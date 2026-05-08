import net from 'node:net';
import fs from 'fs';
import path from 'path';
import readline from 'node:readline/promises';
import { execFileSync, spawn, type ChildProcess } from 'child_process';
import { IOS_USE_HOME } from '../utils/paths.js';
import { logger } from '../utils/logger.js';
import type { DriverClient } from '../driver-client/client.js';

const MITMDUMP_PORT = 9080;
const PROFILE_PORT = 9088;
const STATE_FILE = path.join(IOS_USE_HOME, 'state', 'proxy-session.json');
const EVENTS_FILE = path.join(IOS_USE_HOME, 'state', 'proxy-events.jsonl');
const ADDON_FILE = path.join(IOS_USE_HOME, 'state', 'proxy_jsonl_addon.py');
const LOG_FILE = path.join(IOS_USE_HOME, 'logs', 'proxy.log');
const CLEANUP_CONFIRM_TIMEOUT_MS = 10 * 60 * 1000;

type UnknownState = 'unknown' | 'yes' | 'no';

export interface ProxySessionState {
  sessionId: string;
  status: 'running' | 'stopped';
  startedAt: number;
  stoppedAt?: number;
  udid: string;
  eventsFile: string;
  logFile: string;
  network?: {
    ssid: string;
    interface: string;
    macLanIp: string;
  };
  mac: {
    mitmdumpHost: string;
    mitmdumpPort: number;
    mitmdumpPid?: number;
  };
  profileServer?: {
    port: number;
    pushed: boolean;
  };
  profiles: {
    ca: {
      payloadIdentifier: string;
      displayName: string;
      installed: UnknownState;
      trusted: UnknownState;
    };
    wifiProxy: {
      payloadIdentifier: string;
      displayName: string;
      pushed: boolean;
      installed: UnknownState;
      cleanup: UnknownState;
      removal: UnknownState;
    };
  };
}

interface WifiInfo {
  interface: string;
  ssid: string;
  macLanIp: string;
}

interface GeneratedProfiles {
  caDerBase64: string;
  caProfileBase64: string;
  proxyProfileBase64: string;
  cleanupProfileBase64: string;
}

let mitmdumpProc: ChildProcess | null = null;

function ensureStateDir(): void {
  const dir = path.dirname(STATE_FILE);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  const logDir = path.dirname(LOG_FILE);
  if (!fs.existsSync(logDir)) fs.mkdirSync(logDir, { recursive: true });
}

export function readProxyState(): ProxySessionState | null {
  if (!fs.existsSync(STATE_FILE)) return null;
  try { return JSON.parse(fs.readFileSync(STATE_FILE, 'utf-8')); } catch { return null; }
}

function writeState(state: ProxySessionState): void {
  ensureStateDir();
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + '\n');
}

function status(msg: string, stream?: boolean): void {
  if (stream) process.stderr.write(`${msg}\n`);
  else logger.info(msg);
}

function warn(msg: string, stream?: boolean): void {
  if (stream) process.stderr.write(`WARN: ${msg}\n`);
  else logger.warn(msg);
}

function success(msg: string, stream?: boolean): void {
  if (stream) process.stderr.write(`${msg}\n`);
  else logger.success(msg);
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

function isPidAlive(pid: number | undefined): boolean {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function killPid(pid: number | undefined, name: string, errors: string[]): Promise<void> {
  if (!pid || !isPidAlive(pid)) return;
  try {
    process.kill(pid, 'SIGTERM');
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
      if (!isPidAlive(pid)) return;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    if (isPidAlive(pid)) process.kill(pid, 'SIGKILL');
  } catch (err) {
    errors.push(`Failed to stop ${name} pid=${pid}: ${err}`);
  }
}

function runText(cmd: string, args: string[]): string {
  return execFileSync(cmd, args, { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

function getWifiInterface(): string {
  const out = runText('networksetup', ['-listallhardwareports']);
  const lines = out.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (lines[i]?.trim() === 'Hardware Port: Wi-Fi') {
      const device = lines[i + 1]?.match(/Device:\s*(\S+)/)?.[1];
      if (device) return device;
    }
  }
  throw new Error('WIFI_INTERFACE_NOT_FOUND: Could not find macOS Wi-Fi hardware port.');
}

function getWifiSsid(iface: string): string {
  try {
    const out = runText('networksetup', ['-getairportnetwork', iface]);
    const match = out.match(/Current Wi-Fi Network:\s*(.+)$/);
    if (match?.[1]) return match[1].trim();
  } catch {}

  try {
    const out = runText('wdutil', ['info']);
    const match = out.match(/SSID\s*:\s*(.+)$/m);
    if (match?.[1]) return match[1].trim();
  } catch {}

  try {
    const out = runText('system_profiler', ['SPAirPortDataType']);
    const lines = out.split('\n');
    const currentIndex = lines.findIndex(line => line.includes('Current Network Information:'));
    if (currentIndex >= 0) {
      for (const line of lines.slice(currentIndex + 1)) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        if (trimmed.endsWith(':')) return trimmed.slice(0, -1);
        if (/^(PHY Mode|Channel|Country Code|Network Type|Security|Signal|Transmit Rate|MCS Index):/.test(trimmed)) break;
      }
    }
  } catch {}

  throw new Error(`WIFI_SSID_NOT_FOUND: Could not detect current SSID for ${iface}.`);
}

function detectWifiInfo(): WifiInfo {
  const iface = getWifiInterface();
  const ssid = getWifiSsid(iface);
  let macLanIp = '';
  try {
    macLanIp = runText('ipconfig', ['getifaddr', iface]);
  } catch {
    throw new Error(`MAC_LAN_IP_NOT_FOUND: Could not detect IPv4 address for ${iface}.`);
  }
  if (!macLanIp) throw new Error(`MAC_LAN_IP_NOT_FOUND: Could not detect IPv4 address for ${iface}.`);
  return { interface: iface, ssid, macLanIp };
}

export async function proxyStart(
  client: DriverClient,
  opts: { udid: string; stream?: boolean },
): Promise<void> {
  const existing = readProxyState();
  if (existing?.status === 'running') {
    if (isPidAlive(existing.mac?.mitmdumpPid)) {
      throw new Error('Proxy already running. Run `proxy stop` first.');
    }
    warn('Found stale proxy session state; overwriting it.', opts.stream);
  }

  ensureStateDir();
  fs.writeFileSync(EVENTS_FILE, '');

  const mitmproxyDir = path.join(process.env.HOME || '', '.mitmproxy');
  const caPath = path.join(mitmproxyDir, 'mitmproxy-ca-cert.pem');
  if (!fs.existsSync(caPath)) {
    status('Generating mitmproxy CA (first run)...', opts.stream);
    await generateMitmproxyCA(mitmproxyDir);
  }

  status('Detecting Mac Wi-Fi network...', opts.stream);
  const wifi = detectWifiInfo();
  status(`Wi-Fi: ${wifi.ssid} (${wifi.interface}, ${wifi.macLanIp})`, opts.stream);

  status('Starting mitmdump on LAN...', opts.stream);
  killExistingMitmdump();
  mitmdumpProc = await startMitmdump(mitmproxyDir, EVENTS_FILE, opts.stream);

  status('Starting device profile server...', opts.stream);
  const profileServer = await client.proxyIngressStart({ profilePort: PROFILE_PORT });

  status('Generating CA and Wi-Fi proxy profiles...', opts.stream);
  const profiles = generateProfiles(caPath, {
    ssid: wifi.ssid,
    proxyHost: wifi.macLanIp,
    proxyPort: MITMDUMP_PORT,
  });
  await client.proxyPushProfile(
    profiles.caDerBase64,
    profiles.proxyProfileBase64,
    {
      caProfileBase64: profiles.caProfileBase64,
      cleanupMobileconfigBase64: profiles.cleanupProfileBase64,
    },
  );
  status('Profiles pushed to driver', opts.stream);

  const installUrl = `http://127.0.0.1:${profileServer.profilePort}/install`;
  try {
    status('Opening profile install page on device...', opts.stream);
    await openDeviceUrl(client, opts.udid, installUrl);
  } catch (err) {
    warn(`Could not open install page (${err}); open Safari on the device and visit ${installUrl}`, opts.stream);
  }

  const now = Date.now();
  writeState({
    sessionId: `proxy-${now}`,
    status: 'running',
    startedAt: now,
    udid: opts.udid,
    eventsFile: EVENTS_FILE,
    logFile: LOG_FILE,
    network: wifi,
    mac: {
      mitmdumpHost: '0.0.0.0',
      mitmdumpPort: MITMDUMP_PORT,
      mitmdumpPid: mitmdumpProc?.pid,
    },
    profileServer: {
      port: profileServer.profilePort,
      pushed: true,
    },
    profiles: {
      ca: {
        payloadIdentifier: 'com.ios-use.proxy.ca',
        displayName: 'ios-use CA Profile',
        installed: 'unknown',
        trusted: 'unknown',
      },
      wifiProxy: {
        payloadIdentifier: 'com.ios-use.proxy.wifi',
        displayName: 'ios-use Proxy Wi-Fi Profile',
        pushed: true,
        installed: 'unknown',
        cleanup: 'unknown',
        removal: 'unknown',
      },
    },
  });

  success('Proxy started', opts.stream);
  status(`Profile install page: ${installUrl}`, opts.stream);
  status(`Install/update "ios-use Proxy Wi-Fi Profile" for SSID "${wifi.ssid}".`, opts.stream);
  status('First run only: install "ios-use CA Profile" and enable full trust in Certificate Trust Settings.', opts.stream);
}

export async function proxyStop(client: DriverClient, opts: { force?: boolean } = {}): Promise<void> {
  const errors: string[] = [];
  const state = readProxyState();

  if (state?.profileServer?.port) {
    const cleanupUrl = `http://127.0.0.1:${state.profileServer.port}/cleanup.mobileconfig`;
    logger.warn('Attempting to open cleanup Wi-Fi profile before stopping mitmdump.');
    logger.warn('Install it to turn off the ios-use Wi-Fi proxy for the current SSID.');
    try {
      await openDeviceUrl(client, state.udid, cleanupUrl);
    } catch (err) {
      errors.push(`Failed to open cleanup profile: ${err}`);
    }
  }

  if (opts.force) {
    logger.warn('Force stop requested. If the proxy profile remains installed, this device may lose Wi-Fi connectivity.');
  } else {
    logger.warn('If cleanup profile is not installed, remove the proxy profile manually before relying on normal Wi-Fi:');
    logger.warn('Settings -> General -> VPN & Device Management -> ios-use Proxy Wi-Fi Profile -> Remove Profile');
    const confirmed = await waitForCleanupConfirmation(CLEANUP_CONFIRM_TIMEOUT_MS);
    if (!confirmed) {
      logger.warn('Cleanup was not confirmed. Keeping mitmdump running to avoid breaking device Wi-Fi.');
      logger.warn(`Run \`bun run src/cli.ts proxy stop --force\` after cleanup, or stop pid ${state?.mac?.mitmdumpPid ?? mitmdumpProc?.pid ?? 'unknown'} manually.`);
      if (state) {
        writeState({
          ...state,
          profiles: {
            ...state.profiles,
            wifiProxy: {
              ...state.profiles.wifiProxy,
              cleanup: 'unknown',
              removal: 'unknown',
            },
          },
        });
      }
      return;
    }
  }

  if (mitmdumpProc) {
    mitmdumpProc.kill('SIGTERM');
    const killed = await new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => { mitmdumpProc?.kill('SIGKILL'); resolve(false); }, 3000);
      mitmdumpProc!.on('exit', () => { clearTimeout(timer); resolve(true); });
    });
    if (!killed) logger.warn('mitmdump did not exit gracefully, killed');
    mitmdumpProc = null;
  }
  await killPid(state?.mac?.mitmdumpPid, 'mitmdump', errors);

  try {
    await client.proxyIngressStop();
    logger.info('Profile server stopped');
  } catch (err) {
    errors.push(`Failed to stop profile server: ${err}`);
  }

  if (state) {
    writeState({
      ...state,
      status: 'stopped',
      stoppedAt: Date.now(),
      mac: { ...state.mac, mitmdumpPid: undefined },
      profiles: {
        ...state.profiles,
        wifiProxy: {
          ...state.profiles.wifiProxy,
          cleanup: opts.force ? 'unknown' : 'yes',
          removal: 'unknown',
        },
      },
    });
  }

  if (errors.length) {
    for (const e of errors) logger.warn(e);
  }

  logger.success('Proxy stopped');
}

async function waitForCleanupConfirmation(timeoutMs: number): Promise<boolean> {
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    logger.warn('Non-interactive terminal; cannot confirm cleanup automatically.');
    return false;
  }

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    const timeout = new Promise<null>(resolve => setTimeout(() => resolve(null), timeoutMs));
    const answer = await Promise.race([
      rl.question('Press Enter after cleanup/removal is complete: '),
      timeout,
    ]);
    if (answer === null) return false;
    return true;
  } finally {
    rl.close();
  }
}

export function proxyRead(opts: { count?: number; duration?: string; save?: string }): void {
  const state = readProxyState();
  if (!state?.eventsFile) throw new Error('No recent proxy session.');
  if (!fs.existsSync(state.eventsFile)) throw new Error(`Proxy events file not found: ${state.eventsFile}`);

  const lines = fs.readFileSync(state.eventsFile, 'utf-8')
    .split('\n')
    .filter(Boolean);
  const since = opts.duration ? Date.now() - parseDurationMs(opts.duration) : 0;
  const filtered = since > 0
    ? lines.filter((line) => {
      try {
        const event = JSON.parse(line) as { finishedAt?: number; startedAt?: number };
        return (event.finishedAt ?? event.startedAt ?? 0) >= since;
      } catch {
        return false;
      }
    })
    : lines;
  const selected = filtered.slice(-Math.max(1, opts.count ?? 10));

  if (opts.save !== undefined) {
    const artifactsDir = path.join(IOS_USE_HOME, 'artifacts');
    if (!fs.existsSync(artifactsDir)) fs.mkdirSync(artifactsDir, { recursive: true });
    const safeName = typeof opts.save === 'string' && opts.save.length > 0
      ? opts.save.replace(/[^A-Za-z0-9._-]/g, '_')
      : `proxy-${new Date().toISOString().replace(/[:.]/g, '-')}.jsonl`;
    const out = path.join(artifactsDir, safeName.endsWith('.jsonl') ? safeName : `${safeName}.jsonl`);
    fs.writeFileSync(out, selected.join('\n') + (selected.length ? '\n' : ''));
    logger.success(`Saved ${selected.length} events to ${out}`);
    return;
  }

  for (const line of selected) console.log(line);
}

export function proxyDoctor(): void {
  const checks: Array<{ name: string; ok: boolean; fix: string }> = [];

  try {
    execFileSync('mitmdump', ['--version'], { stdio: 'pipe' });
    checks.push({ name: 'mitmdump installed', ok: true, fix: '' });
  } catch {
    checks.push({ name: 'mitmdump installed', ok: false, fix: 'Install mitmproxy: pip install mitmproxy' });
  }

  const caPath = path.join(process.env.HOME || '', '.mitmproxy', 'mitmproxy-ca-cert.pem');
  checks.push({ name: 'CA generated', ok: fs.existsSync(caPath), fix: 'Run `proxy start` to auto-generate' });

  try {
    const wifi = detectWifiInfo();
    checks.push({ name: `Mac Wi-Fi SSID (${wifi.ssid})`, ok: true, fix: '' });
    checks.push({ name: `Mac LAN IP (${wifi.interface}: ${wifi.macLanIp})`, ok: true, fix: '' });
  } catch (err) {
    checks.push({ name: 'Mac Wi-Fi/LAN detection', ok: false, fix: String(err) });
  }

  const state = readProxyState();
  checks.push({
    name: 'proxy session active',
    ok: state?.status === 'running' && isPidAlive(state.mac?.mitmdumpPid),
    fix: 'Run `proxy start`',
  });

  console.log('\nProxy Doctor:\n');
  for (const c of checks) {
    const icon = c.ok ? '✅' : '❌';
    console.log(`  ${icon} ${c.name}`);
    if (!c.ok && c.fix) console.log(`     → ${c.fix}`);
  }
  console.log('');
}

async function openDeviceUrl(client: DriverClient, udid: string | undefined, url: string): Promise<void> {
  try {
    await client.openURL(url);
    return;
  } catch (driverErr) {
    if (!udid) throw driverErr;
    try {
      execFileSync('xcrun', [
        'devicectl',
        'device',
        'process',
        'launch',
        '--device',
        udid,
        '--payload-url',
        url,
        'com.apple.mobilesafari',
      ], { stdio: 'pipe' });
      return;
    } catch {
      throw driverErr;
    }
  }
}

function killExistingMitmdump(): void {
  try {
    execFileSync('pkill', ['-f', `mitmdump.*${MITMDUMP_PORT}`], { stdio: 'ignore' });
  } catch {}
}

async function startMitmdump(confdir: string, eventsFile: string, stream?: boolean): Promise<ChildProcess> {
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

  const proc = spawn('mitmdump', args, {
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, IOS_USE_PROXY_EVENTS: eventsFile },
  });

  const logStream = fs.createWriteStream(LOG_FILE, { flags: 'a' });
  proc.stdout?.pipe(logStream);
  proc.stderr?.pipe(logStream);

  if (stream) {
    proc.stdout?.on('data', (chunk: Buffer) => {
      process.stdout.write(chunk);
    });
  }

  proc.on('error', (err) => {
    logger.error(`mitmdump failed to start: ${err.message}`);
  });

  proc.on('exit', (code) => {
    if (!stream) logger.info(`mitmdump exited with code ${code}`);
    else process.stderr.write(`mitmdump exited with code ${code}\n`);
  });

  await waitForPort(MITMDUMP_PORT, 5000);
  return proc;
}

async function generateMitmproxyCA(confdir: string): Promise<void> {
  if (!fs.existsSync(confdir)) fs.mkdirSync(confdir, { recursive: true });

  const proc = spawn('mitmdump', ['--set', `confdir=${confdir}`, '--listen-port', '0'], {
    stdio: 'ignore',
  });

  await new Promise<void>((resolve) => {
    const check = setInterval(() => {
      if (fs.existsSync(path.join(confdir, 'mitmproxy-ca-cert.pem'))) {
        clearInterval(check);
        proc.kill('SIGTERM');
        resolve();
      }
    }, 200);
    setTimeout(() => { clearInterval(check); proc.kill('SIGKILL'); resolve(); }, 10000);
  });
}

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

function writeMitmdumpAddon(file: string): void {
  const script = String.raw`import json
import os
import time
from mitmproxy import http

events_file = os.environ.get("IOS_USE_PROXY_EVENTS")

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
    body_bytes = len(resp.raw_content or b"") if resp else 0
    _write({
        "id": flow.id,
        "method": req.method,
        "url": req.pretty_url,
        "host": req.pretty_host,
        "status": resp.status_code if resp else None,
        "contentType": resp.headers.get("content-type") if resp else None,
        "bodyBytes": body_bytes,
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

function generateProfiles(
  caPath: string,
  opts: { ssid: string; proxyHost: string; proxyPort: number },
): GeneratedProfiles {
  const caPem = fs.readFileSync(caPath, 'utf-8');
  const caDer = Buffer.from(
    caPem.replace(/-----BEGIN CERTIFICATE-----/, '')
      .replace(/-----END CERTIFICATE-----/, '')
      .replace(/\s/g, ''),
    'base64',
  );
  const caDerBase64 = caDer.toString('base64');
  const caProfile = wrapProfile('ios-use CA Profile', 'com.ios-use.proxy.ca.profile', `
        <dict>
            <key>PayloadType</key>
            <string>com.apple.security.root</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>com.ios-use.proxy.ca</string>
            <key>PayloadUUID</key>
            <string>${uuid()}</string>
            <key>PayloadDisplayName</key>
            <string>ios-use CA Profile</string>
            <key>PayloadDescription</key>
            <string>Root CA for ios-use HTTPS proxy</string>
            <key>PayloadCertificateFileName</key>
            <string>ios-use-ca.cer</string>
            <key>PayloadContent</key>
            <data>${caDerBase64}</data>
        </dict>`);

  const proxyProfile = wrapProfile('ios-use Proxy Wi-Fi Profile', 'com.ios-use.proxy.wifi.profile', wifiPayload({
    ssid: opts.ssid,
    proxyType: 'Manual',
    proxyHost: opts.proxyHost,
    proxyPort: opts.proxyPort,
  }));
  const cleanupProfile = wrapProfile('ios-use Proxy Wi-Fi Cleanup', 'com.ios-use.proxy.wifi.profile', wifiPayload({
    ssid: opts.ssid,
    proxyType: 'None',
  }));

  return {
    caDerBase64,
    caProfileBase64: Buffer.from(caProfile, 'utf-8').toString('base64'),
    proxyProfileBase64: Buffer.from(proxyProfile, 'utf-8').toString('base64'),
    cleanupProfileBase64: Buffer.from(cleanupProfile, 'utf-8').toString('base64'),
  };
}

function wifiPayload(opts: {
  ssid: string;
  proxyType: 'Manual' | 'None';
  proxyHost?: string;
  proxyPort?: number;
}): string {
  const proxyFields = opts.proxyType === 'Manual'
    ? `
            <key>ProxyType</key>
            <string>Manual</string>
            <key>ProxyServer</key>
            <string>${escapeXml(opts.proxyHost ?? '')}</string>
            <key>ProxyServerPort</key>
            <integer>${opts.proxyPort ?? MITMDUMP_PORT}</integer>`
    : `
            <key>ProxyType</key>
            <string>None</string>`;

  return `
        <dict>
            <key>PayloadType</key>
            <string>com.apple.wifi.managed</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>com.ios-use.proxy.wifi</string>
            <key>PayloadUUID</key>
            <string>${uuid()}</string>
            <key>PayloadDisplayName</key>
            <string>ios-use Proxy Wi-Fi Profile</string>
            <key>SSID_STR</key>
            <string>${escapeXml(opts.ssid)}</string>
            <key>AutoJoin</key>
            <true/>${proxyFields}
        </dict>`;
}

function wrapProfile(displayName: string, identifier: string, payload: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
${payload}
    </array>
    <key>PayloadDisplayName</key>
    <string>${escapeXml(displayName)}</string>
    <key>PayloadIdentifier</key>
    <string>${escapeXml(identifier)}</string>
    <key>PayloadUUID</key>
    <string>${uuid()}</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>`;
}

function uuid(): string {
  const chars = '0123456789ABCDEF';
  let u = '';
  for (let i = 0; i < 36; i++) {
    if (i === 8 || i === 13 || i === 18 || i === 23) u += '-';
    else u += chars[Math.floor(Math.random() * 16)];
  }
  return u;
}

function escapeXml(input: string): string {
  return input
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}
