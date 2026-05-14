import net from 'node:net';
import { connectUsbmux } from './usbmux.js';
import {
  CONNECT_TIMEOUT_MS,
  CONNECTION_MAX_BUFFER_SIZE_BYTES,
  DEFAULT_DRIVER_HOST,
  DEFAULT_PORT,
  MAX_FRAME_SIZE_BYTES,
  MILLISECONDS_PER_SECOND,
  READ_TIMEOUT_MS,
  SOCKET_KEEPALIVE_INITIAL_DELAY_MS,
} from '../constants.js';

export class DriverError extends Error {
  data?: unknown;
  constructor(message: string, data?: unknown) {
    super(message);
    this.name = 'DriverError';
    this.data = data;
  }
}

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
  private readBuffer: Buffer | null = null;
  private readOffset = 0;
  private readTimer: ReturnType<typeof setTimeout> | null = null;
  private sendQueue: Promise<void> = Promise.resolve();
  private _disconnecting = false;

  constructor(opts: { host?: string; port?: number; udid?: string; directTcp?: boolean }) {
    this.host = opts.host ?? DEFAULT_DRIVER_HOST;
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

    this.socket.setKeepAlive(true, SOCKET_KEEPALIVE_INITIAL_DELAY_MS);
    this.socket.setNoDelay(true);
    this.socket.on('data', (data: Buffer) => this.onData(data));
    this.socket.on('end', () => {
      if (this.readReject) {
        this.readReject(new Error('socket closed by remote'));
        this.readResolve = null;
        this.readReject = null;
        this.readNeeded = 0;
        this.readBuffer = null;
        this.readOffset = 0;
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
        this.readBuffer = null;
        this.readOffset = 0;
      }
      if (this.readTimer) { clearTimeout(this.readTimer); this.readTimer = null; }
      this.disconnect();
    });
    this.socket.on('close', () => {
      this.socket = null;
      this.buffer = Buffer.alloc(0);
      this.readBuffer = null;
      this.readOffset = 0;
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
      const sock = this.socket!;
      sock.cork();
      sock.write(header);
      sock.write(data, (err?: Error | null) => err ? reject(err) : resolve());
      process.nextTick(() => sock.uncork());
    });
  }

  private async readFrame(): Promise<Buffer> {
    const header = await this.readExact(4);
    const len = header.readUInt32BE(0);
    if (len === 0 || len > MAX_FRAME_SIZE_BYTES) {
      throw new Error(`invalid frame length: ${len}`);
    }
    return await this.readExact(len);
  }

  private onData(data: Buffer): void {
    if (this.readResolve) {
      if (!this.readBuffer && this.readOffset === 0 && data.length >= this.readNeeded) {
        if (this.readTimer) { clearTimeout(this.readTimer); this.readTimer = null; }
        const result = data.subarray(0, this.readNeeded);
        this.buffer = data.subarray(this.readNeeded);
        if (this.buffer.length > CONNECTION_MAX_BUFFER_SIZE_BYTES) {
          this.disconnect();
          return;
        }
        const resolve = this.readResolve;
        this.readResolve = null;
        this.readReject = null;
        this.readNeeded = 0;
        this.readBuffer = null;
        this.readOffset = 0;
        resolve(result);
        return;
      }

      if (!this.readBuffer) {
        this.readBuffer = Buffer.allocUnsafe(this.readNeeded);
      }
      const remaining = this.readNeeded - this.readOffset;
      const take = Math.min(remaining, data.length);
      if (take > 0) {
        data.copy(this.readBuffer, this.readOffset, 0, take);
        this.readOffset += take;
      }
      if (this.readOffset >= this.readNeeded) {
        if (this.readTimer) { clearTimeout(this.readTimer); this.readTimer = null; }
        const result = this.readBuffer;
        this.buffer = data.subarray(take);
        if (this.buffer.length > CONNECTION_MAX_BUFFER_SIZE_BYTES) {
          this.disconnect();
          return;
        }
        const resolve = this.readResolve;
        this.readResolve = null;
        this.readReject = null;
        this.readNeeded = 0;
        this.readBuffer = null;
        this.readOffset = 0;
        resolve(result);
      }
      return;
    }

    const nextLength = this.buffer.length + data.length;
    if (nextLength > CONNECTION_MAX_BUFFER_SIZE_BYTES) {
      this.disconnect();
      return;
    }
    this.buffer = this.buffer.length === 0 ? data : Buffer.concat([this.buffer, data], nextLength);
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
      this.readBuffer = null;
      this.readOffset = 0;

      if (this.buffer.length > 0) {
        this.readBuffer = Buffer.allocUnsafe(n);
        this.buffer.copy(this.readBuffer, 0);
        this.readOffset = this.buffer.length;
        this.buffer = Buffer.alloc(0);
      }

      this.readTimer = setTimeout(() => {
        if (this.readReject) {
          const gotBytes = this.readOffset + this.buffer.length;
          const rejectFn = this.readReject;
          this.readResolve = null;
          this.readReject = null;
          this.readNeeded = 0;
          this.readBuffer = null;
          this.readOffset = 0;
          this.readTimer = null;
          this.buffer = Buffer.alloc(0);
          rejectFn(new Error(`read timeout after ${READ_TIMEOUT_MS / MILLISECONDS_PER_SECOND}s (got ${gotBytes}/${n} bytes)`));
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
      this.readBuffer = null;
      this.readOffset = 0;
    }
    if (this.socket) {
      this.socket.removeAllListeners();
      this.socket.destroy();
      this.socket = null;
    }
    this.buffer = Buffer.alloc(0);
    this.readBuffer = null;
    this.readOffset = 0;
    this.sendQueue = Promise.resolve();
    this._disconnecting = false;
  }
}
