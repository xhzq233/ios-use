import net from 'node:net';
import tls from 'node:tls';
import { execSync } from 'node:child_process';
import plist from 'plist';
import { connectUsbmux } from '../driver-protocol/usbmux.js';

const LOCKDOWN_PORT = 62078;
const LABEL = 'ios-use';
const PROTOCOL_VERSION = '2';

// ── Plist message framing over length-prefixed socket ──

function plistSend(socket: net.Socket, msg: Record<string, unknown>): void {
  const xml = Buffer.from(plist.build(msg), 'utf8');
  const len = Buffer.allocUnsafe(4);
  len.writeUInt32BE(xml.length, 0);
  socket.write(len);
  socket.write(xml);
}

function plistRecv(socket: net.Socket, timeoutMs = 10000): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`plist recv timeout after ${timeoutMs}ms`)), timeoutMs);
    let buf = Buffer.alloc(0);

    function readExact(n: number): Buffer | null {
      if (buf.length < n) return null;
      const result = buf.subarray(0, n);
      buf = buf.subarray(n);
      return result;
    }

    function tryParse() {
      if (buf.length < 4) return;
      const size = buf.readUInt32BE(0);
      if (size > 10 * 1024 * 1024) { clearTimeout(timer); return reject(new Error(`plist too large: ${size}`)); }
      if (buf.length < 4 + size) return;
      clearTimeout(timer);
      socket.removeListener('data', onData);
      try {
        const data = buf.subarray(4, 4 + size);
        buf = buf.subarray(4 + size);
        resolve(plist.parse(data.toString('utf8')) as Record<string, unknown>);
      } catch (e) {
        reject(e);
      }
    }

    function onData(chunk: Buffer) {
      buf = buf.length === 0 ? chunk : Buffer.concat([buf, chunk]);
      tryParse();
    }
    socket.on('data', onData);
    // Check buffered data
    tryParse();
  });
}

// ── Parse binary plist using macOS plutil ──

function parseBinaryPlist(data: Buffer): Record<string, unknown> {
  const xml = execSync('plutil -convert xml1 -o - -', { input: data, encoding: 'utf8' });
  return plist.parse(xml) as Record<string, unknown>;
}

// ── Read pair record from usbmuxd ──

async function readPairRecord(udid: string): Promise<Record<string, unknown> | null> {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection('/var/run/usbmuxd');
    sock.once('error', reject);
    sock.once('connect', () => {
      let buf = Buffer.alloc(0);
      const msg = plist.build({
        MessageType: 'ReadPairRecord',
        PairRecordID: udid,
        ProgName: 'ios-use',
        ClientVersionString: '1.0',
      });
      const header = Buffer.allocUnsafe(16);
      header.writeUInt32LE(16 + msg.length, 0);
      header.writeUInt32LE(1, 4);
      header.writeUInt32LE(8, 8);
      header.writeUInt32LE(0, 12);

      sock.on('data', (chunk: Buffer) => {
        buf = buf.length === 0 ? chunk : Buffer.concat([buf, chunk]);
        if (buf.length < 16) return;
        const msgLen = buf.readUInt32LE(0);
        if (buf.length < msgLen) return;
        try {
          const payload = plist.parse(buf.subarray(16, msgLen).toString('utf8')) as any;
          sock.destroy();
          if (payload.PairRecordData) {
            // PairRecordData is binary plist, convert via plutil
            const data = typeof payload.PairRecordData === 'string'
              ? Buffer.from(payload.PairRecordData, 'base64')
              : (Buffer.isBuffer(payload.PairRecordData) ? payload.PairRecordData : Buffer.from(payload.PairRecordData));
            resolve(parseBinaryPlist(data));
          } else {
            resolve(null);
          }
        } catch (e) {
          sock.destroy();
          reject(e);
        }
      });

      sock.write(header);
      sock.write(Buffer.from(msg));
    });
  });
}

// ── LockdowndClient ──

export class LockdowndClient {
  private socket: net.Socket | null = null;
  private udid: string;

  constructor(udid: string) {
    this.udid = udid;
  }

  async connect(): Promise<void> {
    this.socket = await connectUsbmux(this.udid, LOCKDOWN_PORT);
  }

  private async sendRequest(req: Record<string, unknown>): Promise<Record<string, unknown>> {
    if (!this.socket) throw new Error('not connected');
    const labeled = { Label: LABEL, ProtocolVersion: PROTOCOL_VERSION, ...req };
    plistSend(this.socket, labeled);
    return await plistRecv(this.socket);
  }

  async queryType(): Promise<void> {
    const resp = await this.sendRequest({ Request: 'QueryType' });
    if (resp.Type !== 'com.apple.mobile.lockdown') {
      throw new Error(`Unexpected lockdown type: ${resp.Type}`);
    }
  }

  async startSession(hostId: string, systemBUID: string): Promise<{ sessionID: string; enableSessionSSL: boolean }> {
    const resp = await this.sendRequest({
      Request: 'StartSession',
      HostID: hostId,
      SystemBUID: systemBUID,
    });
    if (resp.Error) throw new Error(`StartSession failed: ${resp.Error}`);
    if (!resp.SessionID) throw new Error(`StartSession returned no SessionID: ${JSON.stringify(resp)}`);
    return { sessionID: resp.SessionID as string, enableSessionSSL: (resp.EnableSessionSSL as boolean) ?? false };
  }

  enableSessionSSL(hostPrivateKey: Buffer, hostCertificate: Buffer): Promise<void> {
    if (!this.socket) throw new Error('not connected');
    const rawSocket = this.socket;
    return new Promise((resolve, reject) => {
      const tlsSocket = tls.connect({
        socket: rawSocket,
        rejectUnauthorized: false,
        key: hostPrivateKey,
        cert: hostCertificate,
      }, () => resolve());
      tlsSocket.once('error', reject);
      this.socket = tlsSocket;
    });
  }

  async startService(serviceName: string): Promise<{ port: number; enableServiceSSL: boolean }> {
    const resp = await this.sendRequest({
      Request: 'StartService',
      Service: serviceName,
    });
    if (resp.Error) throw new Error(`StartService(${serviceName}) failed: ${resp.Error}`);
    return { port: resp.Port as number, enableServiceSSL: (resp.EnableServiceSSL as boolean) ?? false };
  }

  disconnect(): void {
    if (this.socket) {
      this.socket.destroy();
      this.socket = null;
    }
  }
}

export async function getPairRecord(udid: string): Promise<Record<string, unknown>> {
  const record = await readPairRecord(udid);
  if (!record) throw new Error(`No pair record found for device ${udid}. Please pair with the device first.`);
  return record;
}
