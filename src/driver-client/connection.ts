import net from 'node:net';
import { createRequestFrame, isBinaryResponseCommand } from '../driver-protocol/index.js';
import type { DriverCommand, RequestFrame, ResponseFrame } from '../driver-protocol/index.js';
import { connectUsbmux } from './usbmux.js';

export class DriverError extends Error {
  data?: unknown;
  constructor(message: string, data?: unknown) {
    super(message);
    this.name = 'DriverError';
    this.data = data;
  }
}

const MAX_JSON_FRAME = 10 * 1024 * 1024; // 10 MB
const MAX_BINARY_FRAME = 50 * 1024 * 1024; // 50 MB

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

  async send(command: DriverCommand, args?: Record<string, unknown>): Promise<ResponseFrame> {
    if (!this.socket) throw new Error('not connected');
    return new Promise((resolve, reject) => {
      this.sendQueue = this.sendQueue
        .then(() => this._sendUnsafe(command, args).then(resolve, reject))
        .catch((err: Error) => { reject(err); })
        .then(() => {});
    });
  }

  /**
   * Send a command that returns: 1) a JSON frame with `{size: N}`, then 2) an N-byte binary frame.
   * Used by screenshot (§6.2).
   */
  async sendExpectingBinary(
    command: DriverCommand,
    args?: Record<string, unknown>,
  ): Promise<{ data: { size: number } & Record<string, unknown>; binary: Buffer }> {
    if (!this.socket) throw new Error('not connected');
    if (!isBinaryResponseCommand(command)) {
      throw new Error(`command ${command} does not use binary responses`);
    }
    return new Promise((resolve, reject) => {
      this.sendQueue = this.sendQueue
        .then(() => this._sendUnsafeExpectingBinary(command, args).then(resolve, reject))
        .catch((err: Error) => { reject(err); })
        .then(() => {});
    });
  }

  private async writeFrame(command: DriverCommand, args?: Record<string, unknown>): Promise<void> {
    const frame: RequestFrame = createRequestFrame(command, args);
    const body = Buffer.from(JSON.stringify(frame), 'utf-8');
    const header = Buffer.alloc(4);
    header.writeUInt32BE(body.length, 0);
    await new Promise<void>((resolve, reject) => {
      this.socket!.write(Buffer.concat([header, body]), (err?: Error | null) => err ? reject(err) : resolve());
    });
  }

  private async _sendUnsafe(command: DriverCommand, args?: Record<string, unknown>): Promise<ResponseFrame> {
    if (!this.socket) throw new Error('not connected');
    await this.writeFrame(command, args);

    const respHeader = await this.readExact(4);
    const respLen = respHeader.readUInt32BE(0);
    if (respLen === 0 || respLen > MAX_JSON_FRAME) {
      throw new Error(`invalid response length: ${respLen}`);
    }
    const respBody = await this.readExact(respLen);
    const result = JSON.parse(respBody.toString('utf-8')) as ResponseFrame;
    return result;
  }

  private async _sendUnsafeExpectingBinary(
    command: DriverCommand,
    args?: Record<string, unknown>,
  ): Promise<{ data: { size: number } & Record<string, unknown>; binary: Buffer }> {
    if (!this.socket) throw new Error('not connected');
    await this.writeFrame(command, args);

    const respHeader = await this.readExact(4);
    const respLen = respHeader.readUInt32BE(0);
    if (respLen === 0 || respLen > MAX_JSON_FRAME) {
      throw new Error(`invalid response length: ${respLen}`);
    }
    const respBody = await this.readExact(respLen);
    const result = JSON.parse(respBody.toString('utf-8')) as ResponseFrame;
    if (!result.ok) {
      throw new DriverError(result.error ?? `command ${command} failed`, result.data);
    }
    const data = (result.data ?? {}) as { size?: number } & Record<string, unknown>;
    const size = typeof data.size === 'number' ? data.size : 0;
    if (size <= 0) {
      throw new Error(`invalid binary frame size: ${size}`);
    }
    if (size > MAX_BINARY_FRAME) {
      throw new Error(`binary frame too large: ${size} (max ${MAX_BINARY_FRAME})`);
    }

    // Read 4-byte length-prefixed binary frame
    const binHeader = await this.readExact(4);
    const binLen = binHeader.readUInt32BE(0);
    if (binLen !== size) {
      throw new Error(`binary frame length mismatch: header says ${binLen}, json says ${size}`);
    }
    const binary = await this.readExact(binLen);
    return { data: data as { size: number } & Record<string, unknown>, binary };
  }

  private onData(data: Buffer): void {
    const MAX_BUFFER_SIZE = 64 * 1024 * 1024; // 64 MB to accommodate large JPEG
    const chunk = Buffer.from(data);
    this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);
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
          rejectFn(new Error(`read timeout after 70s (got ${gotBytes}/${n} bytes)`));
        }
        this.disconnect();
      }, 70_000);
    });
  }

  disconnect(): void {
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
  }

  get isConnected(): boolean {
    return this.socket !== null;
  }
}
