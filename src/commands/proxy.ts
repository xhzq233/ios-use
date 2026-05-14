import net from 'node:net';
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'fs';
import path from 'path';
import { execFileSync, spawn, type ChildProcess } from 'child_process';
import { fileURLToPath } from 'url';
import { IOS_USE_HOME } from '../utils/paths.js';
import { logger } from '../utils/logger.js';
import { isProcessAlive } from '../utils/process.js';
import { DriverClient } from '../driver-client/client.js';
import { DRIVER_COMMANDS } from '../driver-protocol/index.js';
import { runFlowFile } from './flow.js';
import {
  DEFAULT_DRIVER_HOST,
  MITMPROXY_CA_GENERATION_POLL_MS,
  MITMPROXY_CA_GENERATION_TIMEOUT_MS,
  PROXY_LAN_PROBE_POLL_MS,
  PROXY_LAN_PROBE_TIMEOUT_MS,
  PROXY_FORCED_KILL_DELAY_MS,
  PROXY_MITMDUMP_PORT,
  PROXY_PROCESS_GRACE_MS,
  PROXY_PROCESS_POLL_MS,
  PROXY_WAIT_PORT_POLL_MS,
} from '../constants.js';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEV_FLOWS_DIR = path.join(MODULE_DIR, '../../flows');
let proxyHome = IOS_USE_HOME;
let flowRunner = runFlowFile;

type ForyProtocol = typeof import('../driver-protocol/fory.js');

let foryProtocolPromise: Promise<ForyProtocol> | null = null;

function loadForyProtocol(): Promise<ForyProtocol> {
  foryProtocolPromise ??= import('../driver-protocol/fory.js');
  return foryProtocolPromise;
}

export interface ProxySessionState {
  sessionId: string;
  status: 'running' | 'stopped';
  startedAt: number;
  stoppedAt?: number;
  udid: string;
  flowFile: string;
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

interface ProxyCADevice {
  fingerprint: string;
  installedAt: number;
}

type ProxyCAState = Record<string, ProxyCADevice>;

let mitmdumpProc: ChildProcess | null = null;

// ── Utilities ──

function stateFile(): string {
  return path.join(proxyHome, 'state', 'proxy-session.json');
}

function caStateFile(): string {
  return path.join(proxyHome, 'state', 'proxy-ca.json');
}

function flowsDir(): string {
  const userFlows = path.join(proxyHome, 'flows');
  return fs.existsSync(userFlows) ? userFlows : DEV_FLOWS_DIR;
}

export function setProxyTestOverrides(opts: {
  iosUseHome?: string | null;
  flowRunner?: typeof runFlowFile | null;
}): void {
  proxyHome = opts.iosUseHome ?? IOS_USE_HOME;
  flowRunner = opts.flowRunner ?? runFlowFile;
}

export function readProxyState(): ProxySessionState | null {
  const file = stateFile();
  if (!fs.existsSync(file)) return null;
  try { return JSON.parse(fs.readFileSync(file, 'utf-8')); } catch { return null; }
}

function writeState(state: ProxySessionState): void {
  fs.mkdirSync(path.dirname(stateFile()), { recursive: true });
  fs.writeFileSync(stateFile(), JSON.stringify(state, null, 2) + '\n');
}

function readCAState(): ProxyCAState {
  const file = caStateFile();
  if (!fs.existsSync(file)) return {};
  try { return JSON.parse(fs.readFileSync(file, 'utf-8')); } catch { return {}; }
}

function writeCAState(state: ProxyCAState): void {
  fs.mkdirSync(path.dirname(caStateFile()), { recursive: true });
  fs.writeFileSync(caStateFile(), JSON.stringify(state, null, 2) + '\n');
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
  const deadline = Date.now() + PROXY_PROCESS_GRACE_MS;
  while (Date.now() < deadline) {
    if (!isProcessAlive(pid)) return;
    await new Promise(r => setTimeout(r, PROXY_PROCESS_POLL_MS));
  }
  if (isProcessAlive(pid)) process.kill(pid, 'SIGKILL');
}

function runText(cmd: string, args: string[]): string {
  return execFileSync(cmd, args, { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

// ── LAN Detection ──

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

function getInterfaceIPv4(iface: string): string | null {
  let out: string;
  try {
    out = runText('ifconfig', [iface]);
  } catch {
    return null;
  }
  if (!/status:\s*active/.test(out)) return null;
  const ip = out.match(/\binet\s+(\d+\.\d+\.\d+\.\d+)\b/)?.[1];
  if (!ip || ip.startsWith('127.') || ip.startsWith('169.254.')) return null;
  return ip;
}

function detectLanInfo(interfaceName?: string): WifiInfo {
  const iface = interfaceName || getWifiInterface();
  const macLanIp = getInterfaceIPv4(iface);
  if (!macLanIp) throw new Error(`MAC_LAN_IP_NOT_FOUND: ${iface}`);
  return { interface: iface, macLanIp };
}

// ── mitmdump ──

function waitForPort(port: number, timeoutMs: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeoutMs;
    const tryConnect = () => {
      const sock = net.createConnection(port, DEFAULT_DRIVER_HOST);
      sock.on('connect', () => { sock.destroy(); resolve(); });
      sock.on('error', () => {
        sock.destroy();
        if (Date.now() > deadline) reject(new Error(`Port ${port} not ready after ${timeoutMs}ms`));
        else setTimeout(tryConnect, PROXY_WAIT_PORT_POLL_MS);
      });
    };
    tryConnect();
  });
}

async function verifyDeviceCanReachMac(client: DriverClient, macLanIp: string): Promise<void> {
  const token = crypto.randomUUID();
  let received = false;
  const server = http.createServer((req, res) => {
    if (req.url === `/${token}`) {
      received = true;
      logger.info(`LAN probe verified: ${req.method} ${req.url} from ${req.socket.remoteAddress}`);
    }
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('ok');
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
    await new Promise<void>(resolve => server.close(() => resolve()));
    throw new Error('LAN_PROBE_SERVER_FAILED');
  }
  try {
    logger.info(`Verifying device can reach Mac LAN IP: ${macLanIp}`);
    const url = `http://${macLanIp}:${addr.port}/${token}`;
    const { openURLArgsSer } = await loadForyProtocol();
    const payload = openURLArgsSer.serialize({ url });
    const resp = await client.sendRaw(DRIVER_COMMANDS.OPEN_URL, payload);
    if (!resp.ok) throw new Error(`openURL failed: ${resp.error}`);

    const deadline = Date.now() + PROXY_LAN_PROBE_TIMEOUT_MS;
    while (Date.now() < deadline) {
      await new Promise(r => setTimeout(r, PROXY_LAN_PROBE_POLL_MS));
      if (received) return;
    }
    throw new Error(
      `DEVICE_CANNOT_REACH_MAC: probe server received no requests to http://${macLanIp}:${addr.port}/${token}. ` +
      `Ensure the iPhone is on the same WiFi and the network allows device-to-device communication (no AP isolation).`,
    );
  } finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
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
    }, MITMPROXY_CA_GENERATION_POLL_MS);
    const fallback = setTimeout(() => { clearInterval(check); proc.kill('SIGKILL'); done(); }, MITMPROXY_CA_GENERATION_TIMEOUT_MS);
  });
}

async function startMitmdump(confdir: string, flowFile: string): Promise<ChildProcess> {
  const args = [
    '-q',
    '--mode', 'regular',
    '--listen-host', '0.0.0.0',
    '--listen-port', String(PROXY_MITMDUMP_PORT),
    '--set', `confdir=${confdir}`,
    '--set', 'ssl_insecure=true',
    '--set', 'connection_strategy=lazy',
    '--set', `save_stream_file=${flowFile}`,
  ];

  const proc = spawn('mitmdump', args, {
    stdio: ['ignore', 'ignore', 'ignore'],
    detached: true,
  });
  proc.unref();

  proc.once('error', (err) => {
    logger.error(`mitmdump failed to start: ${err.message}`);
  });

  try {
    await Promise.race([
      waitForPort(PROXY_MITMDUMP_PORT, PROXY_LAN_PROBE_TIMEOUT_MS),
      new Promise<never>((_, reject) => {
        proc.once('error', reject);
        proc.once('exit', (code, signal) => reject(new Error(`mitmdump exited before ready: code=${code} signal=${signal}`)));
      }),
    ]);
    return proc;
  } catch (error) {
    try { proc.kill('SIGTERM'); } catch {}
    setTimeout(() => { try { if (!proc.killed) proc.kill('SIGKILL'); } catch {} }, PROXY_FORCED_KILL_DELAY_MS).unref?.();
    throw error;
  }
}

// ── Flow Helpers ──

function flowPath(name: string): string {
  return path.join(flowsDir(), name);
}

async function runFlow(client: DriverClient, name: string, opts?: { udid?: string; vars?: Record<string, unknown> }): Promise<void> {
  const file = flowPath(name);
  if (!fs.existsSync(file)) {
    throw new Error(`Flow file not found: ${file}`);
  }

  await client.terminateApp('com.apple.Preferences');
  await client.activateApp('com.apple.Preferences');
  await flowRunner(client, file, { udid: opts?.udid, flowApp: 'com.apple.Preferences' }, opts?.vars);
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
  await runFlow(_client, 'proxy_configca.yaml', { udid: opts.udid });

  // Update state
  const state = readProxyState() || {
    sessionId: `proxy-${Date.now()}`,
    status: 'stopped' as const,
    startedAt: Date.now(),
    udid: opts.udid || '',
    flowFile: '',
  };
  writeState({ ...state, caInstalled: true });
  if (opts.udid) {
    const caState = readCAState();
    caState[opts.udid] = {
      fingerprint: fingerprintPem(caPem),
      installedAt: Date.now(),
    };
    writeCAState(caState);
  }

  logger.success('CA installed and trusted on device.');
}

export async function proxyStart(
  _client: DriverClient,
  opts: { udid?: string; interfaceName?: string },
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
  const caDevice = opts.udid ? caState[opts.udid] : undefined;
  const caReady = !!caDevice && !!caPem && caDevice.fingerprint === fingerprintPem(caPem);
  if (!caReady) {
    logger.info('CA trust record not found. HTTP capture can still work; HTTPS decryption requires the CA to be installed and trusted.');
  }

  const artifactsDir = path.join(proxyHome, 'artifacts');
  if (!fs.existsSync(artifactsDir)) fs.mkdirSync(artifactsDir, { recursive: true });
  const flowFile = path.join(artifactsDir, `proxy-${new Date().toISOString().replace(/[:.]/g, '-')}.flow`);

  const wifi = detectLanInfo(opts.interfaceName);
  logger.info(`${opts.interfaceName ? 'Using requested interface' : 'Using Wi-Fi interface'}: ${wifi.interface}, ${wifi.macLanIp}`);
  await verifyDeviceCanReachMac(_client, wifi.macLanIp);

  logger.info('Starting mitmdump...');
  try {
    mitmdumpProc = await startMitmdump(mitmproxyDir, flowFile);

    logger.info('Configuring device Wi-Fi proxy...');
    await runFlow(_client, 'proxy_set_wifi_proxy.yaml', {
      udid: opts.udid,
      vars: { server: wifi.macLanIp, port: String(PROXY_MITMDUMP_PORT) },
    });
  } catch (error) {
    const pid = mitmdumpProc?.pid;
    try { mitmdumpProc?.kill('SIGTERM'); } catch {}
    mitmdumpProc = null;
    await killPid(pid);
    throw error;
  }

  const now = Date.now();
  writeState({
    sessionId: `proxy-${now}`,
    status: 'running',
    startedAt: now,
    udid: opts.udid || '',
    flowFile,
    caInstalled: caReady,
    network: wifi,
    mitmdumpPid: mitmdumpProc?.pid,
    mitmdumpPort: PROXY_MITMDUMP_PORT,
  });

  logger.success(`Proxy started. Traffic: device → ${wifi.macLanIp}:${PROXY_MITMDUMP_PORT} → mitmdump`);
  logger.info(`Capture: ${flowFile}`);
  logger.info(`View with: mitmweb -r ${flowFile}`);
}

export async function proxyStop(
  _client: DriverClient,
  opts: { udid?: string } = {},
): Promise<void> {
  const state = readProxyState();

  // First: clear the proxy on device (before stopping mitmdump!)
  const targetUdid = opts.udid || state?.udid;
  logger.info('Clearing device Wi-Fi proxy...');
  try {
    await runFlow(_client, 'proxy_clear_wifi_proxy.yaml', { udid: targetUdid });
  } catch (err) {
    logger.warn(`Failed to clear Wi-Fi proxy via flow: ${err}`);
    throw new Error('Unable to clear device Wi-Fi proxy. Manually disable Wi-Fi proxy: Settings -> Wi-Fi -> current network (i) -> Configure Proxy -> Off, then retry `ios-use proxy stop`.');
  }

  // Then stop mitmdump
  if (mitmdumpProc) {
    mitmdumpProc.kill('SIGTERM');
    await new Promise<void>(resolve => {
      const timer = setTimeout(() => { mitmdumpProc?.kill('SIGKILL'); resolve(); }, PROXY_PROCESS_GRACE_MS);
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

export function proxyDoctor(): void {
  const checks: Array<{ name: string; status: 'ok' | 'fail' | 'info' | 'warn'; fix?: string }> = [];

  try {
    execFileSync('mitmdump', ['--version'], { stdio: 'pipe' });
    checks.push({ name: 'mitmdump installed', status: 'ok' });
  } catch {
    logger.info('mitmdump not found, installing mitmproxy...');
    try {
      const pip = ['pip3', 'pip'].find(p => { try { execFileSync(p, ['--version'], { stdio: 'pipe' }); return true; } catch { return false; } });
      if (!pip) throw new Error('pip not found');
      execFileSync(pip, ['install', 'mitmproxy'], { stdio: 'inherit' });
      execFileSync('mitmdump', ['--version'], { stdio: 'pipe' });
      checks.push({ name: 'mitmdump installed', status: 'ok' });
    } catch (installErr) {
      checks.push({ name: 'mitmdump installed', status: 'fail', fix: `Install failed: ${installErr}. Manual: pip install mitmproxy` });
    }
  }

  const caPath = path.join(process.env.HOME || '', '.mitmproxy', 'mitmproxy-ca-cert.pem');
  const caGenerated = fs.existsSync(caPath);
  checks.push({ name: 'CA generated', status: caGenerated ? 'ok' : 'fail', fix: 'Run `proxy configca`' });

  try {
    const wifi = detectLanInfo();
    checks.push({ name: `Wi-Fi LAN IP: ${wifi.macLanIp} (${wifi.interface})`, status: 'ok' });
  } catch (err) {
    checks.push({ name: 'Mac Wi-Fi LAN IP', status: 'fail', fix: String(err) });
  }

  const state = readProxyState();
  const caState = readCAState();
  const caDeviceCount = Object.keys(caState).length;
  let caCurrent = false;
  if (caGenerated && caDeviceCount > 0) {
    const caPem = fs.readFileSync(caPath, 'utf-8');
    const fp = fingerprintPem(caPem);
    caCurrent = Object.values(caState).some(d => d.fingerprint === fp);
  }
  checks.push({
    name: caCurrent
      ? `CA trust record: current CA recorded (${caDeviceCount} device(s))`
      : caDeviceCount > 0
        ? `CA trust record: ${caDeviceCount} device(s) recorded, but CA fingerprint mismatch`
        : 'CA trust record: not recorded',
    status: caCurrent ? 'ok' : 'info',
    fix: caCurrent ? undefined : 'Run `proxy configca` to record CA install/trust state',
  });

  const running = state?.status === 'running' && isProcessAlive(state.mitmdumpPid);
  checks.push({ name: running ? 'Proxy: running' : 'Proxy: not running', status: running ? 'ok' : 'info' });

  console.log('\nProxy Doctor:\n');
  for (const c of checks) {
    const icon = c.status === 'ok' ? '✓' : c.status === 'fail' ? '✗' : c.status === 'warn' ? '!' : '-';
    console.log(`  ${icon} ${c.name}`);
    if (c.status !== 'ok' && c.fix) console.log(`    → ${c.fix}`);
  }
  console.log('');
}
