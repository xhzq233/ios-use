import tls from 'node:tls';
import { LockdowndClient, getPairRecord } from './lockdown.js';
import { connectUsbmux } from '../driver-protocol/usbmux.js';

const SYSLOG_SERVICE_NAME = 'com.apple.syslog_relay';

/** Collect syslog lines from a real device for timeoutMs. */
export async function collectSyslog(udid: string, timeoutMs: number): Promise<string[]> {
  const pairRecord = await getPairRecord(udid);
  const hostId = pairRecord.HostID as string;
  const systemBUID = pairRecord.SystemBUID as string;
  const toBuf = (v: unknown) => typeof v === 'string' ? Buffer.from(v, 'base64') : (v as Buffer);
  const hostKey = toBuf(pairRecord.HostPrivateKey);
  const hostCert = toBuf(pairRecord.HostCertificate);

  const lockdown = new LockdowndClient(udid);
  await lockdown.connect();
  let port: number;
  let enableServiceSSL = false;
  try {
    await lockdown.startSession(hostId, systemBUID);
    await lockdown.enableSessionSSL(hostKey, hostCert);
    const svc = await lockdown.startService(SYSLOG_SERVICE_NAME);
    port = svc.port;
    enableServiceSSL = svc.enableServiceSSL;
  } finally {
    lockdown.disconnect();
  }

  let socket = await connectUsbmux(udid, port);
  if (enableServiceSSL) {
    socket = await new Promise<tls.TLSSocket>((resolve, reject) => {
      const s = tls.connect({
        socket,
        rejectUnauthorized: false,
        key: hostKey,
        cert: hostCert,
      });
      s.once('secureConnect', () => resolve(s));
      s.once('error', reject);
    });
  }
  socket.write('start');

  return new Promise<string[]>((resolve) => {
    const lines: string[] = [];
    let buf = '';

    const timer = setTimeout(() => {
      socket.removeAllListeners('data');
      socket.destroy();
      if (buf.trim()) lines.push(buf.trimEnd());
      resolve(lines);
    }, timeoutMs);

    socket.on('data', (data: Buffer) => {
      buf += data.toString('utf8');
      const parts = buf.split('\n');
      buf = parts.pop() ?? '';
      for (const line of parts) {
        const trimmed = line.trim();
        if (trimmed) lines.push(trimmed);
      }
    });

    socket.on('error', () => { clearTimeout(timer); resolve(lines); });
    socket.on('end', () => { clearTimeout(timer); if (buf.trim()) lines.push(buf.trimEnd()); resolve(lines); });
  });
}
