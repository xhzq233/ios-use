#!/usr/bin/env node

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT = path.resolve(__dirname, '..');
process.chdir(ROOT);

const IOS_USE_HOME = path.resolve(process.env.IOS_USE_HOME || path.join(os.homedir(), '.ios-use'));
const BENCHMARK_DIR = path.join(IOS_USE_HOME, 'artifacts', 'benchmark');
const SCREENSHOT_DIR = path.join(BENCHMARK_DIR, 'screenshots');
const LOG_DIR = path.join(IOS_USE_HOME, 'logs');

const DEFAULT_APP_BUNDLE = 'com.apple.Preferences';
const DEFAULT_LABEL = '蓝牙';
const DEFAULT_ITERATIONS = 3;
const DEFAULT_TIMEOUT_MS = 60000;
const DEVICECTL_TIMEOUT_MS = Number(process.env.IOS_USE_BENCHMARK_DEVICECTL_TIMEOUT_MS || '30000');
const WDA_SCREENSHOT_QUALITY = 1;

const BENCHES = new Set(['ios-use', 'wda']);
const PRESETS = {
  full: null,
  read: ['dom_vs_source', 'find', 'wait_for', 'screenshot'],
  lifecycle: ['start_session', 'start_and_activate_app'],
  mutate: ['tap_coord', 'tap_label', 'longpress_coord', 'input', 'swipe_distance', 'scroll_to_visible'],
  app: ['activate_app', 'terminate_app'],
  smoke: ['start_session', 'dom_vs_source', 'find', 'screenshot', 'tap_coord', 'activate_app'],
};

let iosUseExecutable = '';
let appiumProcess = null;
let appiumStartedByScript = false;

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function benchmarkStamp() {
  return new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);
}

function expandHome(filePath) {
  if (!filePath.startsWith('~/')) return filePath;
  return path.join(os.homedir(), filePath.slice(2));
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function runSync(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || ROOT,
    env: { ...process.env, ...(options.env || {}) },
    input: options.input,
    stdio: options.capture === false ? 'inherit' : ['pipe', 'pipe', 'pipe'],
    encoding: options.encoding || 'utf8',
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

function commandExists(command) {
  try {
    execFileSync('/bin/sh', ['-lc', `command -v ${shellQuote(command)} >/dev/null 2>&1`], {
      stdio: 'ignore',
    });
    return true;
  } catch {
    return false;
  }
}

function resolveIosUseBin(value) {
  const explicit = value || process.env.IOS_USE_BENCHMARK_IOS_USE_BIN || '';
  if (!explicit) {
    const repoBin = path.join(ROOT, 'ios-use');
    if (fs.existsSync(repoBin)) return repoBin;
    if (commandExists('ios-use')) return 'ios-use';
    throw new Error('ios-use binary not found. Build or install it outside benchmark, then pass --ios-use-bin <path>.');
  }
  const candidate = explicit;
  if (candidate.includes('/')) {
    const resolved = path.resolve(candidate);
    if (!fs.existsSync(resolved)) {
      throw new Error(`ios-use binary not found: ${resolved}. Build it outside benchmark, e.g. bash scripts/build_swift_cli.sh --debug or bash scripts/build_swift_cli.sh.`);
    }
    return resolved;
  }
  if (!commandExists(candidate)) {
    throw new Error(`ios-use binary not found in PATH: ${candidate}. Pass --ios-use-bin <path>.`);
  }
  return candidate;
}

function parseArgs(argv) {
  const args = {
    bench: 'ios-use',
    udid: process.env.WDA_INSTALLED_DEVICE || '',
    iosUseBin: '',
    driverIpa: '',
    output: '',
    baseline: '',
    iterations: DEFAULT_ITERATIONS,
    preset: 'full',
    cases: '',
    listCases: false,
    bundleId: DEFAULT_APP_BUNDLE,
    label: DEFAULT_LABEL,
    searchLabel: '搜索',
    scrollToLabel: '开发者',
    inputBundleId: '',
    inputLabel: '',
    inputTraits: 'SearchField',
    inputContent: '蓝牙',
    inputPrepareLabel: '',
    inputOpenUrl: '',
    wdaBundleId: process.env.WDA_BUNDLE_ID || '',
    appiumHost: process.env.APPIUM_HOST || '127.0.0.1',
    appiumPort: Number(process.env.APPIUM_PORT || 4723),
    appiumWdaUrl: process.env.APPIUM_WDA_URL || '',
    wdaLocalPort: process.env.WDA_LOCAL_PORT || '',
    wdaLaunchTimeoutMs: Number(process.env.WDA_LAUNCH_TIMEOUT_MS || '120000'),
    appiumShowXcodeLog: process.env.APPIUM_SHOW_XCODE_LOG === '1',
    skipDriverVersionCheck: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case '--bench':
        args.bench = argv[++i] || '';
        break;
      case '--udid':
        args.udid = argv[++i] || '';
        break;
      case '--ios-use-bin':
        args.iosUseBin = argv[++i] || '';
        break;
      case '--driver-ipa':
        args.driverIpa = argv[++i] || '';
        break;
      case '--output':
        args.output = argv[++i] || '';
        break;
      case '--baseline':
        args.baseline = argv[++i] || '';
        break;
      case '--iterations':
        args.iterations = Number(argv[++i] || DEFAULT_ITERATIONS);
        break;
      case '--preset':
        args.preset = argv[++i] || 'full';
        break;
      case '--cases':
        args.cases = argv[++i] || '';
        break;
      case '--list-cases':
        args.listCases = true;
        break;
      case '--bundle-id':
        args.bundleId = argv[++i] || DEFAULT_APP_BUNDLE;
        break;
      case '--label':
        args.label = argv[++i] || DEFAULT_LABEL;
        break;
      case '--search-label':
        args.searchLabel = argv[++i] || '搜索';
        break;
      case '--scroll-to-label':
        args.scrollToLabel = argv[++i] || '开发者';
        break;
      case '--input-bundle-id':
        args.inputBundleId = argv[++i] || '';
        break;
      case '--input-label':
        args.inputLabel = argv[++i] || '';
        break;
      case '--input-traits':
        args.inputTraits = argv[++i] || '';
        break;
      case '--input-content':
        args.inputContent = argv[++i] || '蓝牙';
        break;
      case '--input-prepare-label':
        args.inputPrepareLabel = argv[++i] || '';
        break;
      case '--input-open-url':
        args.inputOpenUrl = argv[++i] || '';
        break;
      case '--wda-bundle-id':
        args.wdaBundleId = argv[++i] || '';
        break;
      case '--appium-host':
        args.appiumHost = argv[++i] || '127.0.0.1';
        break;
      case '--appium-port':
        args.appiumPort = Number(argv[++i] || 4723);
        break;
      case '--appium-wda-url':
        args.appiumWdaUrl = argv[++i] || '';
        break;
      case '--wda-local-port':
        args.wdaLocalPort = argv[++i] || '';
        break;
      case '--wda-launch-timeout-ms':
        args.wdaLaunchTimeoutMs = Number(argv[++i] || 120000);
        break;
      case '--appium-show-xcode-log':
        args.appiumShowXcodeLog = true;
        break;
      case '--skip-driver-version-check':
        args.skipDriverVersionCheck = true;
        break;
      case '--help':
      case '-h':
        printHelp();
        process.exit(0);
      default:
        throw new Error(`Unknown arg: ${arg}`);
    }
  }

  if (!BENCHES.has(args.bench)) {
    throw new Error(`--bench must be one of: ${[...BENCHES].join(', ')}`);
  }
  if (!Number.isInteger(args.iterations) || args.iterations <= 0) {
    throw new Error('--iterations must be a positive integer');
  }
  if (!(args.preset in PRESETS)) {
    throw new Error(`--preset must be one of: ${Object.keys(PRESETS).join(', ')}`);
  }
  if (!args.udid && !args.listCases) {
    throw new Error('Missing --udid. Benchmark only supports real devices.');
  }
  if (args.udid && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(args.udid)) {
    throw new Error('Simulator UUID detected. Benchmark only supports real devices.');
  }
  if (args.bench === 'ios-use' && !args.driverIpa && !args.listCases) {
    throw new Error('--driver-ipa is required for --bench ios-use. Build/sign/config outside benchmark; this script only measures.');
  }
  if (args.bench === 'wda' && !args.wdaBundleId && !args.listCases) {
    throw new Error('Missing --wda-bundle-id or WDA_BUNDLE_ID for --bench wda.');
  }
  if (args.output && path.extname(args.output) !== '.json') {
    throw new Error('--output must be a .json path. Markdown output is intentionally not supported.');
  }
  if (args.inputOpenUrl && args.bench === 'wda') {
    throw new Error('--input-open-url is only supported for --bench ios-use; WDA benchmark must prepare equivalent app state.');
  }

  args.inputBundleId ||= args.bundleId;
  args.inputLabel ||= args.searchLabel;
  if (args.inputTraits.toLowerCase() === 'none') args.inputTraits = '';
  args.inputPrepareLabel ||= args.inputBundleId === args.bundleId ? args.label : args.inputLabel;
  return args;
}

function printHelp() {
  console.log(`
Usage:
  node scripts/benchmark.js --bench ios-use --udid <real-device-udid> --driver-ipa <path> [options]
  node scripts/benchmark.js --bench wda --udid <real-device-udid> --wda-bundle-id <bundle-id> [options]

What this script does:
  - Measures already prepared real-device automation paths.
  - Writes exactly one JSON report. Markdown output is not supported.
  - Never builds ios-use, never builds driver, never signs IPA, never runs ios-use config,
    never installs driver. Prepare those outside benchmark.

Required for --bench ios-use:
  --udid <id>          Real device UDID.
  --driver-ipa <path> Driver IPA path used as the identity gate for this run.
                       The device must already be configured with this driver version.

Required for --bench wda:
  --udid <id>          Real device UDID.
  --wda-bundle-id <id> Installed WebDriverAgent runner bundle id.

Common options:
  --ios-use-bin <path> ios-use binary to execute. Default: repo ./ios-use if present.
                       The script will not build it.
  --output <path>      JSON report path. Default:
                       $IOS_USE_HOME/artifacts/benchmark/benchmark-<bench>-<timestamp>.json
  --baseline <path>    Compare current averages with a previous JSON report.
                       Historical markdown reports are accepted for migration comparisons.
  --iterations <n>     Iterations per repeated case. Default: ${DEFAULT_ITERATIONS}.
  --preset <name>      full|read|lifecycle|mutate|app|smoke. Default: full.
  --cases <list>       Comma-separated explicit case ids. Overrides --preset.
  --list-cases         Print case ids and exit without touching device.

App/UI options:
  --bundle-id <id>           App under test. Default: ${DEFAULT_APP_BUNDLE}.
  --label <text>             Anchor label for find/waitFor. Default: ${DEFAULT_LABEL}.
  --search-label <text>      SearchField label for input case. Default: 搜索.
  --scroll-to-label <text>   Target label for scroll_to_visible. Default: 开发者.
  --input-bundle-id <id>     App for input case. Default: --bundle-id.
  --input-label <text>       Input target label. Default: --search-label.
  --input-traits <traits>    Input target traits. Default: SearchField; use none to disable.
  --input-content <text>     Text for input case. Default: 蓝牙.
  --input-prepare-label <t>  Label to wait before input. Default: input label or anchor label.
  --input-open-url <url>     ios-use-only input preparation by URL.

WDA/Appium options:
  --appium-host <host>          Default: 127.0.0.1.
  --appium-port <port>          Default: 4723.
  --appium-wda-url <url>        Existing WDA attach URL. Default: APPIUM_WDA_URL.
  --wda-local-port <port>       Local WDA port when Appium launches preinstalled WDA.
  --wda-launch-timeout-ms <ms>  Default: 120000.
  --appium-show-xcode-log       Forward Appium Xcode logs.

Driver identity check:
  For --bench ios-use, the script reads CFBundleShortVersionString from --driver-ipa and
  compares it with $IOS_USE_HOME/config.json devices[udid].driverVersion before measuring.
  If they differ, prepare the device outside benchmark and rerun. Use
  --skip-driver-version-check only for forensic runs.

Examples:
  # Fast read-path ios-use benchmark, no signing/building/config:
  node scripts/benchmark.js --bench ios-use --udid 00008150-0015309E2EE3401C \\
    --driver-ipa .ios-use/driver.ipa --preset read --iterations 5

  # Full ios-use benchmark with baseline comparison:
  node scripts/benchmark.js --bench ios-use --udid 00008150-0015309E2EE3401C \\
    --driver-ipa .ios-use/driver.ipa --baseline ~/.ios-use/artifacts/benchmark/old.json

  # WDA/Appium benchmark only:
  node scripts/benchmark.js --bench wda --udid 00008150-0015309E2EE3401C \\
    --wda-bundle-id com.example.WebDriverAgentRunner.xctrunner --preset read
`.trim());
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

function gitMetadata() {
  return {
    commit: gitOutput(['rev-parse', '--short=12', 'HEAD']) || 'unknown',
    branch: gitOutput(['branch', '--show-current']) || 'unknown',
    status: gitOutput(['status', '--short']) ? 'dirty' : 'clean',
  };
}

function nowNs() {
  return process.hrtime.bigint();
}

function nsToMs(ns) {
  return Number(ns) / 1_000_000;
}

function avg(values) {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid];
}

function measureSummary(samples) {
  if (samples.length === 0) {
    return { avg: null, median: null, min: null, max: null };
  }
  return {
    avg: avg(samples),
    median: median(samples),
    min: Math.min(...samples),
    max: Math.max(...samples),
  };
}

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
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
    if (args[i].startsWith('--udid=')) continue;
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

function customStopSessionQuiet() {
  try {
    cli(['stop'], { allowFailure: true });
  } catch {
    // ignore cleanup failure
  }
}

function customEnsureDriverStarted(udid) {
  const lock = readDriverLock();
  if (lock?.udid === udid) return;
  if (lock) cli(['stop'], { allowFailure: true });
  cli(['start', udid], { capture: false });
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
  for (const processInfo of listDeviceProcesses(udid)) {
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

function terminateWdaProcesses(udid) {
  terminateProcessesByExecutableName(udid, ['WebDriverAgentRunner-Runner']);
}

async function waitForProcessesGone(udid, executableNames, timeoutMs = 8000) {
  const targets = new Set(executableNames.filter(Boolean));
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    const stillRunning = listDeviceProcesses(udid).some(processInfo => {
      const executable = String(processInfo?.executable || '');
      const basename = executable.split('/').pop() || '';
      return targets.has(basename);
    });
    if (!stillRunning) return;
    await sleep(500);
  }
}

async function customPrepareStopped(ctx) {
  terminateWdaProcesses(ctx.udid);
  await waitForProcessesGone(ctx.udid, ['WebDriverAgentRunner-Runner']);
  customStopSessionQuiet();
  terminateCustomDriverProcesses(ctx.udid);
  await waitForProcessesGone(ctx.udid, ['IOSUseDriver-Runner', 'IOSUseDriverXCTest-Runner']);
}

async function customPrepareAppSession(ctx, appBundle = ctx.bundleId, label = ctx.label) {
  terminateWdaProcesses(ctx.udid);
  await waitForProcessesGone(ctx.udid, ['WebDriverAgentRunner-Runner']);
  customEnsureDriverStarted(ctx.udid);
  cli(['terminateApp', appBundle, '--udid', ctx.udid], { allowFailure: true });
  cli(['activateApp', appBundle, '--udid', ctx.udid]);
  cli(['waitFor', '--label', label, '--timeout', '8', '--udid', ctx.udid]);
}

async function customPrepareInputSession(ctx) {
  terminateWdaProcesses(ctx.udid);
  await waitForProcessesGone(ctx.udid, ['WebDriverAgentRunner-Runner']);
  customEnsureDriverStarted(ctx.udid);
  cli(['terminateApp', ctx.inputBundleId, '--udid', ctx.udid], { allowFailure: true });
  if (ctx.inputOpenUrl) {
    cli(['open', ctx.inputOpenUrl, '--udid', ctx.udid]);
  } else {
    cli(['activateApp', ctx.inputBundleId, '--udid', ctx.udid]);
  }
  cli(['waitFor', '--label', ctx.inputPrepareLabel, '--timeout', '8', '--udid', ctx.udid]);
}

function resolveWdaLocalPort(args) {
  if (args.wdaLocalPort) return String(args.wdaLocalPort);
  for (let port = 8100; port <= 8109; port += 1) {
    try {
      execFileSync('/bin/sh', ['-lc', `lsof -nP -iTCP:${port} -sTCP:LISTEN -t`], {
        stdio: 'ignore',
      });
    } catch {
      return String(port);
    }
  }
  throw new Error('No free WDA local port found in range 8100-8109. Pass --wda-local-port to override.');
}

function appendAppiumHint(message, ctx) {
  const normalized = String(message || '');
  const lower = normalized.toLowerCase();
  const hints = [];
  if (lower.includes('tunnel registry port not found') || lower.includes('remote xpc tunnel')) {
    hints.push(`Run \`sudo appium driver run xcuitest tunnel-creation --udid ${ctx.udid}\` first.`);
  }
  if (lower.includes('parse error: expected http/, rtsp/ or ice/')) {
    hints.push('Appium may be connected to a non-HTTP stream on the forwarded WDA port.');
  }
  if (lower.includes('failed to start the preinstalled webdriveragent')) {
    hints.push(`Confirm \`${ctx.wdaBundleId}\` is installed and launchable.`);
  }
  return hints.length ? `${normalized} | hint=${hints.join(' ')}` : normalized;
}

async function appiumRequest(ctx, method, endpoint, body, timeoutMs = DEFAULT_TIMEOUT_MS) {
  const response = await fetch(`${ctx.appiumBaseUrl}${endpoint}`, {
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
    throw new Error(appendAppiumHint(`Appium ${method} ${endpoint} failed (${response.status})\n${typeof payload === 'string' ? payload : JSON.stringify(payload)}`, ctx));
  }
  if (payload && typeof payload === 'object' && payload.value && payload.value.error) {
    throw new Error(appendAppiumHint(`Appium ${method} ${endpoint} error=${payload.value.error} message=${payload.value.message || JSON.stringify(payload.value)}`, ctx));
  }
  return payload;
}

async function isAppiumHealthy(ctx) {
  try {
    const payload = await appiumRequest(ctx, 'GET', '/status', undefined, 3000);
    return payload?.value?.ready === true || payload?.value?.build;
  } catch {
    return false;
  }
}

async function startAppiumServer(ctx) {
  if (await isAppiumHealthy(ctx)) return false;
  ensureDir(LOG_DIR);
  const logFile = path.join(LOG_DIR, 'appium-benchmark.log');
  const outFd = fs.openSync(logFile, 'a');
  try {
    appiumProcess = spawn('appium', ['server', '--address', ctx.appiumHost, '--port', String(ctx.appiumPort)], {
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
    if (await isAppiumHealthy(ctx)) return true;
  }
  throw new Error('Appium server failed to start within 30s');
}

function stopAppiumServer(ctx) {
  if (!appiumStartedByScript) return;
  try {
    execFileSync('/bin/sh', ['-lc', `lsof -ti :${ctx.appiumPort} -sTCP:LISTEN | xargs kill -9 2>/dev/null || true`], {
      stdio: 'ignore',
    });
  } catch {
    // ignore cleanup failure
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

class AppiumDriver {
  constructor(ctx) {
    this.ctx = ctx;
    this.sessionId = null;
  }

  async request(method, endpoint, body, timeoutMs = DEFAULT_TIMEOUT_MS) {
    if (!this.sessionId) throw new Error('Appium session is not ready');
    const payload = await appiumRequest(this.ctx, method, `/session/${this.sessionId}${endpoint}`, body, timeoutMs);
    return payload?.value;
  }

  async createSession() {
    await startAppiumServer(this.ctx);
    const capabilities = {
      platformName: 'iOS',
      'appium:automationName': 'XCUITest',
      'appium:udid': this.ctx.udid,
      'appium:bundleId': this.ctx.bundleId,
      'appium:noReset': true,
      'appium:newCommandTimeout': 0,
      'appium:wdaLaunchTimeout': this.ctx.wdaLaunchTimeoutMs,
    };
    if (this.ctx.appiumShowXcodeLog) {
      capabilities['appium:showXcodeLog'] = true;
    }
    if (this.ctx.appiumWdaUrl) {
      capabilities['appium:webDriverAgentUrl'] = this.ctx.appiumWdaUrl;
    } else {
      capabilities['appium:usePreinstalledWDA'] = true;
      capabilities['appium:updatedWDABundleId'] = this.ctx.appiumUpdatedWdaBundleId;
      capabilities['appium:wdaLocalPort'] = this.ctx.wdaLocalPort;
    }
    const payload = await appiumRequest(this.ctx, 'POST', '/session', {
      capabilities: { alwaysMatch: capabilities, firstMatch: [{}] },
      desiredCapabilities: capabilities,
    }, 120000);
    const sessionId = extractSessionId(payload);
    if (!sessionId) {
      throw new Error(`Appium createSession returned no sessionId: ${JSON.stringify(payload)}`);
    }
    this.sessionId = sessionId;
    return payload;
  }

  async ensureSession() {
    if (!this.sessionId) await this.createSession();
  }

  async deleteSession() {
    if (!this.sessionId) return;
    try {
      await appiumRequest(this.ctx, 'DELETE', `/session/${this.sessionId}`, undefined, 30000);
    } catch {
      // ignore
    } finally {
      this.sessionId = null;
    }
  }

  async close() {
    await this.deleteSession();
  }

  async resetState() {
    await this.deleteSession();
  }

  async source() {
    await this.ensureSession();
    return await this.request('GET', '/source', undefined, 60000);
  }

  async screenshotToFile(name = 'benchmark-wda-appium') {
    await this.ensureSession();
    const base64 = await this.request('GET', '/screenshot');
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
    const payload = await this.request('POST', '/element', { using, value });
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

  async updateSettings(settings) {
    await this.ensureSession();
    return await this.request('POST', '/appium/settings', { settings });
  }

  async execute(script, args = [], timeoutMs = DEFAULT_TIMEOUT_MS) {
    await this.ensureSession();
    return await this.request('POST', '/execute/sync', { script, args }, timeoutMs);
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

  async activateApp(bundleId = this.ctx.bundleId) {
    await this.ensureSession();
    return await this.request('POST', '/appium/device/activate_app', { bundleId });
  }

  async terminateApp(bundleId = this.ctx.bundleId) {
    await this.ensureSession();
    return await this.request('POST', '/appium/device/terminate_app', { bundleId });
  }
}

async function appiumPrepareNoSession(ctx) {
  customStopSessionQuiet();
  terminateCustomDriverProcesses(ctx.udid);
  await ctx.appium.resetState();
  await waitForProcessesGone(ctx.udid, ['IOSUseDriver-Runner', 'IOSUseDriverXCTest-Runner']);
  await sleep(2000);
}

async function appiumPrepareSettingsHome(ctx) {
  customStopSessionQuiet();
  terminateCustomDriverProcesses(ctx.udid);
  await ctx.appium.resetState();
  await waitForProcessesGone(ctx.udid, ['IOSUseDriver-Runner', 'IOSUseDriverXCTest-Runner']);
  await sleep(1000);
  await ctx.appium.createSession();
  await ctx.appium.updateSettings({ screenshotQuality: WDA_SCREENSHOT_QUALITY });
  try {
    await ctx.appium.terminateApp(ctx.bundleId);
  } catch {
    // ignore
  }
  await ctx.appium.activateApp(ctx.bundleId);
  await ctx.appium.waitForElement(ctx.label, 8000, 500);
}

async function appiumPrepareInputSession(ctx) {
  customStopSessionQuiet();
  terminateCustomDriverProcesses(ctx.udid);
  await ctx.appium.resetState();
  await waitForProcessesGone(ctx.udid, ['IOSUseDriver-Runner', 'IOSUseDriverXCTest-Runner']);
  await sleep(1000);
  await ctx.appium.createSession();
  await ctx.appium.updateSettings({ screenshotQuality: WDA_SCREENSHOT_QUALITY });
  try {
    await ctx.appium.terminateApp(ctx.inputBundleId);
  } catch {
    // ignore
  }
  await ctx.appium.activateApp(ctx.inputBundleId);
  await ctx.appium.waitForElement(ctx.inputPrepareLabel, 8000, 500);
}

function buildCases(ctx) {
  const centerX = 187;
  const topTapY = 80;
  const swipeDistance = 200;

  return [
    {
      id: 'start_session',
      kind: 'lifecycle',
      runs: 1,
      mapping: '`ios-use start <udid>` / Appium `POST /session`',
      iosPrepare: async () => { await customPrepareStopped(ctx); },
      iosRun: async () => { cli(['start', ctx.udid]); },
      wdaPrepare: async () => { await appiumPrepareNoSession(ctx); },
      wdaRun: async () => { await ctx.appium.createSession(); },
    },
    {
      id: 'start_and_activate_app',
      kind: 'lifecycle',
      runs: 1,
      mapping: '`start <udid>` + `activateApp` / Appium session + activate app',
      iosPrepare: async () => { await customPrepareStopped(ctx); },
      iosRun: async () => {
        cli(['start', ctx.udid]);
        cli(['activateApp', ctx.bundleId, '--udid', ctx.udid]);
      },
      wdaPrepare: async () => { await appiumPrepareNoSession(ctx); },
      wdaRun: async () => {
        await ctx.appium.createSession();
        await ctx.appium.activateApp(ctx.bundleId);
      },
    },
    {
      id: 'dom_vs_source',
      kind: 'read',
      runs: ctx.iterations,
      mapping: '`ios-use dom` / WDA `GET /source`',
      iosPrepare: async () => { await customPrepareAppSession(ctx); },
      iosRun: async () => { cli(['dom', '--udid', ctx.udid]); },
      wdaPrepare: async () => { await appiumPrepareSettingsHome(ctx); },
      wdaRun: async () => { await ctx.appium.source(); },
    },
    {
      id: 'find',
      kind: 'read',
      runs: ctx.iterations,
      mapping: '`ios-use find <label>` / WDA `POST /element`',
      iosPrepare: async () => { await customPrepareAppSession(ctx); },
      iosRun: async () => { cli(['find', ctx.label, '--udid', ctx.udid]); },
      wdaPrepare: async () => { await appiumPrepareSettingsHome(ctx); },
      wdaRun: async () => { await ctx.appium.findElement(ctx.label); },
    },
    {
      id: 'wait_for',
      kind: 'read',
      runs: ctx.iterations,
      mapping: '`ios-use waitFor` / repeated WDA `POST /element`',
      iosPrepare: async () => { await customPrepareAppSession(ctx); },
      iosRun: async () => { cli(['waitFor', '--label', ctx.label, '--timeout', '8', '--udid', ctx.udid]); },
      wdaPrepare: async () => { await appiumPrepareSettingsHome(ctx); },
      wdaRun: async () => { await ctx.appium.waitForElement(ctx.label, 8000, 500); },
    },
    {
      id: 'screenshot',
      kind: 'read',
      runs: ctx.iterations,
      mapping: '`ios-use screenshot` / WDA `GET /screenshot`',
      iosPrepare: async () => { await customPrepareAppSession(ctx); },
      iosRun: async () => { cli(['screenshot', '--name', 'benchmark-ios-use', '--udid', ctx.udid]); },
      wdaPrepare: async () => { await appiumPrepareSettingsHome(ctx); },
      wdaRun: async () => { await ctx.appium.screenshotToFile('benchmark-wda-appium'); },
    },
    {
      id: 'tap_coord',
      kind: 'mutate',
      runs: ctx.iterations,
      mapping: '`ios-use tap x,y` / WDA pointer action',
      iosPrepare: async () => { await customPrepareAppSession(ctx); },
      iosRun: async () => { cli(['tap', `${centerX},${topTapY}`, '--udid', ctx.udid]); },
      wdaPrepare: async () => { await appiumPrepareSettingsHome(ctx); },
      wdaRun: async () => { await ctx.appium.tap(centerX, topTapY); },
    },
    {
      id: 'tap_label',
      kind: 'mutate',
      runs: ctx.iterations,
      mapping: '`ios-use tap <label>` / WDA find + click',
      iosPrepare: async () => { await customPrepareAppSession(ctx); },
      iosRun: async () => { cli(['tap', ctx.label, '--udid', ctx.udid]); },
      wdaPrepare: async () => { await appiumPrepareSettingsHome(ctx); },
      wdaRun: async () => {
        const elementId = await ctx.appium.findElement(ctx.label);
        await ctx.appium.clickElement(elementId);
      },
    },
    {
      id: 'longpress_coord',
      kind: 'mutate',
      runs: ctx.iterations,
      mapping: '`ios-use longpress x,y` / WDA pointer action',
      iosPrepare: async () => { await customPrepareAppSession(ctx); },
      iosRun: async () => { cli(['longpress', `${centerX},${topTapY}`, '--duration', '500', '--udid', ctx.udid]); },
      wdaPrepare: async () => { await appiumPrepareSettingsHome(ctx); },
      wdaRun: async () => { await ctx.appium.longPress(centerX, topTapY, 500); },
    },
    {
      id: 'input',
      kind: 'mutate',
      runs: ctx.iterations,
      mapping: '`ios-use input --label <label>` / WDA find + click + keys',
      iosPrepare: async () => { await customPrepareInputSession(ctx); },
      iosRun: async () => {
        const args = ['input', '--label', ctx.inputLabel, '--content', ctx.inputContent, '--udid', ctx.udid];
        if (ctx.inputTraits) args.splice(args.length - 2, 0, '--traits', ctx.inputTraits);
        cli(args);
      },
      wdaPrepare: async () => { await appiumPrepareInputSession(ctx); },
      wdaRun: async () => {
        const elementId = await ctx.appium.findElement(ctx.inputLabel);
        await ctx.appium.clickElement(elementId);
        await ctx.appium.keys(ctx.inputContent);
      },
    },
    {
      id: 'swipe_distance',
      kind: 'mutate',
      runs: ctx.iterations,
      mapping: '`ios-use swipe --distance 200 --dir forth` / WDA drag action',
      iosPrepare: async () => { await customPrepareAppSession(ctx); },
      iosRun: async () => { cli(['swipe', '--distance', String(swipeDistance), '--dir', 'forth', '--udid', ctx.udid]); },
      wdaPrepare: async () => { await appiumPrepareSettingsHome(ctx); },
      wdaRun: async () => {
        const rect = await ctx.appium.getWindowRect();
        const x = Math.round((rect.width || rect.value?.width) / 2);
        const height = rect.height || rect.value?.height;
        const startY = Math.round(height * 0.72);
        await ctx.appium.drag(x, startY, x, startY - swipeDistance, 250);
      },
    },
    {
      id: 'scroll_to_visible',
      kind: 'mutate',
      runs: ctx.iterations,
      mapping: '`ios-use swipe --to <label> --from <label>` / WDA mobile scroll loop',
      iosPrepare: async () => { await customPrepareAppSession(ctx); },
      iosRun: async () => { cli(['swipe', '--to', ctx.scrollToLabel, '--from', ctx.label, '--udid', ctx.udid]); },
      wdaPrepare: async () => { await appiumPrepareSettingsHome(ctx); },
      wdaRun: async () => {
        const maxScrolls = 10;
        const collectionViewId = await ctx.appium.findElementByPredicate(`type == 'XCUIElementTypeCollectionView'`);
        const targetPredicate = `label == "${ctx.scrollToLabel}" AND visible == 1`;
        for (let scrollCount = 0; scrollCount <= maxScrolls; scrollCount += 1) {
          try {
            await ctx.appium.findElementByPredicate(targetPredicate);
            return;
          } catch {
            if (scrollCount === maxScrolls) break;
          }
          await ctx.appium.mobileScroll({ elementId: collectionViewId, direction: 'down' });
        }
        throw new Error(`WDA scroll_to_visible timed out after ${maxScrolls} scrolls: ${ctx.scrollToLabel}`);
      },
    },
    {
      id: 'activate_app',
      kind: 'app',
      runs: ctx.iterations,
      mapping: '`ios-use activateApp` / WDA activate app',
      iosPrepare: async () => { await customPrepareAppSession(ctx); },
      iosRun: async () => {
        cli(['terminateApp', ctx.bundleId, '--udid', ctx.udid], { allowFailure: true });
        cli(['activateApp', ctx.bundleId, '--udid', ctx.udid]);
      },
      wdaPrepare: async () => { await appiumPrepareSettingsHome(ctx); },
      wdaRun: async () => {
        try {
          await ctx.appium.terminateApp(ctx.bundleId);
        } catch {
          // ignore
        }
        await ctx.appium.activateApp(ctx.bundleId);
      },
    },
    {
      id: 'terminate_app',
      kind: 'app',
      runs: ctx.iterations,
      mapping: '`ios-use terminateApp` / WDA terminate app',
      iosPrepare: async () => { await customPrepareAppSession(ctx); },
      iosRun: async () => { cli(['terminateApp', ctx.bundleId, '--udid', ctx.udid]); },
      wdaPrepare: async () => { await appiumPrepareSettingsHome(ctx); },
      wdaRun: async () => { await ctx.appium.terminateApp(ctx.bundleId); },
    },
  ];
}

function selectedCases(args, cases) {
  if (args.cases) {
    const selected = new Set(args.cases.split(',').map(item => item.trim()).filter(Boolean));
    const known = new Set(cases.map(item => item.id));
    const unknown = [...selected].filter(item => !known.has(item));
    if (unknown.length > 0) {
      throw new Error(`Unknown benchmark case(s): ${unknown.join(', ')}`);
    }
    return cases.filter(item => selected.has(item.id));
  }
  const presetCases = PRESETS[args.preset];
  if (!presetCases) return cases;
  const selected = new Set(presetCases);
  return cases.filter(item => selected.has(item.id));
}

async function measureCase(sideName, runs, prepareFn, runFn) {
  const samples = [];
  const errors = [];
  let fails = 0;
  console.error(`[bench:${sideName}] x${runs}`);
  for (let i = 0; i < runs; i += 1) {
    try {
      await prepareFn();
    } catch (error) {
      fails += 1;
      errors.push({ phase: 'prepare', message: error.message });
      console.error(`[bench:${sideName}] prepare fail: ${error.message}`);
      continue;
    }
    const startedAt = nowNs();
    try {
      await runFn();
      samples.push(nsToMs(nowNs() - startedAt));
    } catch (error) {
      fails += 1;
      errors.push({ phase: 'run', message: error.message });
      console.error(`[bench:${sideName}] run fail: ${error.message}`);
    }
  }
  return {
    samples,
    fails,
    errors,
    ...measureSummary(samples),
  };
}

function readDriverIpaVersion(ipaPath) {
  const resolved = path.resolve(expandHome(ipaPath));
  if (!fs.existsSync(resolved)) {
    throw new Error(`--driver-ipa does not exist: ${resolved}`);
  }
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ios-use-benchmark-'));
  const plistPath = path.join(tempDir, 'Info.plist');
  try {
    const plist = execFileSync('/usr/bin/unzip', ['-p', resolved, 'Payload/*.app/Info.plist']);
    fs.writeFileSync(plistPath, plist);
    const version = execFileSync('/usr/bin/plutil', ['-extract', 'CFBundleShortVersionString', 'raw', '-o', '-', plistPath], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    return { path: resolved, version };
  } finally {
    try { fs.rmSync(tempDir, { recursive: true, force: true }); } catch {}
  }
}

function readConfiguredDriverVersion(udid) {
  const configPath = path.join(IOS_USE_HOME, 'config.json');
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const version = config?.devices?.[udid]?.driverVersion;
  if (typeof version !== 'string' || version.length === 0) {
    throw new Error(`config.json missing devices[${udid}].driverVersion. Run ios-use config outside benchmark first.`);
  }
  return version;
}

function validateDriverIdentity(args) {
  if (args.bench !== 'ios-use') return null;
  const ipa = readDriverIpaVersion(args.driverIpa);
  let configuredVersion = '';
  if (!args.skipDriverVersionCheck) {
    configuredVersion = readConfiguredDriverVersion(args.udid);
    if (configuredVersion !== ipa.version) {
      throw new Error(`Driver version mismatch: --driver-ipa version=${ipa.version}, configured driverVersion=${configuredVersion}. Prepare/sign/install/config outside benchmark, then rerun.`);
    }
  } else {
    try {
      configuredVersion = readConfiguredDriverVersion(args.udid);
    } catch {
      configuredVersion = 'unknown';
    }
  }
  return {
    ipaPath: ipa.path,
    ipaVersion: ipa.version,
    configuredDriverVersion: configuredVersion,
    versionCheck: args.skipDriverVersionCheck ? 'skipped' : 'passed',
  };
}

function parseJsonBaseline(filePath) {
  const payload = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  const rows = new Map();
  for (const row of payload.results || payload.rows || []) {
    const id = row.id || row.case || row.name;
    const result = row.result || row.custom || row.customResult;
    if (!id || !result) continue;
    rows.set(id, {
      avg: result.avg,
      median: result.median,
      fails: result.fails,
    });
  }
  return rows;
}

function parseMarkdownBaseline(filePath) {
  const text = fs.readFileSync(filePath, 'utf8');
  const rows = new Map();
  for (const line of text.split('\n')) {
    if (!line.startsWith('| ')) continue;
    const cells = line.split('|').slice(1, -1).map(cell => cell.trim());
    if (cells.length < 7 || !/^-?\d+(\.\d+)?$/.test(cells[2])) continue;
    rows.set(cells[0].replaceAll('`', ''), {
      avg: Number(cells[2]),
      median: Number(cells[3]),
      fails: Number(cells[6]),
    });
  }
  return rows;
}

function compareBaseline(results, baselinePath) {
  if (!baselinePath) return [];
  const resolved = path.resolve(expandHome(baselinePath));
  if (!fs.existsSync(resolved)) {
    throw new Error(`--baseline does not exist: ${resolved}`);
  }
  const baseline = resolved.endsWith('.json') ? parseJsonBaseline(resolved) : parseMarkdownBaseline(resolved);
  return results
    .map(row => {
      const base = baseline.get(row.id);
      if (!base || typeof base.avg !== 'number' || typeof row.result.avg !== 'number') return null;
      const deltaMs = row.result.avg - base.avg;
      return {
        id: row.id,
        currentAvgMs: row.result.avg,
        baselineAvgMs: base.avg,
        deltaMs,
        deltaPct: base.avg === 0 ? null : (deltaMs / base.avg) * 100,
      };
    })
    .filter(Boolean);
}

function reproCommand(args, outputPath) {
  const parts = [
    'node', 'scripts/benchmark.js',
    '--bench', args.bench,
    '--udid', args.udid,
    '--output', outputPath,
    '--iterations', String(args.iterations),
    '--preset', args.preset,
  ];
  if (args.iosUseBin) parts.push('--ios-use-bin', args.iosUseBin);
  if (args.driverIpa) parts.push('--driver-ipa', path.resolve(expandHome(args.driverIpa)));
  if (args.baseline) parts.push('--baseline', path.resolve(expandHome(args.baseline)));
  if (args.cases) parts.push('--cases', args.cases);
  if (args.bundleId !== DEFAULT_APP_BUNDLE) parts.push('--bundle-id', args.bundleId);
  if (args.label !== DEFAULT_LABEL) parts.push('--label', args.label);
  if (args.searchLabel !== '搜索') parts.push('--search-label', args.searchLabel);
  if (args.scrollToLabel !== '开发者') parts.push('--scroll-to-label', args.scrollToLabel);
  if (args.inputBundleId !== args.bundleId) parts.push('--input-bundle-id', args.inputBundleId);
  if (args.inputLabel !== args.searchLabel) parts.push('--input-label', args.inputLabel);
  if (args.inputTraits !== 'SearchField') parts.push('--input-traits', args.inputTraits || 'none');
  if (args.inputContent !== '蓝牙') parts.push('--input-content', args.inputContent);
  if (args.inputPrepareLabel !== (args.inputBundleId === args.bundleId ? args.label : args.inputLabel)) parts.push('--input-prepare-label', args.inputPrepareLabel);
  if (args.inputOpenUrl) parts.push('--input-open-url', args.inputOpenUrl);
  if (args.wdaBundleId) parts.push('--wda-bundle-id', args.wdaBundleId);
  if (args.appiumHost !== '127.0.0.1') parts.push('--appium-host', args.appiumHost);
  if (args.appiumPort !== 4723) parts.push('--appium-port', String(args.appiumPort));
  if (args.appiumWdaUrl) parts.push('--appium-wda-url', args.appiumWdaUrl);
  if (args.wdaLocalPort) parts.push('--wda-local-port', args.wdaLocalPort);
  if (args.wdaLaunchTimeoutMs !== 120000) parts.push('--wda-launch-timeout-ms', String(args.wdaLaunchTimeoutMs));
  if (args.appiumShowXcodeLog) parts.push('--appium-show-xcode-log');
  if (args.skipDriverVersionCheck) parts.push('--skip-driver-version-check');
  return parts.map(shellQuote).join(' ');
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  const ctx = {
    ...args,
    appiumBaseUrl: `http://${args.appiumHost}:${args.appiumPort}`,
    appiumUpdatedWdaBundleId: args.wdaBundleId.replace(/\.xctrunner$/, ''),
    wdaLocalPort: args.bench === 'wda' ? resolveWdaLocalPort(args) : '',
    appium: null,
  };
  if (args.bench === 'wda') {
    ctx.appium = new AppiumDriver(ctx);
  }

  const allCases = buildCases(ctx);
  if (args.listCases) {
    console.log(JSON.stringify(allCases.map(item => ({
      id: item.id,
      kind: item.kind,
      runs: item.runs,
      mapping: item.mapping,
    })), null, 2));
    return;
  }

  iosUseExecutable = resolveIosUseBin(args.iosUseBin);
  const driver = validateDriverIdentity(args);
  const cases = selectedCases(args, allCases);
  if (cases.length === 0) {
    throw new Error('No benchmark cases selected.');
  }

  ensureDir(BENCHMARK_DIR);
  const outputPath = path.resolve(expandHome(args.output || path.join(BENCHMARK_DIR, `benchmark-${args.bench}-${benchmarkStamp()}.json`)));
  ensureDir(path.dirname(outputPath));

  const startedAt = nowNs();
  const results = [];
  try {
    for (const testCase of cases) {
      console.error(`\n[case] ${testCase.id} :: ${testCase.mapping}`);
      const result = args.bench === 'ios-use'
        ? await measureCase('ios-use', testCase.runs, testCase.iosPrepare, testCase.iosRun)
        : await measureCase('wda', testCase.runs, testCase.wdaPrepare, testCase.wdaRun);
      results.push({
        id: testCase.id,
        kind: testCase.kind,
        runs: testCase.runs,
        mapping: testCase.mapping,
        result,
      });
    }
  } finally {
    customStopSessionQuiet();
    if (ctx.appium) await ctx.appium.close();
    stopAppiumServer(ctx);
  }

  const report = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    bench: args.bench,
    git: gitMetadata(),
    iosUseHome: IOS_USE_HOME,
    iosUseBin: iosUseExecutable,
    device: {
      udid: args.udid,
      targetType: 'real-device',
    },
    driver,
    appium: args.bench === 'wda' ? {
      baseUrl: ctx.appiumBaseUrl,
      wdaBundleId: args.wdaBundleId,
      appiumUpdatedWdaBundleId: ctx.appiumUpdatedWdaBundleId,
      appiumWdaUrl: args.appiumWdaUrl || null,
      wdaLocalPort: ctx.wdaLocalPort,
      wdaLaunchTimeoutMs: args.wdaLaunchTimeoutMs,
    } : null,
    app: {
      bundleId: args.bundleId,
      label: args.label,
      searchLabel: args.searchLabel,
      scrollToLabel: args.scrollToLabel,
      inputBundleId: args.inputBundleId,
      inputLabel: args.inputLabel,
      inputTraits: args.inputTraits || 'none',
      inputContent: args.inputContent,
      inputPrepareLabel: args.inputPrepareLabel,
      inputOpenUrl: args.inputOpenUrl || null,
    },
    selection: {
      preset: args.preset,
      cases: cases.map(item => item.id),
      iterations: args.iterations,
    },
    durationMs: nsToMs(nowNs() - startedAt),
    results,
    baseline: args.baseline ? {
      path: path.resolve(expandHome(args.baseline)),
      comparison: compareBaseline(results, args.baseline),
    } : null,
    reproCommand: reproCommand(args, outputPath),
    notes: [
      'This benchmark does not build ios-use, build driver, sign IPA, run config, or install driver.',
      'For ios-use runs, --driver-ipa is an identity gate; the configured device driverVersion must match the IPA version unless --skip-driver-version-check is used.',
      'Result timings are end-to-end wall time for the selected bench path.',
    ],
  };

  fs.writeFileSync(outputPath, `${JSON.stringify(report, null, 2)}\n`);
  console.log(`Benchmark JSON written to ${outputPath}`);
}

main().catch(error => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
