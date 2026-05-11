import net from 'node:net';
import {
  serializeRequestFrame,
  serializeArgs,
  deserializeResponse,
  deserializeResponsePayload,
} from './fory.js';
import type { ResponseFrame } from './frames.js';
import { connectUsbmux } from './usbmux.js';

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
    this.port = opts.port ?? 8100;
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
          reject(new Error(`connect timeout after 10s (${this.host}:${this.port})`));
        }, 10_000);
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

  async send(command: string, args?: Record<string, unknown>): Promise<ResponseFrame> {
    if (!this.socket) throw new Error('not connected');
    return new Promise((resolve, reject) => {
      this.sendQueue = this.sendQueue
        .then(() => this._sendUnsafe(command, args).then(resolve, reject))
        .catch((err: Error) => { reject(err); })
        .then(() => {});
    });
  }

  private async writeForyFrame(command: string, args?: Record<string, unknown>): Promise<void> {
    const argsPayload = serializeArgs(command, args);
    const frameData = serializeRequestFrame(command, argsPayload);
    const header = Buffer.allocUnsafe(4);
    header.writeUInt32BE(frameData.length, 0);
    const payload = frameData instanceof Buffer ? frameData : Buffer.from(frameData);
    await new Promise<void>((resolve, reject) => {
      this.socket!.write(header);
      this.socket!.write(payload, (err?: Error | null) => err ? reject(err) : resolve());
    });
  }

  private async readForyFrame(): Promise<Uint8Array> {
    const header = await this.readExact(4);
    const len = header.readUInt32BE(0);
    if (len === 0 || len > MAX_FRAME_SIZE) {
      throw new Error(`invalid frame length: ${len}`);
    }
    const body = await this.readExact(len);
    return body;
  }

  private async _sendUnsafe(command: string, args?: Record<string, unknown>): Promise<ResponseFrame> {
    if (!this.socket) throw new Error('not connected');
    await this.writeForyFrame(command, args);

    const frameData = await this.readForyFrame();
    const { frame, payloadBytes } = deserializeResponse(frameData);

    if (payloadBytes && payloadBytes.length > 0) {
      const payload = deserializeResponsePayload(command, payloadBytes);
      return { ok: frame.ok, error: frame.error, data: payload };
    }
    return frame;
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
      }, 45_000);
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

  get isConnected(): boolean {
    return this.socket !== null;
  }
}
