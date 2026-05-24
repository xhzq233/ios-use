#!/usr/bin/env node

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT = path.resolve(__dirname, '..');
process.chdir(ROOT);

const IOS_USE_HOME = path.resolve(process.env.IOS_USE_HOME || path.join(os.homedir(), '.ios-use'));
const BENCHMARK_DIR = path.join(IOS_USE_HOME, 'artifacts', 'benchmark');
const SCREENSHOT_DIR = path.join(BENCHMARK_DIR, 'screenshots');
const LOG_DIR = path.join(IOS_USE_HOME, 'logs');
const APPIUM_HOST = process.env.APPIUM_HOST || '127.0.0.1';
const APPIUM_PORT = Number(process.env.APPIUM_PORT || 4723);
const APPIUM_BASE_URL = `http://${APPIUM_HOST}:${APPIUM_PORT}`;

const WDA_DEVICE_UDID = process.env.WDA_INSTALLED_DEVICE || '';
const WDA_BUNDLE_ID = process.env.WDA_BUNDLE_ID || '';
const APPIUM_UPDATED_WDA_BUNDLE_ID = WDA_BUNDLE_ID.replace(/\.xctrunner$/, '');
const WDA_LOCAL_PORT = resolveWdaLocalPort();
const APPIUM_WDA_URL = process.env.APPIUM_WDA_URL || '';
const WDA_LAUNCH_TIMEOUT_MS = Number(process.env.WDA_LAUNCH_TIMEOUT_MS || '120000');
const APPIUM_SHOW_XCODE_LOG = process.env.APPIUM_SHOW_XCODE_LOG === '1';

const DEFAULT_APP_BUNDLE = 'com.apple.Preferences';
const DEFAULT_LABEL = '蓝牙';
const DEFAULT_ITERATIONS = 3;
const DEFAULT_TIMEOUT_MS = 60000;
const DEVICECTL_TIMEOUT_MS = Number(process.env.IOS_USE_BENCHMARK_DEVICECTL_TIMEOUT_MS || '30000');
const WDA_SCREENSHOT_QUALITY = 1;

let appiumProcess = null;
let appiumStartedByScript = false;
let iosUseExecutable = 'ios-use';

function appendAppiumHint(message, { udid } = {}) {
  const normalized = String(message || '');
  const lower = normalized.toLowerCase();
  const hints = [];

  if (lower.includes('tunnel registry port not found') || lower.includes('remote xpc tunnel')) {
    hints.push(`Run \`sudo appium driver run xcuitest tunnel-creation --udid ${udid || '<udid>'}\` first.`);
  }
  if (lower.includes('parse error: expected http/, rtsp/ or ice/')) {
    hints.push('Appium connected to a non-HTTP stream on the forwarded WDA port. This usually means WDA is not actually ready yet, or the iOS 18 tunnel prerequisite is missing.');
  }
  if (lower.includes('failed to start the preinstalled webdriveragent')) {
    hints.push(`Confirm \`${WDA_BUNDLE_ID}\` is installed and launchable on device.`);
  }
  if (lower.includes('provide a valid bundle identifier') || lower.includes('is not installed')) {
    hints.push(`Check that env \`WDA_BUNDLE_ID=${WDA_BUNDLE_ID}\` is the installed runner bundle id; Appium receives updatedWDABundleId=${APPIUM_UPDATED_WDA_BUNDLE_ID}.`);
  }

  if (hints.length === 0) {
    return normalized;
  }
  return `${normalized} | hint=${hints.join(' ')}`;
}

function resolveWdaLocalPort() {
  if (process.env.WDA_LOCAL_PORT) return String(process.env.WDA_LOCAL_PORT);
  for (let port = 8100; port <= 8109; port += 1) {
    if (!isTcpListenPortBusy(port)) return String(port);
  }
  throw new Error('No free WDA local port found in range 8100-8109. Set WDA_LOCAL_PORT to override.');
}

function isTcpListenPortBusy(port) {
  try {
    execFileSync('/bin/sh', ['-lc', `lsof -nP -iTCP:${port} -sTCP:LISTEN -t`], {
      stdio: 'ignore',
    });
    return true;
  } catch {
    return false;
  }
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function parseArgs(argv) {
  const args = {
    iterations: DEFAULT_ITERATIONS,
    output: '',
    bundleId: DEFAULT_APP_BUNDLE,
    label: DEFAULT_LABEL,
    customUdid: '',
    cases: '',
    customOnly: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case '--iterations':
        args.iterations = Number(argv[++i] || DEFAULT_ITERATIONS);
        break;
      case '--output':
        args.output = argv[++i] || '';
        break;
      case '--bundle-id':
        args.bundleId = argv[++i] || DEFAULT_APP_BUNDLE;
        break;
      case '--label':
        args.label = argv[++i] || DEFAULT_LABEL;
        break;
      case '--custom-udid':
        args.customUdid = argv[++i] || '';
        break;
      case '--cases':
        args.cases = argv[++i] || '';
        break;
      case '--custom-only':
        args.customOnly = true;
        break;
      case '--help':
      case '-h':
        printHelp();
        process.exit(0);
      default:
        throw new Error(`Unknown arg: ${arg}`);
    }
  }

  if (!Number.isInteger(args.iterations) || args.iterations <= 0) {
    throw new Error('--iterations must be a positive integer');
  }

  return args;
}

function printHelp() {
  console.log(`
Usage:
  WDA_INSTALLED_DEVICE=<udid> WDA_BUNDLE_ID=<bundleId> node scripts/benchmark_wda.js [options]

Options:
  --iterations <n>    default: 3
  --output <path>     markdown output path
  --bundle-id <id>    app bundle to benchmark, default: ${DEFAULT_APP_BUNDLE}
  --label <text>      anchor label for find/waitFor, default: ${DEFAULT_LABEL}
  --custom-udid <id>  custom-driver device UDID, default: WDA_INSTALLED_DEVICE
  --cases <list>      comma-separated subset, e.g. auto_session_activate_app,dom_vs_source,find
  --custom-only       measure only ios-use custom driver; do not start Appium/WDA

Optional env:
  APPIUM_WDA_URL      existing WDA base URL for Appium attach mode
  WDA_LAUNCH_TIMEOUT_MS  default: 120000
  APPIUM_SHOW_XCODE_LOG  set 1 to let Appium print xcode log
  IOS_USE_BENCHMARK_BUILD_CLI_FROM_SOURCE  set 1 to install the local Swift CLI
  IOS_USE_BENCHMARK_IOS_USE_BIN  use an existing ios-use binary instead of running install.sh;
                                  if this points to repo ./ios-use, Release build runs first
  IOS_USE_BENCHMARK_SKIP_DRIVER_BUILD  set 1 to skip release driver build
  IOS_USE_BENCHMARK_SKIP_DRIVER_CONFIG set 1 to skip reinstalling custom driver
  IOS_USE_BENCHMARK_DEVICECTL_TIMEOUT_MS default: 30000
`.trim());
}

function ensureEnv() {
  if (!WDA_DEVICE_UDID) throw new Error('Missing env WDA_INSTALLED_DEVICE');
  if (!WDA_BUNDLE_ID) throw new Error('Missing env WDA_BUNDLE_ID');
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function nowNs() {
  return process.hrtime.bigint();
}

function nsToMs(ns) {
  return Number(ns) / 1_000_000;
}

function fmtMs(ms) {
  return Number.isFinite(ms) ? ms.toFixed(1) : 'NA';
}

function avg(values) {
  if (values.length === 0) return NaN;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function median(values) {
  if (values.length === 0) return NaN;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid];
}

function speedup(appiumMs, customMs) {
  if (!Number.isFinite(appiumMs) || !Number.isFinite(customMs) || customMs <= 0) return 'NA';
  return `${(appiumMs / customMs).toFixed(2)}x`;
}

function runSync(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: ROOT,
    env: { ...process.env, ...(options.env || {}) },
    stdio: options.capture === false ? 'inherit' : ['ignore', 'pipe', 'pipe'],
    encoding: 'utf8',
    timeout: options.timeoutMs,
  });
  const stdout = typeof result.stdout === 'string' ? result.stdout : '';
  const stderr = typeof result.stderr === 'string' ? result.stderr : '';
  const exitCode = result.status ?? 1;
  if (exitCode !== 0 && !options.allowFailure) {
    throw new Error(`${command} ${args.join(' ')} failed (${exitCode})\n${stderr || stdout}`.trim());
  }
  return { stdout, stderr, exitCode };
}

function gitOutput(args) {
  try {
    return execFileSync('git', args, {
      cwd: ROOT,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    return '';
  }
}

function gitBenchmarkMetadata() {
  const commit = gitOutput(['rev-parse', '--short=12', 'HEAD']) || 'unknown';
  const branch = gitOutput(['branch', '--show-current']) || 'unknown';
  const status = gitOutput(['status', '--short']);
  return {
    commit,
    branch,
    status: status ? 'dirty' : 'clean',
  };
}

const driverSideCommands = new Set([
  'activateApp',
  'dismissAlert',
  'dom',
  'find',
  'home',
  'input',
  'longpress',
  'screenshot',
  'swipe',
  'tap',
  'terminateApp',
  'waitFor',
]);

function stripDriverUdidArgs(args) {
  if (!driverSideCommands.has(args[0])) return args;
  const stripped = [];
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === '--udid') {
      i += 1;
      continue;
    }
    if (args[i].startsWith('--udid=')) {
      continue;
    }
    stripped.push(args[i]);
  }
  return stripped;
}

function cli(args, options = {}) {
  return runSync(iosUseExecutable, stripDriverUdidArgs(args), options);
}

function readDriverLock() {
  try {
    const raw = fs.readFileSync(path.join(IOS_USE_HOME, 'state', 'driver.lock'), 'utf8');
    const parsed = JSON.parse(raw);
    return typeof parsed?.udid === 'string' ? parsed : null;
  } catch {
    return null;
  }
}

function customEnsureDriverStarted(customUdid) {
  const lock = readDriverLock();
  if (lock?.udid === customUdid) return;
  if (lock) cli(['stop'], { allowFailure: true });
  cli(['start', customUdid], { capture: false });
}

function buildReleaseDriverArtifacts() {
  if (process.env.IOS_USE_BENCHMARK_SKIP_DRIVER_BUILD === '1') {
    return 'skipped';
  }
  runSync('bash', ['scripts/build_driver.sh'], { capture: false });
  return 'Release';
}

function repoIosUsePath() {
  return path.join(ROOT, 'ios-use');
}

function isRepoIosUseBinary(bin) {
  return path.resolve(bin) === repoIosUsePath();
}

function buildReleaseCliExecutable() {
  runSync('bash', ['scripts/build_swift_cli.sh'], { capture: false });
  const bin = repoIosUsePath();
  if (!fs.existsSync(bin)) {
    throw new Error(`Release CLI build did not produce ${bin}`);
  }
  return bin;
}

function installIosUseExecutable() {
  if (process.env.IOS_USE_BENCHMARK_IOS_USE_BIN) {
    const bin = path.resolve(process.env.IOS_USE_BENCHMARK_IOS_USE_BIN);
    if (isRepoIosUseBinary(bin)) {
      iosUseExecutable = buildReleaseCliExecutable();
      return iosUseExecutable;
    }
    if (!fs.existsSync(bin)) {
      throw new Error(`IOS_USE_BENCHMARK_IOS_USE_BIN does not exist: ${bin}`);
    }
    iosUseExecutable = bin;
    return bin;
  }
  if (shouldBuildCliFromSource()) {
    iosUseExecutable = buildReleaseCliExecutable();
    return iosUseExecutable;
  }
  const installArgs = ['scripts/install.sh'];
  installArgs.push('--print-path');
  const { stdout } = runSync('bash', installArgs, { capture: true });
  const installedPath = stdout
    .split('\n')
    .map(line => line.trim())
    .filter(Boolean)
    .at(-1);
  if (!installedPath) {
    throw new Error('install.sh did not return ios-use path');
  }
  iosUseExecutable = installedPath;
  return installedPath;
}

function shouldBuildCliFromSource() {
  return process.env.IOS_USE_BENCHMARK_BUILD_CLI_FROM_SOURCE === '1';
}

function iosUseInstallMode() {
  if (process.env.IOS_USE_BENCHMARK_IOS_USE_BIN) {
    if (isRepoIosUseBinary(process.env.IOS_USE_BENCHMARK_IOS_USE_BIN)) {
      return 'repo-release-build';
    }
    return 'provided-binary';
  }
  return shouldBuildCliFromSource() ? 'repo-release-build' : 'release-download';
}

function configureCustomDriver(customUdid) {
  if (process.env.IOS_USE_BENCHMARK_SKIP_DRIVER_CONFIG === '1') {
    return 'skipped';
  }
  cli(['config', '--udid', customUdid], { capture: false });
  return 'installed';
}

function listDeviceProcesses(udid) {
  const { stdout } = runSync('xcrun', [
    'devicectl', 'device', 'info', 'processes',
    '--device', udid,
    '--quiet',
    '--json-output', '-',
  ], { timeoutMs: DEVICECTL_TIMEOUT_MS });
  const parsed = JSON.parse(stdout);
  const processes = parsed?.result?.runningProcesses ?? parsed?.result?.processTokens ?? [];
  return Array.isArray(processes) ? processes : [];
}

function terminateProcessByPid(udid, pid) {
  runSync('xcrun', [
    'devicectl', 'device', 'process', 'terminate',
    '--device', udid,
    '--pid', String(pid),
    '--kill',
  ], { allowFailure: true, timeoutMs: DEVICECTL_TIMEOUT_MS });
}

function terminateProcessesByExecutableName(udid, executableNames) {
  const targets = new Set(executableNames.filter(Boolean));
  if (targets.size === 0) return;
  const processes = listDeviceProcesses(udid);
  for (const processInfo of processes) {
    const executable = String(processInfo?.executable || '');
    const basename = executable.split('/').pop() || '';
    if (targets.has(basename)) {
      terminateProcessByPid(udid, processInfo.processIdentifier);
    }
  }
}

function terminateCustomDriverProcesses(udid) {
  terminateProcessesByExecutableName(udid, ['IOSUseDriver-Runner', 'IOSUseDriverXCTest-Runner']);
}

async function waitForProcessesGone(udid, executableNames, timeoutMs = 8000) {
  const targets = new Set(executableNames.filter(Boolean));
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    const processes = listDeviceProcesses(udid);
    const stillRunning = processes.some((processInfo) => {
      const executable = String(processInfo?.executable || '');
      const basename = executable.split('/').pop() || '';
      return targets.has(basename);
    });
    if (!stillRunning) return;
    await sleep(500);
  }
}


async function appiumRequest(method, endpoint, body, timeoutMs = DEFAULT_TIMEOUT_MS) {
  const response = await fetch(`${APPIUM_BASE_URL}${endpoint}`, {
    method,
    headers: body ? { 'content-type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await response.text();
  let payload = null;
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = text;
    }
  }
  if (!response.ok) {
    throw new Error(appendAppiumHint(`Appium ${method} ${endpoint} failed (${response.status})\n${typeof payload === 'string' ? payload : JSON.stringify(payload)}`, {
      udid: WDA_DEVICE_UDID,
    }));
  }
  if (payload && typeof payload === 'object' && payload.value && payload.value.error) {
    throw new Error(appendAppiumHint(`Appium ${method} ${endpoint} error=${payload.value.error} message=${payload.value.message || JSON.stringify(payload.value)}`, {
      udid: WDA_DEVICE_UDID,
    }));
  }
  return payload;
}

async function isAppiumHealthy() {
  try {
    const payload = await appiumRequest('GET', '/status', undefined, 3000);
    return payload?.value?.ready === true || payload?.value?.build;
  } catch {
    return false;
  }
}

async function startAppiumServer() {
  if (await isAppiumHealthy()) return false;

  ensureDir(LOG_DIR);
  const logFile = path.join(LOG_DIR, 'appium-benchmark.log');
  const outFd = fs.openSync(logFile, 'a');
  try {
    appiumProcess = spawn('appium', ['server', '--address', APPIUM_HOST, '--port', String(APPIUM_PORT)], {
      cwd: ROOT,
      stdio: ['ignore', outFd, outFd],
      detached: true,
      env: {
        ...process.env,
        APPIUM_XCUITEST_PREFER_DEVICECTL: process.env.APPIUM_XCUITEST_PREFER_DEVICECTL || '1',
      },
    });
  } finally {
    try { fs.closeSync(outFd); } catch {}
  }
  appiumProcess.unref();
  appiumStartedByScript = true;

  for (let i = 0; i < 30; i += 1) {
    await sleep(1000);
    if (await isAppiumHealthy()) return true;
  }
  throw new Error('Appium server failed to start within 30s');
}

function stopAppiumServer() {
  if (!appiumStartedByScript) return;
  try {
    execFileSync('/bin/sh', ['-lc', `lsof -ti :${APPIUM_PORT} -sTCP:LISTEN | xargs kill -9 2>/dev/null || true`], {
      stdio: 'ignore',
    });
  } catch {
    // ignore
  }
}

function extractSessionId(payload) {
  return payload?.sessionId || payload?.value?.sessionId || null;
}

function extractElementId(value) {
  const source = value?.value ?? value;
  if (!source || typeof source !== 'object') return null;
  return source['element-6066-11e4-a52e-4f735466cecf'] || source.ELEMENT || null;
}

function buildCapabilities({ udid, bundleId, webDriverAgentUrl }) {
  const capabilities = {
    platformName: 'iOS',
    'appium:automationName': 'XCUITest',
    'appium:udid': udid,
    'appium:bundleId': bundleId,
    'appium:noReset': true,
    'appium:newCommandTimeout': 0,
    'appium:wdaLaunchTimeout': WDA_LAUNCH_TIMEOUT_MS,
  };

  if (APPIUM_SHOW_XCODE_LOG) {
    capabilities['appium:showXcodeLog'] = true;
  }

  if (webDriverAgentUrl) {
    capabilities['appium:webDriverAgentUrl'] = webDriverAgentUrl;
  } else {
    capabilities['appium:usePreinstalledWDA'] = true;
    capabilities['appium:updatedWDABundleId'] = APPIUM_UPDATED_WDA_BUNDLE_ID;
    capabilities['appium:wdaLocalPort'] = WDA_LOCAL_PORT;
  }

  return capabilities;
}

class AppiumDriver {
  constructor({ udid, appBundle }) {
    this.udid = udid;
    this.appBundle = appBundle;
    this.sessionId = null;
  }

  async request(method, endpoint, body, timeoutMs = DEFAULT_TIMEOUT_MS) {
    if (!this.sessionId) {
      throw new Error('Appium session is not ready');
    }
    const payload = await appiumRequest(method, `/session/${this.sessionId}${endpoint}`, body, timeoutMs);
    return payload?.value;
  }

  async execute(script, args = [], timeoutMs = DEFAULT_TIMEOUT_MS) {
    await this.ensureSession();
    return await this.request('POST', '/execute/sync', { script, args }, timeoutMs);
  }

  async createSession() {
    await startAppiumServer();
    const capabilities = buildCapabilities({
      udid: this.udid,
      bundleId: this.appBundle,
      webDriverAgentUrl: APPIUM_WDA_URL || undefined,
    });
    const body = {
      capabilities: {
        alwaysMatch: capabilities,
        firstMatch: [{}],
      },
      desiredCapabilities: capabilities,
    };
    const payload = await appiumRequest('POST', '/session', body, 120000);

    const sessionId = extractSessionId(payload);
    if (!sessionId) {
      throw new Error(`Appium createSession returned no sessionId: ${JSON.stringify(payload)}`);
    }
    this.sessionId = sessionId;
    return payload;
  }

  async ensureSession() {
    if (!this.sessionId) {
      await this.createSession();
    }
  }

  async deleteSession() {
    if (!this.sessionId) return;
    try {
      await appiumRequest('DELETE', `/session/${this.sessionId}`, undefined, 30000);
    } catch {
      // ignore
    } finally {
      this.sessionId = null;
    }
  }

  async source() {
    await this.ensureSession();
    return await this.request('GET', '/source', undefined, 60000);
  }

  async screenshot() {
    await this.ensureSession();
    return await this.request('GET', '/screenshot');
  }

  async screenshotToFile(name = 'benchmark-wda-appium') {
    const base64 = await this.screenshot();
    if (typeof base64 !== 'string' || base64.length === 0) {
      throw new Error(`Appium /screenshot returned invalid payload: ${JSON.stringify(base64)}`);
    }
    ensureDir(SCREENSHOT_DIR);
    const filePath = path.join(SCREENSHOT_DIR, `${name}.jpg`);
    fs.writeFileSync(filePath, Buffer.from(base64, 'base64'));
    return filePath;
  }

  async findElementUsing(using, value) {
    await this.ensureSession();
    const payload = await this.request('POST', '/element', {
      using,
      value,
    });
    const elementId = extractElementId(payload);
    if (!elementId) {
      throw new Error(`Appium /element returned no element id: ${JSON.stringify(payload)}`);
    }
    return elementId;
  }

  async findElement(label) {
    return await this.findElementUsing('accessibility id', label);
  }

  async findElementByPredicate(predicate) {
    return await this.findElementUsing('-ios predicate string', predicate);
  }

  async updateSettings(settings) {
    await this.ensureSession();
    return await this.request('POST', '/appium/settings', { settings });
  }

  async waitForElement(label, timeoutMs = 8000, intervalMs = 500) {
    const startedAt = Date.now();
    while (Date.now() - startedAt < timeoutMs) {
      try {
        return await this.findElement(label);
      } catch {
        await sleep(intervalMs);
      }
    }
    throw new Error(`Appium waitForElement timed out: ${label}`);
  }

  async performActions(actions) {
    await this.ensureSession();
    return await this.request('POST', '/actions', { actions });
  }

  async tap(x, y) {
    return await this.performActions([{
      type: 'pointer',
      id: 'finger1',
      parameters: { pointerType: 'touch' },
      actions: [
        { type: 'pointerMove', duration: 0, x, y },
        { type: 'pointerDown', button: 0 },
        { type: 'pause', duration: 80 },
        { type: 'pointerUp', button: 0 },
      ],
    }]);
  }

  async longPress(x, y, durationMs = 500) {
    return await this.performActions([{
      type: 'pointer',
      id: 'finger1',
      parameters: { pointerType: 'touch' },
      actions: [
        { type: 'pointerMove', duration: 0, x, y },
        { type: 'pointerDown', button: 0 },
        { type: 'pause', duration: durationMs },
        { type: 'pointerUp', button: 0 },
      ],
    }]);
  }

  async drag(fromX, fromY, toX, toY, durationMs = 250) {
    return await this.performActions([{
      type: 'pointer',
      id: 'finger1',
      parameters: { pointerType: 'touch' },
      actions: [
        { type: 'pointerMove', duration: 0, x: Math.round(fromX), y: Math.round(fromY) },
        { type: 'pointerDown', button: 0 },
        { type: 'pause', duration: 80 },
        { type: 'pointerMove', duration: durationMs, x: Math.round(toX), y: Math.round(toY) },
        { type: 'pointerUp', button: 0 },
      ],
    }]);
  }

  async mobileScroll(params) {
    return await this.execute('mobile: scroll', [params], 60000);
  }

  async clickElement(elementId) {
    await this.ensureSession();
    return await this.request('POST', `/element/${elementId}/click`, { id: elementId });
  }

  async keys(text) {
    await this.ensureSession();
    return await this.request('POST', '/keys', { value: text.split('') });
  }

  async getWindowRect() {
    await this.ensureSession();
    return await this.request('GET', '/window/rect');
  }

  async activateApp(bundleId = this.appBundle) {
    await this.ensureSession();
    return await this.request('POST', '/appium/device/activate_app', { bundleId });
  }

  async terminateApp(bundleId = this.appBundle) {
    await this.ensureSession();
    return await this.request('POST', '/appium/device/terminate_app', { bundleId });
  }

  async close() {
    await this.deleteSession();
  }

  async resetState() {
    await this.deleteSession();
  }
}

function customStopSessionQuiet() {
  try {
    cli(['stop'], { allowFailure: true });
  } catch {
    // ignore
  }
}

async function customPrepareNoSession(customUdid = WDA_DEVICE_UDID, appBundle = DEFAULT_APP_BUNDLE) {
  customEnsureDriverStarted(customUdid);
  cli(['terminateApp', appBundle, '--udid', customUdid], { allowFailure: true });
}

async function customPrepareAppSession(customUdid, appBundle, label) {
  customEnsureDriverStarted(customUdid);
  cli(['terminateApp', appBundle, '--udid', customUdid], { allowFailure: true });
  cli(['activateApp', appBundle, '--udid', customUdid]);
  cli(['waitFor', '--label', label, '--timeout', '8', '--udid', customUdid]);
}

async function appiumPrepareNoSession(driver) {
  customStopSessionQuiet();
  terminateCustomDriverProcesses(driver.udid);
  await driver.resetState();
  await waitForProcessesGone(driver.udid, ['IOSUseDriver-Runner', 'IOSUseDriverXCTest-Runner']);
  await sleep(2000);
}

async function appiumPrepareSettingsHome(driver, label) {
  customStopSessionQuiet();
  terminateCustomDriverProcesses(driver.udid);
  await driver.resetState();
  await waitForProcessesGone(driver.udid, ['IOSUseDriver-Runner', 'IOSUseDriverXCTest-Runner']);
  await sleep(1000);
  await driver.createSession();
  await driver.updateSettings({ screenshotQuality: WDA_SCREENSHOT_QUALITY });
  try {
    await driver.terminateApp(driver.appBundle);
  } catch {
    // ignore; Settings may not be running yet
  }
  await driver.activateApp(driver.appBundle);
  await driver.waitForElement(label, 8000, 500);
}

async function measureSide(sideName, runs, prepareFn, runFn) {
  const samples = [];
  const errors = [];
  let fails = 0;

  console.error(`[bench:${sideName}] x${runs}`);
  for (let i = 0; i < runs; i += 1) {
    try {
      await prepareFn();
    } catch (error) {
      fails += 1;
      errors.push(`prepare: ${error.message}`);
      console.error(`[bench:${sideName}] prepare fail: ${error.message}`);
      continue;
    }
    const startedAt = nowNs();
    try {
      await runFn();
      samples.push(nsToMs(nowNs() - startedAt));
    } catch (error) {
      fails += 1;
      errors.push(error.message);
      console.error(`[bench:${sideName}] fail: ${error.message}`);
    }
  }

  return {
    samples,
    errors,
    fails,
    avg: samples.length ? avg(samples) : NaN,
    min: samples.length ? Math.min(...samples) : NaN,
    max: samples.length ? Math.max(...samples) : NaN,
    median: samples.length ? median(samples) : NaN,
  };
}

function emptyMeasureResult() {
  return {
    samples: [],
    errors: [],
    fails: 0,
    avg: NaN,
    min: NaN,
    max: NaN,
    median: NaN,
  };
}

function buildCases(ctx) {
  const centerX = 187;
  const topTapY = 80;
  const swipeDistance = 200;
  const scrollToLabel = '开发者';

  return [
    {
      name: 'auto_session_activate_app',
      kind: 'lifecycle',
      runs: 1,
      mapping: '`start <udid>` prepared lock + `activateApp` ↔ `POST /session` + activate app',
      customPrepare: async () => { await customPrepareNoSession(ctx.customUdid, ctx.appBundle); },
      customRun: async () => {
        cli(['activateApp', ctx.appBundle, '--udid', ctx.customUdid]);
      },
      appiumPrepare: async () => { await appiumPrepareNoSession(ctx.appium); },
      appiumRun: async () => {
        await ctx.appium.createSession();
        await ctx.appium.activateApp(ctx.appBundle);
      },
    },
    {
      name: 'dom_vs_source',
      kind: 'read',
      runs: ctx.iterations,
      mapping: '`dom` ↔ `GET /source`',
      customPrepare: async () => {
        await customPrepareAppSession(ctx.customUdid, ctx.appBundle, ctx.label);
      },
      customRun: async () => { cli(['dom', '--udid', ctx.customUdid]); },
      appiumPrepare: async () => { await appiumPrepareSettingsHome(ctx.appium, ctx.label); },
      appiumRun: async () => { await ctx.appium.source(); },
    },
    {
      name: 'find',
      kind: 'read',
      runs: ctx.iterations,
      mapping: '`find <label>` ↔ `POST /element` (`accessibility id`)',
      customPrepare: async () => {
        await customPrepareAppSession(ctx.customUdid, ctx.appBundle, ctx.label);
      },
      customRun: async () => { cli(['find', ctx.label, '--udid', ctx.customUdid]); },
      appiumPrepare: async () => { await appiumPrepareSettingsHome(ctx.appium, ctx.label); },
      appiumRun: async () => { await ctx.appium.findElement(ctx.label); },
    },
    {
      name: 'wait_for',
      kind: 'read',
      runs: ctx.iterations,
      mapping: '`waitFor` ↔ repeated `POST /element` polling',
      customPrepare: async () => {
        await customPrepareAppSession(ctx.customUdid, ctx.appBundle, ctx.label);
      },
      customRun: async () => { cli(['waitFor', '--label', ctx.label, '--timeout', '8', '--udid', ctx.customUdid]); },
      appiumPrepare: async () => { await appiumPrepareSettingsHome(ctx.appium, ctx.label); },
      appiumRun: async () => { await ctx.appium.waitForElement(ctx.label, 8000, 500); },
    },
    {
      name: 'screenshot',
      kind: 'read',
      runs: ctx.iterations,
      mapping: '`screenshot` ↔ `GET /screenshot`',
      customPrepare: async () => {
        await customPrepareAppSession(ctx.customUdid, ctx.appBundle, ctx.label);
      },
      customRun: async () => { cli(['screenshot', '--name', 'benchmark-wda-custom', '--udid', ctx.customUdid]); },
      appiumPrepare: async () => { await appiumPrepareSettingsHome(ctx.appium, ctx.label); },
      appiumRun: async () => { await ctx.appium.screenshotToFile('benchmark-wda-appium'); },
    },
    {
      name: 'tap_coord',
      kind: 'mutate',
      runs: ctx.iterations,
      mapping: '`tap x,y` ↔ `POST /actions`',
      customPrepare: async () => {
        await customPrepareAppSession(ctx.customUdid, ctx.appBundle, ctx.label);
      },
      customRun: async () => { cli(['tap', `${centerX},${topTapY}`, '--udid', ctx.customUdid]); },
      appiumPrepare: async () => { await appiumPrepareSettingsHome(ctx.appium, ctx.label); },
      appiumRun: async () => { await ctx.appium.tap(centerX, topTapY); },
    },
    {
      name: 'tap_label',
      kind: 'mutate',
      runs: ctx.iterations,
      mapping: '`tap 蓝牙` ↔ `POST /element` + `POST /element/:id/click`',
      customPrepare: async () => {
        await customPrepareAppSession(ctx.customUdid, ctx.appBundle, ctx.label);
      },
      customRun: async () => { cli(['tap', ctx.label, '--udid', ctx.customUdid]); },
      appiumPrepare: async () => { await appiumPrepareSettingsHome(ctx.appium, ctx.label); },
      appiumRun: async () => {
        const elementId = await ctx.appium.findElement(ctx.label);
        await ctx.appium.clickElement(elementId);
      },
    },
    {
      name: 'longpress_coord',
      kind: 'mutate',
      runs: ctx.iterations,
      mapping: '`longpress x,y` ↔ `POST /actions`',
      customPrepare: async () => {
        await customPrepareAppSession(ctx.customUdid, ctx.appBundle, ctx.label);
      },
      customRun: async () => { cli(['longpress', `${centerX},${topTapY}`, '--duration', '500', '--udid', ctx.customUdid]); },
      appiumPrepare: async () => { await appiumPrepareSettingsHome(ctx.appium, ctx.label); },
      appiumRun: async () => { await ctx.appium.longPress(centerX, topTapY, 500); },
    },
    {
      name: 'input',
      kind: 'mutate',
      runs: ctx.iterations,
      mapping: '`input` ↔ `POST /element` + `POST /element/:id/click` + `POST /keys`',
      customPrepare: async () => {
        await customPrepareAppSession(ctx.customUdid, ctx.appBundle, ctx.label);
      },
      customRun: async () => { cli(['input', '--label', '搜索', '--content', '蓝牙', '--traits', 'SearchField', '--udid', ctx.customUdid]); },
      appiumPrepare: async () => { await appiumPrepareSettingsHome(ctx.appium, ctx.label); },
      appiumRun: async () => {
        const elementId = await ctx.appium.findElement('搜索');
        await ctx.appium.clickElement(elementId);
        await ctx.appium.keys('蓝牙');
      },
    },
    {
      name: 'swipe_distance',
      kind: 'mutate',
      runs: ctx.iterations,
      mapping: '`swipe --distance 200 --dir forth` ↔ `POST /actions` drag gesture',
      customPrepare: async () => {
        await customPrepareAppSession(ctx.customUdid, ctx.appBundle, ctx.label);
      },
      customRun: async () => { cli(['swipe', '--distance', String(swipeDistance), '--dir', 'forth', '--udid', ctx.customUdid]); },
      appiumPrepare: async () => { await appiumPrepareSettingsHome(ctx.appium, ctx.label); },
      appiumRun: async () => {
        const rect = await ctx.appium.getWindowRect();
        const x = Math.round((rect.width || rect.value?.width) / 2);
        const height = rect.height || rect.value?.height;
        const startY = Math.round(height * 0.72);
        const endY = startY - swipeDistance;
        await ctx.appium.drag(x, startY, x, endY, 250);
      },
    },
    {
      name: 'scroll_to_visible',
      kind: 'mutate',
      runs: ctx.iterations,
      mapping: '`swipe --to 开发者 --from 蓝牙` ↔ loop `mobile: scroll(direction=down)` + visible check (`label == "开发者" AND visible == 1`)',
      customPrepare: async () => {
        await customPrepareAppSession(ctx.customUdid, ctx.appBundle, ctx.label);
      },
      customRun: async () => { 
        cli(['swipe', '--to', scrollToLabel, '--from', ctx.label, '--udid', ctx.customUdid]);
      },
      appiumPrepare: async () => { await appiumPrepareSettingsHome(ctx.appium, ctx.label); },
      appiumRun: async () => {
        const maxScrolls = 10;
        const collectionViewId = await ctx.appium.findElementByPredicate(`type == 'XCUIElementTypeCollectionView'`);
        const targetPredicate = `label == "${scrollToLabel}" AND visible == 1`;
        for (let scrollCount = 0; scrollCount <= maxScrolls; scrollCount += 1) {
          try {
            await ctx.appium.findElementByPredicate(targetPredicate);
            return;
          } catch {
            if (scrollCount === maxScrolls) break;
          }
          await ctx.appium.mobileScroll({
            elementId: collectionViewId,
            direction: 'down',
          });
        }
        throw new Error(`Appium scroll_to_visible timed out after ${maxScrolls} scrolls: ${scrollToLabel}`);
      },
    },
    {
      name: 'activate_app',
      kind: 'app',
      runs: ctx.iterations,
      mapping: '`activateApp` ↔ `POST /appium/device/activate_app`',
      customPrepare: async () => {
        await customPrepareAppSession(ctx.customUdid, ctx.appBundle, ctx.label);
      },
      customRun: async () => {
        cli(['terminateApp', ctx.appBundle, '--udid', ctx.customUdid], { allowFailure: true });
        cli(['activateApp', ctx.appBundle, '--udid', ctx.customUdid]);
      },
      appiumPrepare: async () => { await appiumPrepareSettingsHome(ctx.appium, ctx.label); },
      appiumRun: async () => {
        try {
          await ctx.appium.terminateApp(ctx.appBundle);
        } catch {
          // ignore
        }
        await ctx.appium.activateApp(ctx.appBundle);
      },
    },
    {
      name: 'terminate_app',
      kind: 'app',
      runs: ctx.iterations,
      mapping: '`terminateApp` ↔ `POST /appium/device/terminate_app`',
      customPrepare: async () => {
        await customPrepareAppSession(ctx.customUdid, ctx.appBundle, ctx.label);
      },
      customRun: async () => { cli(['terminateApp', ctx.appBundle, '--udid', ctx.customUdid]); },
      appiumPrepare: async () => { await appiumPrepareSettingsHome(ctx.appium, ctx.label); },
      appiumRun: async () => { await ctx.appium.terminateApp(ctx.appBundle); },
    },
  ];
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  ensureEnv();
  const customUdid = args.customUdid || WDA_DEVICE_UDID;
  const driverBuild = buildReleaseDriverArtifacts();
  const installedCliPath = installIosUseExecutable();
  const customDriverInstall = configureCustomDriver(customUdid);

  ensureDir(BENCHMARK_DIR);
  const output = args.output || path.join(BENCHMARK_DIR, `benchmark-wda-${new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19)}.md`);
  const selectedCases = args.cases
    ? new Set(args.cases.split(',').map(item => item.trim()).filter(Boolean))
    : null;

  const ctx = {
    iterations: args.iterations,
    appBundle: args.bundleId,
    label: args.label,
    customUdid,
    appium: args.customOnly ? null : new AppiumDriver({ udid: WDA_DEVICE_UDID, appBundle: args.bundleId }),
  };

  const cases = buildCases(ctx).filter(item => !selectedCases || selectedCases.has(item.name));
  if (cases.length === 0) {
    throw new Error('No benchmark cases selected');
  }

  const suiteStartNs = nowNs();
  const rows = [];

  try {
    for (const testCase of cases) {
      console.error(`\n[case] ${testCase.name} :: ${testCase.mapping}`);
      const customResult = await measureSide('custom', testCase.runs, testCase.customPrepare, testCase.customRun);
      const appiumResult = args.customOnly
        ? emptyMeasureResult()
        : await measureSide('appium', testCase.runs, testCase.appiumPrepare, testCase.appiumRun);
      rows.push({ ...testCase, customResult, appiumResult });
    }
  } finally {
    customStopSessionQuiet();
    if (ctx.appium) {
      await ctx.appium.close();
    }
    stopAppiumServer();
  }

  const suiteElapsedMs = nsToMs(nowNs() - suiteStartNs);
  const generatedAt = new Date().toISOString();
  const gitMeta = gitBenchmarkMetadata();

  const lines = [];
  lines.push(args.customOnly ? '# ios-use Custom Driver Benchmark' : '# ios-use vs Appium+WDA Benchmark');
  lines.push('');
  lines.push('## 测试环境');
  lines.push('');
  lines.push('| 项目 | 值 |');
  lines.push('|------|-----|');
  lines.push(`| 时间 | \`${generatedAt}\` |`);
  lines.push(`| git commit | \`${gitMeta.commit}\` |`);
  lines.push(`| git branch | \`${gitMeta.branch}\` |`);
  lines.push(`| git status | \`${gitMeta.status}\` |`);
  lines.push('| 实验组 | `ios-use custom driver` |');
  lines.push(`| 对照组 | \`${args.customOnly ? 'skipped (--custom-only)' : 'Appium Server -> WDA'}\` |`);
  if (args.customOnly) {
    lines.push(`| 设备 | \`${customUdid}\` |`);
  } else {
    lines.push(`| WDA 设备 | \`${WDA_DEVICE_UDID}\` |`);
    lines.push(`| WDA bundleId | \`${WDA_BUNDLE_ID}\` |`);
    lines.push(`| Appium updatedWDABundleId | \`${APPIUM_UPDATED_WDA_BUNDLE_ID}\` |`);
    lines.push(`| WDA local port | \`${WDA_LOCAL_PORT}\` |`);
    lines.push(`| WDA launch timeout | \`${WDA_LAUNCH_TIMEOUT_MS} ms\` |`);
    lines.push(`| custom 设备 | \`${customUdid}\` |`);
  }
  lines.push(`| custom driver build | \`${driverBuild}\` |`);
  lines.push(`| custom driver install | \`${customDriverInstall}\` |`);
  lines.push(`| App | \`${args.bundleId}\` |`);
  lines.push(`| 锚点 label | \`${args.label}\` |`);
  if (!args.customOnly) {
    lines.push(`| Appium URL | \`${APPIUM_BASE_URL}\` |`);
    lines.push(`| WDA attach URL | \`${APPIUM_WDA_URL || 'auto(preinstalled WDA)'}\` |`);
  }
  lines.push(`| ios-use 可执行文件 | \`${installedCliPath}\` |`);
  lines.push(`| ios-use install mode | \`${iosUseInstallMode()}\` |`);
  lines.push(`| 迭代次数 | \`${args.iterations}\` |`);
  lines.push(`| 总耗时 | \`${fmtMs(suiteElapsedMs)} ms\` |`);
  lines.push('');
  lines.push(args.customOnly ? '## ios-use 命令' : '## 对照映射');
  lines.push('');
  lines.push(args.customOnly ? '| Case | 命令 |' : '| Case | 映射 |');
  lines.push('|------|------|');
  for (const row of rows) {
    const mapping = args.customOnly ? row.mapping.split('↔')[0].trim() : row.mapping;
    lines.push(`| ${row.name} | ${mapping} |`);
  }
  lines.push('');
  lines.push('## 结果');
  lines.push('');
  if (args.customOnly) {
    lines.push('| Case | 类型 | Custom Avg | Custom Median | Custom Min | Custom Max | Custom Fails |');
    lines.push('|------|------|-----------:|--------------:|-----------:|-----------:|-------------:|');
    for (const row of rows) {
      lines.push(`| ${row.name} | ${row.kind} | ${fmtMs(row.customResult.avg)} | ${fmtMs(row.customResult.median)} | ${fmtMs(row.customResult.min)} | ${fmtMs(row.customResult.max)} | ${row.customResult.fails} |`);
    }
  } else {
    lines.push('| Case | 类型 | Custom Avg | Appium+WDA Avg | Speedup | Custom Median | Appium Median | Custom Fails | Appium Fails |');
    lines.push('|------|------|-----------:|----------------:|--------:|--------------:|---------------:|-------------:|-------------:|');
    for (const row of rows) {
      lines.push(`| ${row.name} | ${row.kind} | ${fmtMs(row.customResult.avg)} | ${fmtMs(row.appiumResult.avg)} | ${speedup(row.appiumResult.avg, row.customResult.avg)} | ${fmtMs(row.customResult.median)} | ${fmtMs(row.appiumResult.median)} | ${row.customResult.fails} | ${row.appiumResult.fails} |`);
    }
  }
  lines.push('');
  if (!args.customOnly) {
    lines.push('## 明细');
    lines.push('');
    lines.push('| Case | Custom Min | Custom Max | Appium Min | Appium Max |');
    lines.push('|------|-----------:|-----------:|-----------:|-----------:|');
    for (const row of rows) {
      lines.push(`| ${row.name} | ${fmtMs(row.customResult.min)} | ${fmtMs(row.customResult.max)} | ${fmtMs(row.appiumResult.min)} | ${fmtMs(row.appiumResult.max)} |`);
    }
    lines.push('');
  }
  lines.push('## 失败原因');
  lines.push('');
  if (args.customOnly) {
    lines.push('| Case | Custom Error |');
    lines.push('|------|--------------|');
    for (const row of rows) {
      lines.push(`| ${row.name} | ${row.customResult.errors[0] || '-'} |`);
    }
  } else {
    lines.push('| Case | Custom Error | Appium Error |');
    lines.push('|------|--------------|--------------|');
    for (const row of rows) {
      lines.push(`| ${row.name} | ${row.customResult.errors[0] || '-'} | ${row.appiumResult.errors[0] || '-'} |`);
    }
  }
  lines.push('');
  lines.push('## 使用方式');
  lines.push('');
  lines.push('```bash');
  if (process.env.IOS_USE_BENCHMARK_IOS_USE_BIN) {
    lines.push(`IOS_USE_BENCHMARK_IOS_USE_BIN=${installedCliPath} \\\n  WDA_INSTALLED_DEVICE=${WDA_DEVICE_UDID} WDA_BUNDLE_ID=${WDA_BUNDLE_ID} \\\n  node scripts/benchmark_wda.js --iterations 3${args.customOnly ? ' --custom-only' : ''}`);
  } else {
    lines.push(`WDA_INSTALLED_DEVICE=${WDA_DEVICE_UDID} WDA_BUNDLE_ID=${WDA_BUNDLE_ID} \\\n  node scripts/benchmark_wda.js --iterations 3${args.customOnly ? ' --custom-only' : ''}`);
  }
  lines.push('```');
  lines.push('');
  if (process.env.IOS_USE_BENCHMARK_IOS_USE_BIN) {
    lines.push('说明：本次通过 `IOS_USE_BENCHMARK_IOS_USE_BIN` 使用已有 `ios-use` 可执行文件，不执行 `scripts/install.sh`。');
  } else {
    lines.push('说明：脚本开始前会先执行 Release driver build、`scripts/install.sh` 和 `ios-use config --udid <customUdid>`，并使用安装后的 `ios-use` 可执行文件进行 custom 侧 benchmark。');
  }
  if (args.customOnly) {
    lines.push('说明：本次只测 ios-use custom driver，不启动 Appium/WDA 对照组。');
  } else {
    lines.push('说明：本脚本对照组默认走完整 `Appium Server -> preinstalled WDA` 链路，不是直打 WDA。');
    lines.push('说明：如果真机是 iOS 18+ 且 Appium 报 `Tunnel registry port not found`，需先手动执行 `sudo appium driver run xcuitest tunnel-creation --udid <udid>`。');
  }

  fs.writeFileSync(output, `${lines.join('\n')}\n`);
  console.log(`Benchmark written to ${output}`);
}

await main();
