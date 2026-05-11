import { writeFileSync } from 'fs';
import { DEFAULT_PORT } from '../constants.js';
import { Connection, DriverError } from '../driver-protocol/connection.js';
import {
  serializeRequestFrame,
  deserializeResponse,
  activateAppArgsSer,
  createSessionArgsSer,
  proxyCAPushArgsSer,
  deserializeSimpleStringPayload,
  deserializeScreenshotPayload,
  deserializeProxyPayload,
} from '../driver-protocol/fory.js';
import type { RawResponse } from '../driver-protocol/fory.js';
import { DRIVER_COMMANDS } from '../driver-protocol/index.js';
import type { CreateSessionResponse } from '../driver-protocol/index.js';

export { DriverError };
export type { RawResponse };

function nextSessionId(): string {
  return `session-${Date.now()}`;
}

export class DriverClient {
  private conn: Connection;
  private _sessionId: string | null;
  private _bundleId: string | null;
  private verbose: boolean;
  private _ownsSession: boolean;

  constructor(opts: {
    host?: string;
    port?: number;
    udid?: string;
    directTcp?: boolean;
    verbose?: boolean;
    ownsSession?: boolean;
    sessionId?: string;
    bundleId?: string;
  } = {}) {
    this.conn = new Connection({
      host: opts.host ?? '127.0.0.1',
      port: opts.port ?? DEFAULT_PORT,
      udid: opts.udid,
      directTcp: opts.directTcp,
    });
    this._sessionId = opts.sessionId ?? null;
    this._bundleId = opts.bundleId ?? null;
    this.verbose = opts.verbose ?? false;
    this._ownsSession = opts.ownsSession ?? true;
  }

  async connect(): Promise<void> {
    await this.conn.connect();
  }

  disconnect(): void {
    this.conn.disconnect();
  }

  get sessionId(): string { return this._sessionId ?? ''; }
  get bundleId(): string | null { return this._bundleId; }

  /** Send a Fory frame (command + pre-serialized args payload). Returns raw response. */
  async sendRaw(command: string, argsPayload: Uint8Array): Promise<RawResponse> {
    const t0 = this.verbose ? Date.now() : 0;
    const frameData = serializeRequestFrame(command, argsPayload);
    const responseBytes = await this.conn.send(Buffer.from(frameData));
    if (this.verbose) console.log(`[client] ${command} took ${Date.now() - t0}ms`);
    return deserializeResponse(responseBytes);
  }

  // ── Session lifecycle (used by session.ts) ──

  async createSession(bundleId?: string, terminate?: boolean): Promise<CreateSessionResponse> {
    const args = { bundleId: bundleId ?? '', terminate: terminate ?? false };
    const payload = createSessionArgsSer.serialize(args);
    const resp = await this.sendRaw(DRIVER_COMMANDS.CREATE_SESSION, payload);
    if (!resp.ok) throw new DriverError(resp.error ?? 'createSession failed', resp.errorData);
    this._sessionId = nextSessionId();
    this._bundleId = bundleId ?? null;
    return (resp.payloadBytes ? deserializeSimpleStringPayload(resp.payloadBytes) : {}) as CreateSessionResponse;
  }

  async deleteSession(): Promise<void> {
    if (!this._ownsSession) return;
    await this.sendRaw(DRIVER_COMMANDS.DELETE_SESSION, new Uint8Array(0));
    this._sessionId = null;
    this._bundleId = null;
  }

  async activateApp(bundleId: string): Promise<void> {
    const payload = activateAppArgsSer.serialize({ bundleId });
    const resp = await this.sendRaw(DRIVER_COMMANDS.ACTIVATE_APP, payload);
    if (!resp.ok) throw new DriverError(resp.error ?? 'activateApp failed', resp.errorData);
    this._bundleId = bundleId;
  }

  // ── Screenshot (used by handler + proxy) ──

  async screenshot(): Promise<Buffer> {
    const resp = await this.sendRaw(DRIVER_COMMANDS.SCREENSHOT, new Uint8Array(0));
    if (!resp.ok) throw new DriverError(resp.error ?? 'screenshot failed', resp.errorData);
    return deserializeScreenshotPayload(resp.payloadBytes!).jpeg;
  }

  async saveScreenshot(filepath: string): Promise<void> {
    const buf = await this.screenshot();
    writeFileSync(filepath, buf);
  }

  // ── Proxy (used by proxy.ts) ──

  async proxyCAPush(caBase64: string): Promise<unknown> {
    const payload = proxyCAPushArgsSer.serialize({ caBase64 });
    const resp = await this.sendRaw(DRIVER_COMMANDS.PROXY_CA_PUSH, payload);
    if (!resp.ok) throw new DriverError(resp.error ?? 'proxyCAPush failed', resp.errorData);
    return deserializeProxyPayload(resp.payloadBytes!);
  }
}
