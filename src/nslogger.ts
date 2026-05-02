import net from 'net';
import tls from 'tls';
import fs from 'fs';
import path from 'path';
import os from 'os';
import { execFileSync, spawn, ChildProcess } from 'child_process';
import { logger } from './utils/logger.js';
import { IOS_USE_HOME, ensureDir } from './utils/paths.js';

// ── Types ──

export interface NSLoggerServerOptions {
  port?: number;
  useSSL?: boolean;
  keyPath?: string | null;
  certPath?: string | null;
  bonjourName?: string;
  publishBonjour?: boolean;
  maxBufferSize?: number;
}

export interface BonjourStatus {
  publishEnabled: boolean;
  attempted: boolean;
  active: boolean;
  serviceName: string;
  serviceType: string;
  domain: string;
  port: number;
  error: string | null;
  pid: number | null;
}

export interface ParsedMessage {
  totalSize: number;
  parts: Record<number, unknown>;
  consumed: number;
}

export interface ImagePart {
  width: number;
  height: number;
  data: Buffer;
}

export interface FormattedMessage {
  level: 'info' | 'warn';
  message: string;
}

// ── Constants ──

const WHITESPACE_RE = /\s+/g;
const DEFAULT_NSLOGGER_RUNTIME_DIR = path.join(IOS_USE_HOME, 'runtime');

export const PART_KEY_MESSAGE_TYPE = 0;
export const PART_KEY_TIMESTAMP_S = 1;
export const PART_KEY_TIMESTAMP_MS = 2;
export const PART_KEY_TIMESTAMP_US = 3;
export const PART_KEY_THREAD_ID = 4;
export const PART_KEY_TAG = 5;
export const PART_KEY_LEVEL = 6;
export const PART_KEY_MESSAGE = 7;
export const PART_KEY_IMAGE_WIDTH = 8;
export const PART_KEY_IMAGE_HEIGHT = 9;
export const PART_KEY_MESSAGE_SEQ = 10;
export const PART_KEY_FILENAME = 11;
export const PART_KEY_LINENUMBER = 12;
export const PART_KEY_FUNCTIONNAME = 13;
export const PART_KEY_CLIENT_NAME = 20;
export const PART_KEY_CLIENT_VERSION = 21;
export const PART_KEY_OS_NAME = 22;
export const PART_KEY_OS_VERSION = 23;
export const PART_KEY_CLIENT_MODEL = 24;
export const PART_KEY_UNIQUEID = 25;

export const PART_TYPE_STRING = 0;
export const PART_TYPE_BINARY = 1;
export const PART_TYPE_INT16 = 2;
export const PART_TYPE_INT32 = 3;
export const PART_TYPE_INT64 = 4;
export const PART_TYPE_IMAGE = 5;

export const LOGMSG_TYPE_LOG = 0;
export const LOGMSG_TYPE_BLOCKSTART = 1;
export const LOGMSG_TYPE_BLOCKEND = 2;
export const LOGMSG_TYPE_CLIENTINFO = 3;
export const LOGMSG_TYPE_DISCONNECT = 4;
export const LOGMSG_TYPE_MARK = 5;

// ── Helpers ──

export const DEFAULT_NSLOGGER_KEY_PATH = path.join(DEFAULT_NSLOGGER_RUNTIME_DIR, 'nslogger-selfsigned.key');
export const DEFAULT_NSLOGGER_CERT_PATH = path.join(DEFAULT_NSLOGGER_RUNTIME_DIR, 'nslogger-selfsigned.crt');

function ensureDefaultTLSCredentials(): void {
  ensureDir(DEFAULT_NSLOGGER_RUNTIME_DIR);
  const hasKey = fs.existsSync(DEFAULT_NSLOGGER_KEY_PATH);
  const hasCert = fs.existsSync(DEFAULT_NSLOGGER_CERT_PATH);
  if (hasKey && hasCert) {
    return;
  }

  try {
    fs.rmSync(DEFAULT_NSLOGGER_KEY_PATH, { force: true });
    fs.rmSync(DEFAULT_NSLOGGER_CERT_PATH, { force: true });
    execFileSync('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-keyout',
      DEFAULT_NSLOGGER_KEY_PATH,
      '-out',
      DEFAULT_NSLOGGER_CERT_PATH,
      '-nodes',
      '-subj',
      '/CN=ios-use NSLogger',
      '-days',
      '3650',
    ], { stdio: 'ignore' });
    fs.chmodSync(DEFAULT_NSLOGGER_KEY_PATH, 0o600);
    fs.chmodSync(DEFAULT_NSLOGGER_CERT_PATH, 0o644);
  } catch (error: unknown) {
    throw new Error(`Failed to generate NSLogger TLS certificate: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function resolveTLSCredentials(opts: NSLoggerServerOptions = {}): { keyPath: string | null; certPath: string | null } {
  if (!opts.useSSL) {
    return {
      keyPath: opts.keyPath || null,
      certPath: opts.certPath || null,
    };
  }

  if (!opts.keyPath && !opts.certPath) {
    ensureDefaultTLSCredentials();
  }

  return {
    keyPath: opts.keyPath || DEFAULT_NSLOGGER_KEY_PATH,
    certPath: opts.certPath || DEFAULT_NSLOGGER_CERT_PATH,
  };
}

// ── Message parsing ──

export function parseMessage(buf: Buffer): ParsedMessage | null {
  if (buf.length < 6) return null;

  const totalSize = buf.readUInt32BE(0);
  if (buf.length < 4 + totalSize) return null;

  const partCount = buf.readUInt16BE(4);
  let offset = 6;
  const parts: Record<number, unknown> = {};

  for (let i = 0; i < partCount; i++) {
    if (offset + 2 > buf.length) break;
    const partKey = buf[offset];
    const partType = buf[offset + 1];
    offset += 2;

    let value: unknown;
    switch (partType) {
      case PART_TYPE_STRING: {
        if (offset + 4 > buf.length) return null;
        const size = buf.readUInt32BE(offset);
        offset += 4;
        if (offset + size > buf.length) return null;
        value = buf.subarray(offset, offset + size).toString('utf-8');
        offset += size;
        break;
      }
      case PART_TYPE_BINARY: {
        if (offset + 4 > buf.length) return null;
        const size = buf.readUInt32BE(offset);
        offset += 4;
        if (offset + size > buf.length) return null;
        value = buf.subarray(offset, offset + size);
        offset += size;
        break;
      }
      case PART_TYPE_INT16: {
        if (offset + 2 > buf.length) return null;
        value = buf.readInt16BE(offset);
        offset += 2;
        break;
      }
      case PART_TYPE_INT32: {
        if (offset + 4 > buf.length) return null;
        value = buf.readInt32BE(offset);
        offset += 4;
        break;
      }
      case PART_TYPE_INT64: {
        if (offset + 8 > buf.length) return null;
        value = Number(buf.readBigInt64BE(offset));
        offset += 8;
        break;
      }
      case PART_TYPE_IMAGE: {
        if (offset + 4 > buf.length) return null;
        const size = buf.readUInt32BE(offset);
        offset += 4;
        if (offset + size > buf.length) return null;
        value = { width: 0, height: 0, data: buf.subarray(offset, offset + size) } as ImagePart;
        offset += size;
        break;
      }
      default:
        return null;
    }

    parts[partKey] = value;
  }

  return { totalSize, parts, consumed: 4 + totalSize };
}

// ── Formatting ──

export function formatLogEntry(parts: Record<number, unknown>): string {
  const msgType = parts[PART_KEY_MESSAGE_TYPE] as number | undefined;
  const tag = (parts[PART_KEY_TAG] as string) || '';
  const level = parts[PART_KEY_LEVEL] as number | undefined;
  const message = (parts[PART_KEY_MESSAGE] as string) || '';
  const filename = (parts[PART_KEY_FILENAME] as string) || '';
  const lineno = parts[PART_KEY_LINENUMBER] as number | undefined;
  const funcName = (parts[PART_KEY_FUNCTIONNAME] as string) || '';
  const seq = parts[PART_KEY_MESSAGE_SEQ] as number | undefined;

  const ts = parts[PART_KEY_TIMESTAMP_S] as number | undefined;
  const tsMs = (parts[PART_KEY_TIMESTAMP_MS] as number) || 0;
  const tsUs = (parts[PART_KEY_TIMESTAMP_US] as number) || 0;
  const ms = tsMs || Math.floor(tsUs / 1000);
  const date = ts ? new Date(ts * 1000 + ms) : null;
  const timeStr = date ? date.toISOString() : '';

  const levelStr = level !== undefined ? `L${level}` : '';
  const tagStr = tag ? `[${tag}]` : '';
  const loc = filename ? ` ${filename}:${lineno || '?'}` : '';
  const fn = funcName ? ` ${funcName}()` : '';
  const seqStr = seq !== undefined ? `#${seq}` : '';

  if (msgType === LOGMSG_TYPE_CLIENTINFO) {
    const name = (parts[PART_KEY_CLIENT_NAME] as string) || '';
    const ver = (parts[PART_KEY_CLIENT_VERSION] as string) || '';
    const osName = (parts[PART_KEY_OS_NAME] as string) || '';
    const osVer = (parts[PART_KEY_OS_VERSION] as string) || '';
    const model = (parts[PART_KEY_CLIENT_MODEL] as string) || '';
    return `${timeStr} [CLIENT_INFO] ${name} v${ver} | ${osName} ${osVer} | ${model}`;
  }

  if (msgType === LOGMSG_TYPE_MARK) {
    return `${timeStr} [MARK] ${message}`;
  }

  if (msgType === LOGMSG_TYPE_BLOCKSTART) {
    return `${timeStr} [BLOCK_START] ${tagStr} ${message}`;
  }

  if (msgType === LOGMSG_TYPE_BLOCKEND) {
    return `${timeStr} [BLOCK_END]`;
  }

  return `${timeStr} ${seqStr} ${tagStr} ${levelStr}${loc}${fn} ${message}`.replace(WHITESPACE_RE, ' ').trim();
}

export function formatBonjourStatusMessages(status: BonjourStatus, opts: { prefix?: string } = {}): FormattedMessage[] {
  const prefix = opts.prefix || '';
  const format = (message: string) => `${prefix}${message}`;

  if (!status.publishEnabled) {
    return [{
      level: 'warn',
      message: format('Bonjour publishing is disabled; iOS NSLogger clients using default settings will not auto-discover this viewer.'),
    }];
  }

  if (status.active) {
    return [{
      level: 'info',
      message: format(`Bonjour publish process started: ${status.serviceName}.${status.serviceType}.${status.domain}:${status.port}`),
    }];
  }

  const errorSuffix = status.error ? ` (${status.error})` : '';
  const messages: FormattedMessage[] = [{
    level: 'warn',
    message: format(`Bonjour publish unavailable; iOS NSLogger clients using default settings may not auto-discover this viewer${errorSuffix}`),
  }];

  if (status.port > 0) {
    messages.push({
      level: 'info',
      message: format(`TCP server is healthy on ephemeral port ${status.port}; to verify direct TCP, restart with a fixed --port and configure LoggerSetViewerHost() on iOS.`),
    });
  }

  return messages;
}

// ── Server ──

export class NSLoggerServer {
  port: number;
  useSSL: boolean;
  keyPath: string | null;
  certPath: string | null;
  publishBonjour: boolean;
  bonjourName: string;
  server: net.Server | tls.Server | null;
  bonjourProcess: ChildProcess | null;
  clients: Map<string, net.Socket>;
  private _ringBuffer: (string | undefined)[];
  private _ringHead: number;
  private _ringTail: number;
  private _ringSize: number;
  private _ringCapacity: number;
  private _msgCallback: ((entry: string, parts: Record<number, unknown>) => void) | null;
  private _grepRegex: RegExp | null = null;
  private _grepPattern = '';
  private _grepFlags = '';
  private _clientCounter = 0;
  bonjourStatus: BonjourStatus;

  constructor(opts: NSLoggerServerOptions = {}) {
    const { keyPath, certPath } = resolveTLSCredentials(opts);
    this.port = opts.port || 0;
    this.useSSL = opts.useSSL ?? false;
    this.keyPath = keyPath;
    this.certPath = certPath;
    this.publishBonjour = opts.publishBonjour !== false;
    this.bonjourName = opts.bonjourName || '';
    this.server = null;
    this.bonjourProcess = null;
    this.clients = new Map();
    const raw = opts.maxBufferSize;
    const num = Number.isFinite(raw) ? (raw as number) : 50000;
    const capacity = Math.max(0, Math.floor(num)) || 50000;
    this._ringBuffer = new Array(capacity);
    this._ringHead = 0;
    this._ringTail = 0;
    this._ringSize = 0;
    this._ringCapacity = this._ringBuffer.length;
    this._msgCallback = null;
    this.bonjourStatus = {
      publishEnabled: this.publishBonjour,
      attempted: false,
      active: false,
      serviceName: this.bonjourName || os.hostname(),
      serviceType: this.useSSL ? '_nslogger-ssl._tcp' : '_nslogger._tcp',
      domain: 'local',
      port: this.port,
      error: null,
      pid: null,
    };
  }

  onMessage(cb: (entry: string, parts: Record<number, unknown>) => void): void {
    this._msgCallback = cb;
  }

  async start(): Promise<number> {
    return new Promise((resolve, reject) => {
      const connectionHandler = (socket: net.Socket) => {
        this._clientCounter += 1;
        const clientId = `client-${this._clientCounter}`;
        logger.info(`NSLogger: client connected from ${clientId} (${socket.remoteAddress}:${socket.remotePort})`);

        let recvBuf = Buffer.alloc(0);

        const MAX_RECV_BUF = 1024 * 1024; // 1MB cap per client to prevent DoS
        socket.on('data', (data: Buffer) => {
          const chunk = Buffer.from(data);
          recvBuf = recvBuf.length === 0 ? chunk : Buffer.concat([recvBuf, chunk]);
          if (recvBuf.length > MAX_RECV_BUF) {
            logger.warn(`NSLogger: client ${clientId} recvBuf exceeded ${MAX_RECV_BUF}, disconnecting`);
            socket.destroy();
            return;
          }

          while (recvBuf.length >= 6) {
            const msg = parseMessage(recvBuf);
            if (!msg) break;

            const entry = formatLogEntry(msg.parts);
            this.push(entry);

            if (this._msgCallback) this._msgCallback(entry, msg.parts);

            recvBuf = recvBuf.subarray(msg.consumed);
          }
        });

        socket.on('close', () => {
          logger.info(`NSLogger: client disconnected ${clientId}`);
          this.clients.delete(clientId);
        });

        socket.on('error', (err: Error) => {
          logger.warn(`NSLogger: socket error ${clientId}: ${err.message}`);
          this.clients.delete(clientId);
        });

        this.clients.set(clientId, socket);
      };

      if (this.useSSL) {
        if (!this.keyPath || !this.certPath) {
          reject(new Error('SSL mode requires keyPath and certPath'));
          return;
        }
        this.server = tls.createServer({
          key: fs.readFileSync(this.keyPath),
          cert: fs.readFileSync(this.certPath),
        }, connectionHandler);
      } else {
        this.server = net.createServer(connectionHandler);
      }

      const onError = (err: Error) => reject(err);
      this.server.once('error', onError);
      this.server.listen(this.port, () => {
        this.server!.off('error', onError);
        const addr = this.server!.address() as net.AddressInfo;
        this.port = addr.port;
        this.bonjourStatus.port = this.port;
        logger.info(`NSLogger: server listening on port ${this.port} (${this.useSSL ? 'SSL' : 'plain'})`);
        if (this.publishBonjour) {
          try {
            this.publishBonjourService();
          } catch (error: unknown) {
            const err = error instanceof Error ? error : new Error(String(error));
            this.bonjourStatus.attempted = true;
            this.bonjourStatus.active = false;
            this.bonjourStatus.error = err.message;
            logger.warn(`NSLogger: failed to publish Bonjour service: ${err.message}`);
          }
        }
        resolve(this.port);
      });
    });
  }

  publishBonjourService(): void {
    if (this.bonjourProcess) return;

    const serviceType = this.useSSL ? '_nslogger-ssl._tcp' : '_nslogger._tcp';
    const serviceName = this.bonjourName || os.hostname();
    const domain = 'local';
    const args = ['-R', serviceName, serviceType, domain, String(this.port)];

    this.bonjourStatus.attempted = true;
    this.bonjourStatus.active = false;
    this.bonjourStatus.serviceType = serviceType;
    this.bonjourStatus.serviceName = serviceName;
    this.bonjourStatus.domain = domain;
    this.bonjourStatus.port = this.port;
    this.bonjourStatus.error = null;
    this.bonjourStatus.pid = null;

    const proc = spawn('dns-sd', args, {
      stdio: 'ignore',
      detached: true,
    });

    this.bonjourProcess = proc;
    this.bonjourStatus.active = true;
    this.bonjourStatus.pid = proc.pid ?? null;

    proc.on('error', (error: Error) => {
      this.bonjourStatus.active = false;
      this.bonjourStatus.error = error.message;
      this.bonjourProcess = null;
      logger.warn(`NSLogger: Bonjour publish error: ${error.message}`);
    });

    proc.on('exit', (code: number | null, signal: NodeJS.Signals | null) => {
      if (!this.bonjourProcess || this.bonjourProcess.pid !== proc.pid) return;
      this.bonjourStatus.active = false;
      this.bonjourStatus.error = `dns-sd exited${code !== null ? ` with code ${code}` : ''}${signal ? ` (signal ${signal})` : ''}`;
      this.bonjourProcess = null;
    });

    proc.unref();
    logger.info(`NSLogger: Bonjour publish process started for ${serviceName}.${serviceType}.${domain}:${this.port}`);
  }

  async stop(): Promise<void> {
    for (const [, socket] of this.clients) {
      try { socket.removeAllListeners(); socket.destroy(); } catch {}
    }
    this.clients.clear();
    if (this.bonjourProcess && !this.bonjourProcess.killed) {
      try {
        this.bonjourProcess.kill('SIGTERM');
      } catch {}
      this.bonjourProcess = null;
    }
    this.bonjourStatus.active = false;
    this.bonjourStatus.pid = null;
    if (this.server) {
      await new Promise<void>((resolve, reject) => {
        this.server!.close((err) => {
          if (err) reject(err);
          else {
            logger.info('NSLogger: server stopped');
            resolve();
          }
        });
      });
    }
    this.server = null;
  }

  getBonjourStatus(): BonjourStatus {
    return {
      ...this.bonjourStatus,
      port: this.port,
    };
  }

  grep(pattern: string, flags = ''): string[] {
    let regex: RegExp;
    if (pattern === this._grepPattern && flags === this._grepFlags && this._grepRegex) {
      regex = this._grepRegex;
    } else {
      try {
        regex = new RegExp(pattern, flags);
      } catch (e) {
        throw new Error(`Invalid regex pattern: ${pattern} (flags: ${flags}) — ${e instanceof Error ? e.message : String(e)}`);
      }
      this._grepRegex = regex;
      this._grepPattern = pattern;
      this._grepFlags = flags;
    }
    const result: string[] = [];
    let idx = this._ringHead;
    for (let i = 0; i < this._ringSize; i++) {
      const entry = this._ringBuffer[idx];
      if (entry !== undefined && regex.test(entry)) {
        result.push(entry);
      }
      idx++;
      if (idx >= this._ringCapacity) idx = 0;
    }
    return result;
  }

  clear(): void {
    this._ringBuffer.fill(undefined);
    this._ringHead = 0;
    this._ringTail = 0;
    this._ringSize = 0;
  }

  push(entry: string): void {
    this._ringBuffer[this._ringTail] = entry;
    this._ringTail++;
    if (this._ringTail >= this._ringCapacity) this._ringTail = 0;
    if (this._ringSize === this._ringCapacity) {
      this._ringHead++;
      if (this._ringHead >= this._ringCapacity) this._ringHead = 0;
    } else {
      this._ringSize++;
    }
  }

  getPort(): number {
    return this.port;
  }

  getLogCount(): number {
    return this._ringSize;
  }
}
