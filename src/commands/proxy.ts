import net from 'node:net';
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'fs';
import path from 'path';
import { execFileSync, spawn, type ChildProcess } from 'child_process';
import { fileURLToPath } from 'url';
import { IOS_USE_HOME, ensureStateDir } from '../utils/paths.js';
import { logger } from '../utils/logger.js';
import { isProcessAlive } from '../utils/process.js';
import type { DriverClient } from '../driver-client/client.js';
import { flowAction } from './flow.js';

const MITMDUMP_PORT = 9080;
const STATE_FILE = path.join(IOS_USE_HOME, 'state', 'proxy-session.json');
const CA_STATE_FILE = path.join(IOS_USE_HOME, 'state', 'proxy-ca.json');
const EVENTS_FILE = path.join(IOS_USE_HOME, 'state', 'proxy-events.jsonl');
const ADDON_FILE = path.join(IOS_USE_HOME, 'state', 'proxy_jsonl_addon.py');
const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const FLOWS_DIR = path.join(MODULE_DIR, '../../flows');

export interface ProxySessionState {
  sessionId: string;
  status: 'running' | 'stopped';
  startedAt: number;
  stoppedAt?: number;
  udid: string;
  eventsFile: string;
  caInstalled?: boolean;
  network?: {
    interface: string;
    macLanIp: string;
  };
  mitmdumpPid?: number;
  mitmdumpPort?: number;
}

interface WifiInfo {
  interface: string;
  macLanIp: string;
}

interface ProxyCAState {
  udid: string;
  fingerprint: string;
  installedAt: number;
}

let mitmdumpProc: ChildProcess | null = null;

// ── Utilities ──

export function readProxyState(): ProxySessionState | null {
  if (!fs.existsSync(STATE_FILE)) return null;
  try { return JSON.parse(fs.readFileSync(STATE_FILE, 'utf-8')); } catch { return null; }
}

function writeState(state: ProxySessionState): void {
  ensureStateDir();
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + '\n');
}

function readCAState(): ProxyCAState | null {
  if (!fs.existsSync(CA_STATE_FILE)) return null;
  try { return JSON.parse(fs.readFileSync(CA_STATE_FILE, 'utf-8')); } catch { return null; }
}

function writeCAState(state: ProxyCAState): void {
  ensureStateDir();
  fs.writeFileSync(CA_STATE_FILE, JSON.stringify(state, null, 2) + '\n');
}

function fingerprintPem(pem: string): string {
  const body = pem
    .replace(/-----BEGIN CERTIFICATE-----/, '')
    .replace(/-----END CERTIFICATE-----/, '')
    .replace(/\s/g, '');
  return crypto.createHash('sha256').update(Buffer.from(body, 'base64')).digest('hex');
}

async function killPid(pid: number | undefined): Promise<void> {
  if (!pid || !isProcessAlive(pid)) return;
  process.kill(pid, 'SIGTERM');
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    if (!isProcessAlive(pid)) return;
    await new Promise(r => setTimeout(r, 100));
  }
  if (isProcessAlive(pid)) process.kill(pid, 'SIGKILL');
}

function runText(cmd: string, args: string[]): string {
  return execFileSync(cmd, args, { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

function parseDurationMs(input: string): number {
  const match = input.trim().match(/^(\d+(?:\.\d+)?)(ms|s|m)?$/);
  if (!match) throw new Error(`Invalid duration: ${input}`);
  const value = Number(match[1]);
  const unit = match[2] ?? 'ms';
  if (unit === 'ms') return value;
  if (unit === 's') return value * 1000;
  if (unit === 'm') return value * 60_000;
  return value;
}

// ── Wi-Fi Detection ──

function getWifiInterface(): string {
  const out = runText('networksetup', ['-listallhardwareports']);
  const lines = out.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (lines[i]?.trim() === 'Hardware Port: Wi-Fi') {
      const device = lines[i + 1]?.match(/Device:\s*(\S+)/)?.[1];
      if (device) return device;
    }
  }
  throw new Error('WIFI_INTERFACE_NOT_FOUND');
}

function detectWifiInfo(): WifiInfo {
  const iface = getWifiInterface();
  let macLanIp: string;
  try {
    macLanIp = runText('ipconfig', ['getifaddr', iface]);
  } catch {
    throw new Error(`MAC_LAN_IP_NOT_FOUND`);
  }
  if (!macLanIp) throw new Error(`MAC_LAN_IP_NOT_FOUND`);
  return { interface: iface, macLanIp };
}

// ── mitmdump ──

function waitForPort(port: number, timeoutMs: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeoutMs;
    const tryConnect = () => {
      const sock = net.createConnection(port, '127.0.0.1');
      sock.on('connect', () => { sock.destroy(); resolve(); });
      sock.on('error', () => {
        sock.destroy();
        if (Date.now() > deadline) reject(new Error(`Port ${port} not ready after ${timeoutMs}ms`));
        else setTimeout(tryConnect, 200);
      });
    };
    tryConnect();
  });
}

async function waitForFileGrowth(file: string, previousSize: number, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const size = fs.existsSync(file) ? fs.statSync(file).size : 0;
    if (size > previousSize) return true;
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  return false;
}

async function startLanProbeServer(): Promise<{ port: number; close: () => Promise<void> }> {
  const server = http.createServer((_req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('ios-use-ok');
  });
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '0.0.0.0', () => {
      server.off('error', reject);
      resolve();
    });
  });
  const addr = server.address();
  if (!addr || typeof addr === 'string') {
    server.close();
    throw new Error('LAN_PROBE_SERVER_FAILED');
  }
  return {
    port: addr.port,
    close: () => new Promise(resolve => server.close(() => resolve())),
  };
}

async function verifyDeviceCanReachMac(client: DriverClient, macLanIp: string): Promise<void> {
  const probe = await startLanProbeServer();
  try {
    logger.info('Verifying device can reach Mac LAN IP...');
    const result = await client.probeFetch(`http://${macLanIp}:${probe.port}/ping`, 5);
    if (result.statusCode !== 200) {
      throw new Error(`DEVICE_CANNOT_REACH_MAC: LAN probe returned status ${result.statusCode}`);
    }
  } finally {
    await probe.close();
  }
}

async function verifyProxyTraffic(client: DriverClient, eventsFile: string): Promise<void> {
  const beforeSize = fs.existsSync(eventsFile) ? fs.statSync(eventsFile).size : 0;
  const url = `http://example.com/ios-use-proxy-probe-${Date.now()}`;
  logger.info('Verifying device traffic reaches mitmdump...');
  await client.probeFetch(url, 8);
  const observed = await waitForFileGrowth(eventsFile, beforeSize, 5000);
  if (!observed) {
    throw new Error('DEVICE_CANNOT_REACH_MAC: device probe did not appear in mitmdump events.');
  }
}

async function generateMitmproxyCA(confdir: string): Promise<void> {
  if (!fs.existsSync(confdir)) fs.mkdirSync(confdir, { recursive: true });
  const proc = spawn('mitmdump', ['--set', `confdir=${confdir}`, '--listen-port', '0'], { stdio: 'ignore' });
  await new Promise<void>((resolve) => {
    let settled = false;
    const done = () => { if (!settled) { settled = true; resolve(); } };
    const check = setInterval(() => {
      if (fs.existsSync(path.join(confdir, 'mitmproxy-ca-cert.pem'))) {
        clearInterval(check);
        clearTimeout(fallback);
        proc.kill('SIGTERM');
        done();
      }
    }, 200);
    const fallback = setTimeout(() => { clearInterval(check); proc.kill('SIGKILL'); done(); }, 10000);
  });
}

function writeMitmdumpAddon(file: string): void {
  const script = String.raw`import json
import os
import time
from mitmproxy import http

events_file = os.environ.get("IOS_USE_PROXY_EVENTS")
body_limit = int(os.environ.get("IOS_USE_BODY_LIMIT", "102400"))
no_body = os.environ.get("IOS_USE_NO_BODY") == "1"

TEXT_TYPES = ("json", "xml", "html", "text", "javascript", "css", "csv", "yaml", "form")

def _is_text(content_type: str | None) -> bool:
    if not content_type:
        return False
    ct = content_type.lower()
    return any(t in ct for t in TEXT_TYPES)

def _get_body(raw: bytes | None, content_type: str | None) -> tuple:
    """Returns (body_str_or_none, truncated)"""
    if no_body or raw is None:
        return (None, False)
    if not _is_text(content_type):
        return (f"<binary {len(raw)} bytes>", False)
    try:
        text = raw.decode("utf-8", errors="replace")
    except Exception:
        return (f"<binary {len(raw)} bytes>", False)
    if len(text) > body_limit:
        return (text[:body_limit], True)
    return (text, False)

def _write(event):
    line = json.dumps(event, separators=(",", ":"), ensure_ascii=False)
    if events_file:
        with open(events_file, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    print(line, flush=True)

def response(flow: http.HTTPFlow):
    req = flow.request
    resp = flow.response
    started = int((req.timestamp_start or time.time()) * 1000)
    finished = int(((resp.timestamp_end if resp else None) or time.time()) * 1000)
    
    req_ct = req.headers.get("content-type")
    resp_ct = resp.headers.get("content-type") if resp else None
    req_body, req_trunc = _get_body(req.raw_content, req_ct)
    resp_body, resp_trunc = _get_body(resp.raw_content if resp else None, resp_ct)
    
    _write({
        "id": flow.id,
        "method": req.method,
        "url": req.pretty_url,
        "host": req.pretty_host,
        "status": resp.status_code if resp else None,
        "contentType": resp_ct,
        "requestHeaders": dict(req.headers),
        "responseHeaders": dict(resp.headers) if resp else None,
        "requestBody": req_body,
        "responseBody": resp_body,
        "bodyBytes": len(resp.raw_content or b"") if resp else 0,
        "truncated": req_trunc or resp_trunc,
        "startedAt": started,
        "finishedAt": finished,
    })

def error(flow: http.HTTPFlow):
    req = flow.request
    _write({
        "id": flow.id,
        "method": req.method,
        "url": req.pretty_url,
        "host": req.pretty_host,
        "error": str(flow.error) if flow.error else "unknown",
        "startedAt": int((req.timestamp_start or time.time()) * 1000),
        "finishedAt": int(time.time() * 1000),
    })
`;
  fs.writeFileSync(file, script);
}

async function startMitmdump(confdir: string, eventsFile: string, opts: { stream?: boolean; noBody?: boolean; bodyLimit?: number }): Promise<ChildProcess> {
  ensureStateDir();
  writeMitmdumpAddon(ADDON_FILE);

  const args = [
    '-q',
    '--mode', 'regular',
    '--listen-host', '0.0.0.0',
    '--listen-port', String(MITMDUMP_PORT),
    '--set', `confdir=${confdir}`,
    '--set', 'ssl_insecure=true',
    '--set', 'connection_strategy=lazy',
    '-s', ADDON_FILE,
  ];

  const env: Record<string, string> = {
    ...process.env as Record<string, string>,
    IOS_USE_PROXY_EVENTS: eventsFile,
  };
  if (opts.noBody) env.IOS_USE_NO_BODY = '1';
  if (opts.bodyLimit) env.IOS_USE_BODY_LIMIT = String(opts.bodyLimit);

  const proc = spawn('mitmdump', args, { stdio: ['ignore', 'pipe', 'pipe'], env });

  if (opts.stream) {
    proc.stdout?.on('data', (chunk: Buffer) => process.stdout.write(chunk));
  }
  proc.stderr?.on('data', (chunk: Buffer) => process.stderr.write(chunk));

  proc.once('error', (err) => {
    logger.error(`mitmdump failed to start: ${err.message}`);
  });

  try {
    await Promise.race([
      waitForPort(MITMDUMP_PORT, 5000),
      new Promise<never>((_, reject) => {
        proc.once('error', reject);
        proc.once('exit', (code, signal) => reject(new Error(`mitmdump exited before ready: code=${code} signal=${signal}`)));
      }),
    ]);
    return proc;
  } catch (error) {
    try { proc.kill('SIGTERM'); } catch {}
    setTimeout(() => { try { if (!proc.killed) proc.kill('SIGKILL'); } catch {} }, 1000).unref?.();
    throw error;
  }
}

// ── Flow Helpers ──

function flowPath(name: string): string {
  return path.join(FLOWS_DIR, name);
}

async function runFlow(name: string, opts?: { udid?: string; vars?: Record<string, unknown> }): Promise<void> {
  const file = flowPath(name);
  if (!fs.existsSync(file)) {
    throw new Error(`Flow file not found: ${file}`);
  }

  await flowAction(file, { udid: opts?.udid, vars: opts?.vars });
}

// ── Commands ──

export async function proxyConfigCA(
  _client: DriverClient,
  opts: { udid?: string },
): Promise<void> {
  const mitmproxyDir = path.join(process.env.HOME || '', '.mitmproxy');
  const caPath = path.join(mitmproxyDir, 'mitmproxy-ca-cert.pem');

  if (!fs.existsSync(caPath)) {
    logger.info('Generating mitmproxy CA (first run)...');
    await generateMitmproxyCA(mitmproxyDir);
  }

  if (!fs.existsSync(caPath)) {
    throw new Error('CA_NOT_GENERATED: Failed to generate mitmproxy CA.');
  }

  // Convert PEM to DER base64
  const caPem = fs.readFileSync(caPath, 'utf-8');
  const caBase64 = caPem
    .replace(/-----BEGIN CERTIFICATE-----/, '')
    .replace(/-----END CERTIFICATE-----/, '')
    .replace(/\s/g, '');

  // Push CA to driver
  logger.info('Pushing CA certificate to device...');
  await _client.proxyCAPush(caBase64);

  // Run flow to install + trust the CA (single combined flow)
  logger.info('Installing and trusting CA on device...');
  await runFlow('proxy_configca.yaml', { udid: opts.udid });

  // Update state
  const state = readProxyState() || {
    sessionId: `proxy-${Date.now()}`,
    status: 'stopped' as const,
    startedAt: Date.now(),
    udid: opts.udid || '',
    eventsFile: EVENTS_FILE,
  };
  writeState({ ...state, caInstalled: true });
  if (opts.udid) {
    writeCAState({
      udid: opts.udid,
      fingerprint: fingerprintPem(caPem),
      installedAt: Date.now(),
    });
  }

  logger.success('CA installed and trusted on device.');
}

export async function proxyStart(
  _client: DriverClient,
  opts: { udid?: string; stream?: boolean; noBody?: boolean; bodyLimit?: number },
): Promise<void> {
  const state = readProxyState();
  if (state?.status === 'running' && isProcessAlive(state.mitmdumpPid)) {
    throw new Error('Proxy already running. Run `proxy stop` first.');
  }

  const mitmproxyDir = path.join(process.env.HOME || '', '.mitmproxy');
  const caPath = path.join(mitmproxyDir, 'mitmproxy-ca-cert.pem');
  if (!fs.existsSync(caPath)) {
    logger.info('Generating mitmproxy CA...');
    await generateMitmproxyCA(mitmproxyDir);
  }
  if (!fs.existsSync(caPath)) {
    throw new Error('CA_NOT_GENERATED: Failed to generate mitmproxy CA.');
  }

  const caPem = fs.readFileSync(caPath, 'utf-8');
  const caState = readCAState();
  const caReady = !!opts.udid && !!caPem && caState?.udid === opts.udid && caState?.fingerprint === fingerprintPem(caPem);
  if (!caReady) {
    logger.warn('CA not configured. Run `proxy configca` first for HTTPS decryption.');
  }

  ensureStateDir();
  fs.writeFileSync(EVENTS_FILE, '');

  logger.info('Detecting Mac Wi-Fi...');
  const wifi = detectWifiInfo();
  logger.info(`Wi-Fi: ${wifi.interface}, ${wifi.macLanIp}`);
  await verifyDeviceCanReachMac(_client, wifi.macLanIp);

  logger.info('Starting mitmdump...');
  mitmdumpProc = await startMitmdump(mitmproxyDir, EVENTS_FILE, {
    stream: opts.stream,
    noBody: opts.noBody,
    bodyLimit: opts.bodyLimit,
  });

  logger.info('Configuring device Wi-Fi proxy...');
  await runFlow('proxy_set_wifi_proxy.yaml', {
    udid: opts.udid,
    vars: { server: wifi.macLanIp, port: String(MITMDUMP_PORT) },
  });

  await verifyProxyTraffic(_client, EVENTS_FILE);

  const now = Date.now();
  writeState({
    sessionId: `proxy-${now}`,
    status: 'running',
    startedAt: now,
    udid: opts.udid || '',
    eventsFile: EVENTS_FILE,
    caInstalled: caReady,
    network: wifi,
    mitmdumpPid: mitmdumpProc?.pid,
    mitmdumpPort: MITMDUMP_PORT,
  });

  logger.success(`Proxy started. Traffic: device → ${wifi.macLanIp}:${MITMDUMP_PORT} → mitmdump`);
}

export async function proxyStop(
  _client: DriverClient,
  opts: { udid?: string; force?: boolean } = {},
): Promise<void> {
  const state = readProxyState();

  // First: clear the proxy on device (before stopping mitmdump!)
  logger.info('Clearing device Wi-Fi proxy...');
  const targetUdid = opts.udid || state?.udid;
  try {
    await runFlow('proxy_clear_wifi_proxy.yaml', { udid: targetUdid });
  } catch (err) {
    logger.warn(`Failed to clear Wi-Fi proxy via flow: ${err}`);
    logger.warn('Manually disable Wi-Fi proxy: Settings → Wi-Fi → current network (i) → Configure Proxy → Off');
  }

  // Then stop mitmdump
  if (mitmdumpProc) {
    mitmdumpProc.kill('SIGTERM');
    await new Promise<void>(resolve => {
      const timer = setTimeout(() => { mitmdumpProc?.kill('SIGKILL'); resolve(); }, 3000);
      mitmdumpProc!.on('exit', () => { clearTimeout(timer); resolve(); });
    });
    mitmdumpProc = null;
  }
  await killPid(state?.mitmdumpPid);

  if (state) {
    writeState({ ...state, status: 'stopped', stoppedAt: Date.now(), mitmdumpPid: undefined });
  }

  logger.success('Proxy stopped.');
}

export function proxyRead(opts: { count?: number; duration?: string; save?: string }): void {
  const state = readProxyState();
  if (!state?.eventsFile) throw new Error('No recent proxy session.');
  if (!fs.existsSync(state.eventsFile)) throw new Error(`Events file not found: ${state.eventsFile}`);

  const lines = fs.readFileSync(state.eventsFile, 'utf-8').split('\n').filter(Boolean);
  const since = opts.duration ? Date.now() - parseDurationMs(opts.duration) : 0;
  const filtered = since > 0
    ? lines.filter(line => {
        try {
          const ev = JSON.parse(line);
          return (ev.finishedAt ?? ev.startedAt ?? 0) >= since;
        } catch { return false; }
      })
    : lines;
  const selected = filtered.slice(-Math.max(1, opts.count ?? 10));

  if (opts.save !== undefined) {
    const dir = path.join(IOS_USE_HOME, 'artifacts');
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    const name = typeof opts.save === 'string' && opts.save.length > 0
      ? opts.save.replace(/[^A-Za-z0-9._-]/g, '_')
      : `proxy-${new Date().toISOString().replace(/[:.]/g, '-')}.jsonl`;
    const out = path.join(dir, name.endsWith('.jsonl') ? name : `${name}.jsonl`);
    fs.writeFileSync(out, selected.join('\n') + (selected.length ? '\n' : ''));
    logger.success(`Saved ${selected.length} events to ${out}`);
    return;
  }

  for (const line of selected) console.log(line);
}

export function proxyDoctor(): void {
  const checks: Array<{ name: string; ok: boolean; fix: string; warn?: boolean }> = [];

  try {
    execFileSync('mitmdump', ['--version'], { stdio: 'pipe' });
    checks.push({ name: 'mitmdump installed', ok: true, fix: '' });
  } catch {
    checks.push({ name: 'mitmdump installed', ok: false, fix: 'Install: pip install mitmproxy' });
  }

  const caPath = path.join(process.env.HOME || '', '.mitmproxy', 'mitmproxy-ca-cert.pem');
  const caGenerated = fs.existsSync(caPath);
  checks.push({ name: 'CA generated', ok: caGenerated, fix: 'Run `proxy configca`' });

  try {
    const wifi = detectWifiInfo();
    checks.push({ name: `LAN IP: ${wifi.macLanIp} (${wifi.interface})`, ok: true, fix: '' });
  } catch (err) {
    checks.push({ name: 'Mac Wi-Fi', ok: false, fix: String(err) });
  }

  const state = readProxyState();
  const caState = readCAState();
  let caMatches = false;
  if (caGenerated && caState) {
    const caPem = fs.readFileSync(caPath, 'utf-8');
    caMatches = caState.fingerprint === fingerprintPem(caPem);
  }
  checks.push({ name: 'CA installed on device', ok: !!caState && caMatches, fix: 'Run `proxy configca`' });
  checks.push({
    name: 'Proxy running',
    ok: state?.status === 'running' && isProcessAlive(state.mitmdumpPid),
    fix: 'Run `proxy start`',
  });

  console.log('\nProxy Doctor:\n');
  for (const c of checks) {
    const icon = c.ok ? (c.warn ? '!' : '✓') : '✗';
    console.log(`  ${icon} ${c.name}`);
    if (!c.ok && c.fix) console.log(`    → ${c.fix}`);
  }
  console.log('');
}
