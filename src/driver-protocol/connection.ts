import net from 'node:net';
import { connectUsbmux } from './usbmux.js';
import { CONNECT_TIMEOUT_MS, DEFAULT_PORT, READ_TIMEOUT_MS } from '../constants.js';

export class DriverError extends Error {
  data?: unknown;
  constructor(message: string, data?: unknown) {
    super(message);
    this.name = 'DriverError';
    this.data = data;
  }
}

const MAX_FRAME_SIZE = 50 * 1024 * 1024; // 50 MB

export class Connection {
  private host: string;
  private port: number;
  private udid?: string;
  private directTcp: boolean;
  private socket: net.Socket | null = null;
  private buffer = Buffer.alloc(0);
  private readResolve: ((data: Buffer) => void) | null = null;
  private readReject: ((err: Error) => void) | null = null;
  private readNeeded = 0;
  private readTimer: ReturnType<typeof setTimeout> | null = null;
  private sendQueue: Promise<void> = Promise.resolve();
  private _disconnecting = false;

  constructor(opts: { host?: string; port?: number; udid?: string; directTcp?: boolean }) {
    this.host = opts.host ?? '127.0.0.1';
    this.port = opts.port ?? DEFAULT_PORT;
    this.udid = opts.udid;
    this.directTcp = opts.directTcp ?? false;
  }

  async connect(): Promise<void> {
    if (this.udid && !this.directTcp) {
      this.socket = await connectUsbmux(this.udid, this.port);
    } else {
      this.socket = await new Promise<net.Socket>((resolve, reject) => {
        const sock = net.createConnection({ host: this.host, port: this.port }, () => resolve(sock));
        const timer = setTimeout(() => {
          sock.destroy();
          reject(new Error(`connect timeout after ${CONNECT_TIMEOUT_MS}ms (${this.host}:${this.port})`));
        }, CONNECT_TIMEOUT_MS);
        sock.once('error', (err: Error) => { clearTimeout(timer); reject(err); });
        sock.once('connect', () => { clearTimeout(timer); });
      });
    }

    this.socket.setKeepAlive(true, 5000);
    this.socket.setNoDelay(true);
    this.socket.on('data', (data: Buffer) => this.onData(data));
    this.socket.on('end', () => {
      if (this.readReject) {
        this.readReject(new Error('socket closed by remote'));
        this.readResolve = null;
        this.readReject = null;
        this.readNeeded = 0;
      }
      if (this.readTimer) { clearTimeout(this.readTimer); this.readTimer = null; }
      this.disconnect();
    });
    this.socket.on('error', (err: Error) => {
      if (this.readReject) {
        this.readReject(err);
        this.readResolve = null;
        this.readReject = null;
        this.readNeeded = 0;
      }
      if (this.readTimer) { clearTimeout(this.readTimer); this.readTimer = null; }
      this.disconnect();
    });
    this.socket.on('close', () => {
      this.socket = null;
      this.buffer = Buffer.alloc(0);
    });
  }

  /** Send raw bytes with 4-byte BE length prefix. Returns raw response bytes. */
  async send(payload: Buffer): Promise<Buffer> {
    if (!this.socket) throw new Error('not connected');
    return new Promise((resolve, reject) => {
      this.sendQueue = this.sendQueue
        .then(() => this._sendUnsafe(payload))
        .then(resolve, reject);
    });
  }

  private async _sendUnsafe(payload: Buffer): Promise<Buffer> {
    if (!this.socket) throw new Error('not connected');
    await this.writeFrame(payload);
    return await this.readFrame();
  }

  private async writeFrame(data: Buffer): Promise<void> {
    const header = Buffer.allocUnsafe(4);
    header.writeUInt32BE(data.length, 0);
    await new Promise<void>((resolve, reject) => {
      this.socket!.write(header);
      this.socket!.write(data, (err?: Error | null) => err ? reject(err) : resolve());
    });
  }

  private async readFrame(): Promise<Buffer> {
    const header = await this.readExact(4);
    const len = header.readUInt32BE(0);
    if (len === 0 || len > MAX_FRAME_SIZE) {
      throw new Error(`invalid frame length: ${len}`);
    }
    return await this.readExact(len);
  }

  private onData(data: Buffer): void {
    const MAX_BUFFER_SIZE = 64 * 1024 * 1024;
    this.buffer = this.buffer.length === 0 ? data : Buffer.concat([this.buffer, data]);
    if (this.buffer.length > MAX_BUFFER_SIZE) {
      this.disconnect();
      return;
    }

    if (this.readResolve && this.buffer.length >= this.readNeeded) {
      if (this.readTimer) { clearTimeout(this.readTimer); this.readTimer = null; }
      const result = this.buffer.subarray(0, this.readNeeded);
      this.buffer = this.buffer.subarray(this.readNeeded);
      const resolve = this.readResolve;
      this.readResolve = null;
      this.readReject = null;
      this.readNeeded = 0;
      resolve(result);
    }
  }

  private readExact(n: number): Promise<Buffer> {
    if (this.buffer.length >= n) {
      const result = this.buffer.subarray(0, n);
      this.buffer = this.buffer.subarray(n);
      return Promise.resolve(result);
    }

    return new Promise((resolve, reject) => {
      this.readNeeded = n;
      this.readResolve = resolve;
      this.readReject = reject;

      this.readTimer = setTimeout(() => {
        if (this.readReject) {
          const gotBytes = this.buffer.length;
          const rejectFn = this.readReject;
          this.readResolve = null;
          this.readReject = null;
          this.readNeeded = 0;
          this.readTimer = null;
          this.buffer = Buffer.alloc(0);
          rejectFn(new Error(`read timeout after 45s (got ${gotBytes}/${n} bytes)`));
        }
        this.disconnect();
      }, READ_TIMEOUT_MS);
    });
  }

  disconnect(): void {
    if (this._disconnecting) return;
    this._disconnecting = true;
    if (this.readTimer) { clearTimeout(this.readTimer); this.readTimer = null; }
    if (this.readReject) {
      this.readReject(new Error('connection disconnected'));
      this.readResolve = null;
      this.readReject = null;
      this.readNeeded = 0;
    }
    if (this.socket) {
      this.socket.removeAllListeners();
      this.socket.destroy();
      this.socket = null;
    }
    this.buffer = Buffer.alloc(0);
    this.sendQueue = Promise.resolve();
    this._disconnecting = false;
  }
}
