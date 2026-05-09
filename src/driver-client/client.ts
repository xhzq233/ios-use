import { writeFileSync } from 'fs';
import { Connection, DriverError } from './connection';
import {
  DRIVER_COMMANDS,
  omitUndefined,
} from '../driver-protocol/index.js';
import type {
  CreateSessionResponse,
  DomResponse,
  FindResult,
  FindMatch,
  FindArgs,
  SwipeArgs,
  SwipeResult,
  TapResult,
  LabelOrPoint,
  WaitForArgs,
  WaitForResult,
  OslogArgs,
  OslogResult,
  ProbeFetchResult,
  ProxyCAPushResult,
  DriverCommand,
} from '../driver-protocol/index.js';

export { DriverError };

function nextSessionId(): string {
  return `session-${Date.now()}`;
}

abstract class BaseRpcClient {
  protected conn: Connection;
  protected _sessionId: string | null;
  protected _bundleId: string | null;
  protected verbose: boolean;

  protected constructor(conn: Connection, opts: { sessionId?: string; bundleId?: string; verbose?: boolean } = {}) {
    this.conn = conn;
    this._sessionId = opts.sessionId ?? null;
    this._bundleId = opts.bundleId ?? null;
    this.verbose = opts.verbose ?? false;
  }

  async connect(): Promise<void> {
    await this.conn.connect();
  }

  disconnect(): void {
    this.conn.disconnect();
  }

  get sessionId(): string { return this._sessionId ?? ''; }
  get bundleId(): string | null { return this._bundleId; }

  protected async send<T>(command: DriverCommand, args?: Record<string, unknown>): Promise<T> {
    const t0 = this.verbose ? Date.now() : 0;
    const resp = await this.conn.send(command, args);
    if (this.verbose) console.log(`[client] ${command} took ${Date.now() - t0}ms`);
    if (!resp.ok) {
      throw new DriverError(resp.error ?? `command ${command} failed`, resp.data);
    }
    return resp.data as T;
  }

  async dom(opts?: { raw?: boolean; fresh?: boolean }): Promise<DomResponse> {
    return await this.send(DRIVER_COMMANDS.DOM, omitUndefined({ raw: opts?.raw || undefined, fresh: opts?.fresh || undefined }));
  }

  async find(args: FindArgs): Promise<FindResult> {
    const resp = await this.conn.send(DRIVER_COMMANDS.FIND, omitUndefined({ label: args.label, traits: args.traits }));
    if (resp.ok) {
      const d = (resp.data ?? {}) as { matches?: FindMatch[]; suggestions?: string[]; hint?: string };
      return { ok: true, matches: d.matches ?? [], suggestions: d.suggestions, hint: d.hint };
    }
    const d = (resp.data ?? {}) as { hint?: string };
    return { ok: false, error: resp.error ?? 'find failed', hint: d.hint };
  }

  async tap(
    target: LabelOrPoint,
    traits?: string,
    offset?: { x?: number; y?: number; xRatio?: number; yRatio?: number },
  ): Promise<TapResult> {
    return await this.send(DRIVER_COMMANDS.TAP, omitUndefined({ label: target, traits, offset }));
  }

  async longPress(target: LabelOrPoint, duration?: number, traits?: string): Promise<TapResult> {
    return await this.send(DRIVER_COMMANDS.LONG_PRESS, omitUndefined({ label: target, duration, traits }));
  }

  async input(label: string, content: string, traits?: string): Promise<void> {
    await this.send(DRIVER_COMMANDS.INPUT, omitUndefined({ label, content, traits }));
  }

  async swipe(args: SwipeArgs): Promise<SwipeResult> {
    return await this.send(DRIVER_COMMANDS.SWIPE, omitUndefined(args as unknown as Record<string, unknown>));
  }

  async waitFor(args: WaitForArgs): Promise<WaitForResult> {
    return await this.send(DRIVER_COMMANDS.WAIT_FOR, omitUndefined({
      label: args.label,
      timeout: args.timeout,
      traits: args.traits,
    }));
  }

  async activateApp(bundleId: string): Promise<void> {
    await this.send(DRIVER_COMMANDS.ACTIVATE_APP, { bundleId });
    this._bundleId = bundleId;
  }

  async terminateApp(bundleId: string): Promise<void> {
    if (!bundleId) throw new Error('terminateApp requires bundleId');
    await this.send(DRIVER_COMMANDS.TERMINATE_APP, { bundleId });
  }

  async openURL(url: string): Promise<void> {
    await this.send(DRIVER_COMMANDS.OPEN_URL, { url });
  }

  async dismissAlert(opts?: { index?: number }): Promise<{ dismissed: boolean; text?: string; button?: string; reason?: string }> {
    const res = await this.send(DRIVER_COMMANDS.DISMISS_ALERT, opts || {});
    return res as any;
  }

  async screenshot(): Promise<Buffer> {
    const { binary } = await this.conn.sendExpectingBinary(DRIVER_COMMANDS.SCREENSHOT, {});
    return binary;
  }

  async saveScreenshot(filepath: string): Promise<void> {
    const buf = await this.screenshot();
    writeFileSync(filepath, buf);
  }

  async oslog(args: OslogArgs = {}): Promise<OslogResult> {
    return await this.send(DRIVER_COMMANDS.OSLOG, omitUndefined({
      pattern: args.pattern,
      flags: args.flags,
      name: args.name,
      clear: args.clear,
      bundleId: args.bundleId,
      timeout: args.timeout,
    }));
  }

  async probeFetch(url: string, timeout?: number): Promise<ProbeFetchResult> {
    return await this.send(DRIVER_COMMANDS.PROBE_FETCH, omitUndefined({ url, timeout }));
  }

  async proxyCAPush(caBase64: string): Promise<ProxyCAPushResult> {
    return await this.send(DRIVER_COMMANDS.PROXY_CA_PUSH, { caBase64 });
  }
}

export class DriverClient extends BaseRpcClient {
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
    super(new Connection({
      host: opts.host ?? '127.0.0.1',
      port: opts.port ?? 8100,
      udid: opts.udid,
      directTcp: opts.directTcp,
    }), {
      sessionId: opts.sessionId,
      bundleId: opts.bundleId,
      verbose: opts.verbose,
    });
    this._ownsSession = opts.ownsSession ?? true;
  }

  async createSession(bundleId?: string, terminate?: boolean): Promise<CreateSessionResponse> {
    const args: Record<string, unknown> = {};
    if (bundleId) args.bundleId = bundleId;
    if (terminate) args.terminate = true;
    const data = await this.send<CreateSessionResponse>(DRIVER_COMMANDS.CREATE_SESSION, args);
    this._sessionId = nextSessionId();
    this._bundleId = bundleId ?? null;
    return data;
  }

  async deleteSession(): Promise<void> {
    if (!this._ownsSession) return;
    await this.send(DRIVER_COMMANDS.DELETE_SESSION);
    this._sessionId = null;
    this._bundleId = null;
  }
}
