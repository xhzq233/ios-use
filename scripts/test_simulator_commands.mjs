#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  bridgeCase,
  simulatorCaseIds,
  simulatorCaseMetadataById,
  shouldRunPrerequisiteConfig,
  unsupportedCaseReasons,
  validateCaseMetadataSchema,
} from './simulator_case_registry.mjs';
import { buildContactsCases } from './sim/cases/contacts.mjs';
import { buildDeviceConfigCases } from './sim/cases/device-config.mjs';
import { buildFlowCases } from './sim/cases/flow.mjs';
import { buildHostBridgeCases } from './sim/cases/host-bridge.mjs';
import {
  buildSettingsAfterContactsCases,
  buildSettingsBeforeContactsCases,
} from './sim/cases/settings.mjs';

const decoder = new TextDecoder();
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');
let skipBuild = false;
let caseFilterIds;
let driverIpaPath = '';
const testIosUseHome = process.env.IOS_USE_TEST_HOME ?? path.join(os.homedir(), '.ios-use/test-homes/simulator-commands');
const iosUseCli = process.env.IOS_USE_TEST_CLI ?? path.join(rootDir, 'ios-use');


export function parseCaseFilter(value) {
  const ids = value
    .split(',')
    .map(part => part.trim().toUpperCase())
    .filter(Boolean);
  if (ids.length === 0) throw new Error('--case requires at least one case id');
  return new Set(ids);
}

export function isCaseSelected(id, filterIds) {
  if (!filterIds) return true;
  return filterIds.has(id.toUpperCase());
}

export function parseRunnerArgs(argv) {
  let parsedSkipBuild = false;
  let parsedCaseFilterIds;
  let parsedDriverIpaPath = '';
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--skip-build') {
      parsedSkipBuild = true;
    } else if (arg === '--case') {
      const value = argv[++i];
      if (!value) throw new Error('--case requires a value');
      parsedCaseFilterIds = parseCaseFilter(value);
    } else if (arg === '--driver-ipa') {
      const value = argv[++i];
      if (!value) throw new Error('--driver-ipa requires a value');
      parsedDriverIpaPath = path.resolve(value);
    } else if (arg.startsWith('--driver-ipa=')) {
      parsedDriverIpaPath = path.resolve(arg.slice('--driver-ipa='.length));
    } else {
      throw new Error(`unknown option ${arg}`);
    }
  }
  if (!parsedDriverIpaPath) {
    throw new Error('--driver-ipa is required; build or choose the Simulator driver IPA outside the full Simulator runner');
  }
  return { skipBuild: parsedSkipBuild, caseFilterIds: parsedCaseFilterIds, driverIpaPath: parsedDriverIpaPath };
}

export function validateCaseFilter(caseIds, filterIds) {
  if (!filterIds) return;
  const available = new Set([...caseIds].map(id => id.toUpperCase()));
  const unknown = [...filterIds].filter(id => !available.has(id));
  if (unknown.length > 0) {
    throw new Error(`unknown --case id: ${unknown.join(', ')}`);
  }
}

function validateCaseRegistry(caseIds) {
  const expected = simulatorCaseIds.map(id => id.toUpperCase());
  const actual = caseIds.map(id => id.toUpperCase());
  const expectedSet = new Set(expected);
  const actualSet = new Set(actual);
  const missing = expected.filter(id => !actualSet.has(id));
  const extra = actual.filter(id => !expectedSet.has(id));
  const firstMismatchIndex = expected.findIndex((id, index) => id !== actual[index]);
  if (missing.length === 0 && extra.length === 0 && firstMismatchIndex === -1 && expected.length === actual.length) return;

  const order = firstMismatchIndex === -1
    ? ''
    : ` first order mismatch at ${firstMismatchIndex}: registry=${expected[firstMismatchIndex]} runner=${actual[firstMismatchIndex] ?? '<none>'};`;
  throw new Error(`simulator case registry drift:${order} missing=${missing.join(',') || '<none>'}; extra=${extra.join(',') || '<none>'}`);
}

let sim;
let iosHome = '';
let artifactDir = '';
let stateBackupDir = '';
let flowDir = '';
let runLockFile = '';
let runLockFd;
const emptyHomeName = 'empty-home';
let passed = 0;
let failed = 0;
let skipped = 0;
let bridged = 0;
let unsupported = 0;
const caseResults = [];
const caseStartTimes = new Map();
const recoveryEvents = [];
let currentPhase = 'case';
let currentCaseId = '';
const simulatorDriverBundleId = 'com.iosuse.xcuidriver.xctrunner';
const driverReadyTimeoutMs = 180_000;

function stamp() {
  return new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function writeFile(file, content) {
  ensureDir(path.dirname(file));
  fs.writeFileSync(file, content);
}

function processExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function acquireRunLock() {
  runLockFile = path.join(iosHome, 'state/simulator-command-tests.lock');
  ensureDir(path.dirname(runLockFile));
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      runLockFd = fs.openSync(runLockFile, 'wx');
      fs.writeFileSync(runLockFd, `${process.pid}\n`);
      return;
    } catch (error) {
      const code = error && typeof error === 'object' && 'code' in error ? String(error.code) : '';
      if (code !== 'EEXIST') throw error;
      const lockText = readFileIfExists(runLockFile).trim();
      const lockPid = Number.parseInt(lockText, 10);
      if (Number.isFinite(lockPid) && processExists(lockPid)) {
        throw new Error(`simulator command test already running for IOS_USE_HOME ${iosHome} (pid ${lockPid})`);
      }
      fs.rmSync(runLockFile, { force: true });
    }
  }
  throw new Error(`failed to acquire simulator command test lock: ${runLockFile}`);
}

function releaseRunLock() {
  if (runLockFd === undefined) return;
  fs.closeSync(runLockFd);
  runLockFd = undefined;
  if (runLockFile) fs.rmSync(runLockFile, { force: true });
}

function readFileIfExists(file) {
  return fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
}

function findProxyPrecheckReferences() {
  const files = [
    'swift-cli/Sources/IOSUseCLI/Services/Proxy/ProxyService.swift',
    'swift-cli/Tests/IOSUseCLITests/ProxyServiceTests.swift',
  ];
  const forbidden = [
    'verifyDeviceCanReachMac',
    'ProxyProbeServer',
    'DEVICE_CANNOT_REACH_MAC',
    'ios-use-probe',
  ];
  const hits = [];
  for (const relativeFile of files) {
    const file = path.join(rootDir, relativeFile);
    const lines = readFileIfExists(file).split(/\r?\n/);
    lines.forEach((line, index) => {
      for (const term of forbidden) {
        if (line.includes(term)) {
          hits.push(`${relativeFile}:${index + 1}: ${term}`);
        }
      }
    });
  }
  return hits;
}

function runProcess(cmd, opts = {}) {
  const proc = spawnSync(cmd[0], cmd.slice(1), {
    cwd: opts.cwd ?? rootDir,
    env: { ...process.env, ...(opts.env ?? {}) },
    encoding: null,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return {
    code: proc.status ?? 1,
    stdout: decoder.decode(proc.stdout ?? new Uint8Array()),
    stderr: decoder.decode(proc.stderr ?? new Uint8Array()),
  };
}

function prepareSimulatorDriverAsset(src) {
  const dst = path.join(iosHome, 'driver-sim.ipa');
  if (!fs.existsSync(src)) {
    throw new Error(`prebuilt Simulator driver IPA not found: ${src}`);
  }
  ensureDir(path.dirname(dst));
  if (path.resolve(src) !== path.resolve(dst)) {
    fs.copyFileSync(src, dst);
  }
  return {
    sourcePath: src,
    installedPath: dst,
  };
}

function execCmd(cmd, opts = {}) {
  return runProcess(cmd, opts);
}

async function sleep(ms) {
  await new Promise(resolve => setTimeout(resolve, ms));
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

function readDriverLockInfo() {
  try {
    const lock = JSON.parse(readFileIfExists(path.join(iosHome, 'state/driver.lock')) || '{}');
    return typeof lock.udid === 'string' ? lock : null;
  } catch {
    return null;
  }
}

function runCli(args) {
  if (driverSideCommands.has(args[0])) {
    for (let i = 0; i < args.length; i++) {
      if ((args[i] === '--udid' && args[i + 1] === sim?.udid) || args[i] === `--udid=${sim?.udid}`) {
        throw new Error(`Simulator runner driver-side case must not pass --udid: ${args.join(' ')}`);
      }
    }
  }
  return execCmd([iosUseCli, ...args], {
    cwd: args[0] === 'config' ? iosHome : rootDir,
    env: { IOS_USE_HOME: iosHome },
  });
}

function runCliToFiles(args, out, err) {
  const res = runCli(args);
  writeFile(out, res.stdout);
  writeFile(err, res.stderr);
  return res;
}

function runExternalToFiles(cmd, out, err, env = {}) {
  const res = execCmd(cmd, { env: { IOS_USE_HOME: iosHome, ...env } });
  writeFile(out, res.stdout);
  writeFile(err, res.stderr);
  return res;
}

function selected(id) {
  return isCaseSelected(id, caseFilterIds);
}

function caseDurationMs(id) {
  const startedAt = caseStartTimes.get(id);
  if (startedAt === undefined) return undefined;
  return Math.round(performance.now() - startedAt);
}

function resultArtifacts(id) {
  if (!artifactDir || !fs.existsSync(artifactDir)) return [];
  return fs.readdirSync(artifactDir)
    .filter(file => file === 'cli.log' || file.startsWith(`${id}.`) || file.startsWith(`${id}-`))
    .sort()
    .map(file => path.join(artifactDir, file));
}

function finishCase(id, status, fields = {}) {
  const metadata = simulatorCaseMetadataById.get(id);
  const result = {
    id,
    group: metadata?.group ?? null,
    kind: metadata?.kind ?? null,
    status,
    phase: fields.phase ?? null,
    setup: metadata?.setup ?? null,
    assertion: metadata?.assertion ?? null,
    coverage: metadata?.coverage ?? null,
    durationMs: caseDurationMs(id) ?? null,
    attempts: fields.attempts ?? 1,
    reason: fields.reason ?? null,
    details: fields.details ? String(fields.details).slice(0, 4000) : null,
    artifacts: resultArtifacts(id),
  };
  caseResults.push(result);
  writeCaseResults();
  return result;
}

function writeCaseResults() {
  if (!artifactDir) return;
  writeFile(path.join(artifactDir, 'case-results.json'), `${JSON.stringify(caseResults, null, 2)}\n`);
}

function writeRecoveryEvents() {
  if (!artifactDir) return;
  writeFile(path.join(artifactDir, 'recovery-events.json'), `${JSON.stringify(recoveryEvents, null, 2)}\n`);
}

function recordRecovery(type, id, detail = '') {
  const event = {
    type,
    caseId: id || currentCaseId || null,
    phase: currentPhase,
    detail,
    at: new Date().toISOString(),
  };
  recoveryEvents.push(event);
  writeRecoveryEvents();
}

async function withPhase(phase, work) {
  const previous = currentPhase;
  currentPhase = phase;
  try {
    return await work();
  } finally {
    currentPhase = previous;
  }
}

function recordPass(id, fields = {}) {
  passed++;
  finishCase(id, 'passed', fields);
  console.log(`[sim-test] PASS ${id}`);
}

function recordFail(id, details, phase = currentPhase || 'case', fields = {}) {
  failed++;
  finishCase(id, 'failed', { ...fields, phase, details });
  console.log(`[sim-test] FAIL ${id}`);
  if (details) process.stderr.write(details);
}

function recordSkip(id) {
  skipped++;
  finishCase(id, 'skipped');
  if (caseFilterIds) return;
  console.log(`[sim-test] SKIP ${id}`);
}

function recordUnsupported(id, reason) {
  unsupported++;
  finishCase(id, 'unsupported', { reason });
  console.log(`[sim-test] UNSUPPORTED ${id}: ${reason}`);
}

function recordBridged(id, source, reason) {
  bridged++;
  finishCase(id, 'bridged', { reason: `${source}: ${reason}` });
  console.log(`[sim-test] BRIDGED ${id}: ${source}`);
}

async function runSetup(id, setup) {
  if (!setup) return true;
  try {
    await withPhase('setup', async () => setup());
    return true;
  } catch (error) {
    recordFail(id, `${error instanceof Error ? error.stack || error.message : String(error)}\n`, 'setup');
    return false;
  }
}

async function runCommand(id, args, out, err) {
  try {
    return await withPhase('command', async () => runCliToFiles(args, out, err));
  } catch (error) {
    recordFail(id, `${error instanceof Error ? error.stack || error.message : String(error)}\n`, 'command');
    return null;
  }
}

async function runCase(id, args, setup) {
  if (!selected(id)) return recordSkip(id);
  if (!await runSetup(id, setup)) return;
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')}`);
  const res = await runCommand(id, args, out, err);
  if (!res) return;
  if (res.code === 0) recordPass(id);
  else recordFail(id, res.stderr || res.stdout, 'command');
}

async function runCaseContains(id, expected, args, setup) {
  if (!selected(id)) return recordSkip(id);
  if (!await runSetup(id, setup)) return;
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')}`);
  const res = await runCommand(id, args, out, err);
  if (!res) return;
  if (res.code === 0 && res.stdout.includes(expected)) recordPass(id);
  else if (res.code !== 0) recordFail(id, res.stdout + res.stderr, 'command');
  else recordFail(id, res.stdout + res.stderr, 'assertion');
}

async function runCaseContainsAndDomContains(id, expected, args, domExpected, setup) {
  if (!selected(id)) return recordSkip(id);
  if (!await runSetup(id, setup)) return;
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  const domOut = path.join(artifactDir, `${id}-dom.out`);
  const domErr = path.join(artifactDir, `${id}-dom.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')} + dom postcondition`);
  const res = await runCommand(id, args, out, err);
  if (!res) return;
  if (res.code !== 0 || !res.stdout.includes(expected)) {
    recordFail(id, res.stdout + res.stderr, res.code === 0 ? 'assertion' : 'command');
    return;
  }
  const dom = await runCommand(id, ['dom', '--fresh'], domOut, domErr);
  if (!dom) return;
  if (dom.code === 0 && dom.stdout.includes(domExpected)) recordPass(id);
  else recordFail(id, `${res.stdout}${res.stderr}${dom.stdout}${dom.stderr}`, dom.code === 0 ? 'assertion' : 'command');
}

function isTransientDriverFailure(output) {
  return /driver TCP read failed|not connected|connection refused|read timeout/i.test(output);
}

async function runCaseContainsRetryTransient(id, expected, args, setup) {
  if (!selected(id)) return recordSkip(id);
  if (!await runSetup(id, setup)) return;
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')}`);
  let res = await runCommand(id, args, out, err);
  if (!res) return;
  let attempts = 1;
  if ((res.code !== 0 || !res.stdout.includes(expected)) && isTransientDriverFailure(`${res.stdout}\n${res.stderr}`)) {
    console.log(`[sim-test] ${id}: transient driver failure, rebuilding once before retry`);
    recordRecovery('case-retry', id, 'transient driver failure');
    runCliToFiles(['config', '--simulator', '--udid', sim.udid], path.join(artifactDir, `${id}-reconfig.out`), path.join(artifactDir, `${id}-reconfig.err`));
    await waitForDriver();
    attempts++;
    if (!await runSetup(id, setup)) return;
    res = await runCommand(id, args, out, err);
    if (!res) return;
  }
  if (res.code === 0 && res.stdout.includes(expected)) recordPass(id, { attempts });
  else if (res.code !== 0) recordFail(id, res.stdout + res.stderr, 'command', { attempts });
  else recordFail(id, res.stdout + res.stderr, 'assertion', { attempts });
}

async function runCaseMatches(id, expected, args, setup) {
  if (!selected(id)) return recordSkip(id);
  if (!await runSetup(id, setup)) return;
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')}`);
  const res = await runCommand(id, args, out, err);
  if (!res) return;
  if (res.code === 0 && expected.test(res.stdout)) recordPass(id);
  else if (res.code !== 0) recordFail(id, res.stdout + res.stderr, 'command');
  else recordFail(id, res.stdout + res.stderr, 'assertion');
}

async function runCaseFailsContains(id, expected, args, setup) {
  if (!selected(id)) return recordSkip(id);
  if (!await runSetup(id, setup)) return;
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')} (expect fail)`);
  const res = await runCommand(id, args, out, err);
  if (!res) return;
  const haystack = `${res.stdout}\n${res.stderr}`.toLowerCase();
  if (res.code !== 0 && haystack.includes(expected.toLowerCase())) recordPass(id);
  else if (res.code === 0) recordFail(id, res.stdout + res.stderr, 'assertion');
  else recordFail(id, res.stdout + res.stderr, 'assertion');
}

async function runCaseFailsMatches(id, expected, args, setup) {
  if (!selected(id)) return recordSkip(id);
  if (!await runSetup(id, setup)) return;
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')} (expect fail)`);
  const res = await runCommand(id, args, out, err);
  if (!res) return;
  if (res.code !== 0 && expected.test(`${res.stdout}\n${res.stderr}`)) recordPass(id);
  else recordFail(id, res.stdout + res.stderr, 'assertion');
}

async function runCaseFileExists(id, filePath, args, setup) {
  if (!selected(id)) return recordSkip(id);
  if (!await runSetup(id, setup)) return;
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')}`);
  const res = await runCommand(id, args, out, err);
  if (!res) return;
  if (res.code === 0 && fs.existsSync(filePath) && fs.statSync(filePath).size > 0) {
    fs.copyFileSync(filePath, path.join(artifactDir, path.basename(filePath)));
    recordPass(id);
  } else {
    recordFail(id, `${res.stdout}${res.stderr}[sim-test] missing file: ${filePath}\n`, res.code === 0 ? 'assertion' : 'command');
  }
}

async function runAutoLabelFindCase() {
  const id = 'FIND-12';
  if (!selected(id)) return recordSkip(id);
  await resetSettingsHome();
  const domOut = path.join(artifactDir, `${id}-dom.out`);
  const domErr = path.join(artifactDir, `${id}-dom.err`);
  const findOut = path.join(artifactDir, `${id}.out`);
  const findErr = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: dom auto label then find generated label`);
  const dom = runCliToFiles(['dom', '--fresh'], domOut, domErr);
  const match = dom.stdout.match(/^\s+([^\s]+Appc\d*) \[Collection(?:,[^\]]*)?\](?: \(\d+,\d+,\d+,\d+\))?:/m);
  if (dom.code !== 0 || !match) {
    return recordFail(id, dom.stdout + dom.stderr, dom.code === 0 ? 'assertion' : 'command');
  }
  const autoLabel = match[1];
  const found = runCliToFiles(['find', autoLabel, '--traits', 'Collection'], findOut, findErr);
  if (found.code === 0 && found.stdout.includes(autoLabel)) {
    recordPass(id);
  } else {
    recordFail(id, found.stdout + found.stderr, found.code === 0 ? 'assertion' : 'command');
  }
}

async function runDomPresentationCase() {
  const id = 'DOM-12';
  if (!selected(id)) return recordSkip(id);
  await resetSettingsHome();
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use dom presentation shape`);
  const res = runCliToFiles(['dom', '--fresh'], out, err);
  const output = res.stdout;
  const hasScrollableDirection = /^\s+\S+ \[(?:Scroll|Collection|Table),(?:vertical|horizontal)(?:,[^\]]*)?\] \(\d+,\d+,\d+,\d+\):/m.test(output);
  const hasLeafRect = /^\s+- .+ \[[^\]]+\] \(\d+,\d+,\d+,\d+\)$/m.test(output);
  const hasAppHeader = output.includes('App: com.apple.Preferences');
  if (res.code === 0 && hasAppHeader && hasScrollableDirection && hasLeafRect) {
    recordPass(id);
  } else {
    recordFail(id, `${res.stdout}${res.stderr}[sim-test] DOM-12 expected app header, scroll direction container rect, and leaf rect\n`, res.code === 0 ? 'assertion' : 'command');
  }
}

async function runDomNoWindowHeaderCase() {
  const id = 'DOM-6';
  if (!selected(id)) return recordSkip(id);
  await resetSettingsHome();
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use dom omits Window header`);
  const res = runCliToFiles(['dom', '--fresh'], out, err);
  if (res.code === 0 && res.stdout.includes('App: com.apple.Preferences') && !res.stdout.includes('Window:')) {
    recordPass(id);
  } else {
    recordFail(id, `${res.stdout}${res.stderr}[sim-test] DOM-6 expected App header without Window header\n`, res.code === 0 ? 'assertion' : 'command');
  }
}

async function runPostDomMutationCase() {
  const id = 'AS-9';
  if (!selected(id)) return recordSkip(id);
  await resetSettingsHome();
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use tap ... --dom 0`);
  const res = runCliToFiles(['tap', 'com.apple.settings.general', '--traits', 'Button', '--dom', '0'], out, err);
  const output = `${res.stdout}\n${res.stderr}`;
  if (res.code === 0 && output.includes('Tap') && output.includes('DOM after 0ms\nApp: com.apple.Preferences')) {
    recordPass(id);
  } else {
    recordFail(id, `${output}[sim-test] AS-9 expected tap output followed by post DOM\n`, res.code === 0 ? 'assertion' : 'command');
  }
}

async function runDomPayloadShapeCase() {
  const id = 'DOM-4';
  if (!selected(id)) return recordSkip(id);
  await resetSettingsHome();
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use dom payload/output shape`);
  const res = runCliToFiles(['dom', '--fresh'], out, err);
  const output = res.stdout;
  const hasAppHeader = output.includes('App: com.apple.Preferences');
  const hasNoWindowHeader = !/Window:\s*\d+x\d+/.test(output);
  const hasContainerRect = /^\s+\S+ \[[^\]]+\] \(\d+,\d+,\d+,\d+\):/m.test(output);
  const hasLeafRect = /^\s+- .+ \[[^\]]+\] \(\d+,\d+,\d+,\d+\)$/m.test(output);
  if (res.code === 0 && hasAppHeader && hasNoWindowHeader && hasContainerRect && hasLeafRect) {
    recordPass(id);
  } else {
    recordFail(id, `${res.stdout}${res.stderr}[sim-test] DOM-4 expected app header without Window header plus container and leaf rects\n`, res.code === 0 ? 'assertion' : 'command');
  }
}

async function runFindExactPreferredCase(id) {
  if (!selected(id)) return recordSkip(id);
  await resetSettingsHome();
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: find exact label should not return contains ambiguity`);
  const res = runCliToFiles(['find', 'General'], out, err);
  if (res.code === 0 && res.stdout.includes('Find "General":') && !/Find "General" \(\d+ matches\):/.test(res.stdout)) {
    recordPass(id);
  } else {
    recordFail(id, res.stdout + res.stderr, res.code === 0 ? 'assertion' : 'command');
  }
}

async function runConfigDriverVersionCase() {
  const id = 'CFG-7';
  if (!selected(id)) return recordSkip(id);
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: config writes driverVersion only`);
  const devices = runCliToFiles(['devices', '--simulator'], out, err);
  let entry;
  try {
    const config = JSON.parse(fs.readFileSync(path.join(iosHome, 'config.json'), 'utf8'));
    entry = config.devices?.[sim.udid];
  } catch (error) {
    return recordFail(id, `${devices.stdout}${devices.stderr}${error}\n`, devices.code === 0 ? 'assertion' : 'command');
  }
  if (
    devices.code === 0 &&
    !devices.stdout.includes('driver update required') &&
    typeof entry?.driverVersion === 'string' &&
    entry.driverVersion.length > 0 &&
    Object.keys(entry).sort().join(',') === 'bundleId,driverVersion'
  ) {
    recordPass(id);
  } else {
    recordFail(id, `${devices.stdout}${devices.stderr}${JSON.stringify(entry, null, 2)}\n`, devices.code === 0 ? 'assertion' : 'command');
  }
}

async function runStartCreatesDriverLockCase() {
  const id = 'START-1';
  if (!selected(id)) return recordSkip(id);
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  const domOut = path.join(artifactDir, `${id}-dom.out`);
  const domErr = path.join(artifactDir, `${id}-dom.err`);
  console.log(`[sim-test] RUN ${id}: ios-use start <sim>`);
  stopDriverIfLocked(id);
  const res = runCliToFiles(['start', sim.udid], out, err);
  let lock;
  try {
    lock = JSON.parse(readFileIfExists(path.join(iosHome, 'state/driver.lock')) || '{}');
  } catch (error) {
    return recordFail(id, `${res.stdout}${res.stderr}${error}\n`, res.code === 0 ? 'assertion' : 'command');
  }
  const dom = runCliToFiles(['dom', '--fresh'], domOut, domErr);
  if (
    res.code === 0 &&
    res.stdout.includes(`Driver started for ${sim.udid}`) &&
    lock.udid === sim.udid &&
    dom.code === 0 &&
    dom.stdout.includes('App:')
  ) {
    recordPass(id);
  } else {
    recordFail(id, `${res.stdout}${res.stderr}${readFileIfExists(path.join(iosHome, 'state/driver.lock'))}\n${dom.stdout}${dom.stderr}`, res.code === 0 && dom.code === 0 ? 'assertion' : 'command');
  }
}

async function runStopClearsDriverLockCase() {
  const id = 'STOP-1';
  if (!selected(id)) return recordSkip(id);
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use stop with active driver.lock`);
  ensureDriverStarted(`${id}-start`);
  const sessionPath = path.join(iosHome, 'state/session.json');
  writeFile(sessionPath, JSON.stringify({ legacy: true }));
  const stop = runCliToFiles(['stop'], out, err);
  const lockExists = fs.existsSync(path.join(iosHome, 'state/driver.lock'));
  const sessionExists = fs.existsSync(sessionPath);
  if (stop.code === 0 && !lockExists && sessionExists) {
    recordPass(id);
  } else {
    recordFail(id, `${stop.stdout}${stop.stderr}[sim-test] lockExists=${lockExists} sessionExists=${sessionExists}\n`, stop.code === 0 ? 'assertion' : 'command');
  }
}

async function runStopWithoutDriverLockCase() {
  const id = 'STOP-2';
  if (!selected(id)) return recordSkip(id);
  stopDriverIfLocked(id);
  await runCaseFailsContains(id, 'No active driver', ['stop']);
}

function backupStateFile(rel) {
  const src = path.join(iosHome, rel);
  const dst = path.join(stateBackupDir, rel);
  ensureDir(path.dirname(dst));
  if (fs.existsSync(src)) fs.copyFileSync(src, dst);
  else writeFile(`${dst}.missing`, '');
}

function restoreStateFile(rel) {
  const src = path.join(stateBackupDir, rel);
  const missing = `${src}.missing`;
  const dst = path.join(iosHome, rel);
  if (fs.existsSync(src)) {
    ensureDir(path.dirname(dst));
    fs.copyFileSync(src, dst);
  } else if (fs.existsSync(missing)) {
    fs.rmSync(dst, { force: true });
  }
}

function backupLocalState() {
  ensureDir(stateBackupDir);
  backupStateFile('config.json');
  backupStateFile('state/session.json');
  backupStateFile('state/driver.lock');
}

function restoreLocalState() {
  restoreStateFile('config.json');
  restoreStateFile('state/session.json');
  restoreStateFile('state/driver.lock');
}

async function waitForDriver() {
  const out = path.join(artifactDir, 'driver-warmup.out');
  const err = path.join(artifactDir, 'driver-warmup.err');
  console.log('[sim-test] Waiting for driver...');
  ensureDriverStarted('driver-warmup-start');
  const startedAt = performance.now();
  let attempt = 0;
  let reconfigured = false;
  let consecutiveUnreachable = 0;
  while (performance.now() - startedAt < driverReadyTimeoutMs) {
    attempt++;
    const res = runCliToFiles(['dom', '--fresh'], out, err);
    if (res.code === 0) {
      console.log('[sim-test] Driver ready');
      return;
    }
    const combined = res.stdout + res.stderr;
    if (!reconfigured && combined.includes('out of date')) {
      console.log('[sim-test] Driver version mismatch, reinstalling');
      recordRecovery('driver-reconfig', currentCaseId, 'driver version mismatch');
      runCliToFiles(['config', '--simulator', '--udid', sim.udid], path.join(artifactDir, 'driver-reconfig.out'), path.join(artifactDir, 'driver-reconfig.err'));
      ensureDriverStarted('driver-reconfig-start');
      reconfigured = true;
      await sleep(3000);
      continue;
    }
    if (combined.includes('did not become reachable')) {
      consecutiveUnreachable++;
      if (consecutiveUnreachable >= 6) {
        console.log('[sim-test] Driver port unreachable after 6 attempts, giving up');
        break;
      }
    } else {
      consecutiveUnreachable = 0;
    }
    if (attempt % 5 === 0) {
      recordRecovery('driver-relaunch', currentCaseId, `warmup attempt ${attempt}`);
      relaunchSimulatorDriver(attempt);
    }
    await sleep(2000);
  }
  collectDriverWarmupDiagnostics();
  throw new Error(`Driver did not become ready\n${readFileIfExists(out)}${readFileIfExists(err)}${readFileIfExists(path.join(artifactDir, 'driver-warmup-diagnostics.out'))}${readFileIfExists(path.join(artifactDir, 'driver-warmup-diagnostics.err'))}`);
}

function relaunchSimulatorDriver(attempt) {
  const res = execCmd(['xcrun', 'simctl', 'launch', sim.udid, simulatorDriverBundleId]);
  writeFile(path.join(artifactDir, `driver-warmup-relaunch-${attempt}.out`), res.stdout);
  writeFile(path.join(artifactDir, `driver-warmup-relaunch-${attempt}.err`), res.stderr);
}

function collectDriverWarmupDiagnostics() {
  const diagnostics = [
    ['xcrun', 'simctl', 'spawn', sim.udid, 'launchctl', 'print', `gui/501/${simulatorDriverBundleId}`],
    ['xcrun', 'simctl', 'spawn', sim.udid, 'log', 'show', '--style', 'compact', '--last', '3m', '--predicate', 'process CONTAINS "IOSUseDriver" OR eventMessage CONTAINS "[driver]" OR eventMessage CONTAINS "iosuse"'],
  ];
  const stdout = [];
  const stderr = [];
  for (const cmd of diagnostics) {
    const res = execCmd(cmd);
    stdout.push(`$ ${cmd.join(' ')}\n${res.stdout}`);
    stderr.push(`$ ${cmd.join(' ')}\n${res.stderr}`);
  }
  writeFile(path.join(artifactDir, 'driver-warmup-diagnostics.out'), stdout.join('\n'));
  writeFile(path.join(artifactDir, 'driver-warmup-diagnostics.err'), stderr.join('\n'));
}

let recoveryCount = 0;
let startCount = 0;

function stopDriverIfLocked(prefix) {
  if (!readDriverLockInfo()) return null;
  return runCliToFiles(
    ['stop'],
    path.join(artifactDir, `${prefix}-stop.out`),
    path.join(artifactDir, `${prefix}-stop.err`),
  );
}

function ensureDriverStarted(prefix = 'driver-start') {
  const lock = readDriverLockInfo();
  if (lock?.udid === sim.udid) return;
  if (lock) {
    const stopped = stopDriverIfLocked(prefix);
    if (stopped && stopped.code !== 0) {
      throw new Error(`failed to stop existing driver lock\n${stopped.stdout}${stopped.stderr}`);
    }
  }
  startCount++;
  const start = runCliToFiles(
    ['start', sim.udid],
    path.join(artifactDir, `${prefix}-${startCount}.out`),
    path.join(artifactDir, `${prefix}-${startCount}.err`),
  );
  if (start.code !== 0) {
    throw new Error(`failed to start simulator driver lock\n${start.stdout}${start.stderr}`);
  }
}

async function ensureDriverReady() {
  ensureDriverStarted('driver-ready-start');
  const probe = runCli(['dom', '--fresh']);
  if (probe.code === 0) return;
  recoveryCount++;
  console.log('[sim-test] Driver unavailable, reconfiguring simulator driver');
  recordRecovery('driver-recover', currentCaseId, 'dom probe failed');
  runCliToFiles(
    ['config', '--simulator', '--udid', sim.udid],
    path.join(artifactDir, `driver-recover-${recoveryCount}.out`),
    path.join(artifactDir, `driver-recover-${recoveryCount}.err`),
  );
  await waitForDriver();
}

async function prerequisiteConfig() {
  if (!caseFilterIds || selected('CFG-4')) return;
  console.log('[sim-test] Running prerequisite config');
  runCliToFiles(['config', '--simulator', '--udid', sim.udid], path.join(artifactDir, 'prereq-config.out'), path.join(artifactDir, 'prereq-config.err'));
  await waitForDriver();
}

async function resetSettingsHome() {
  await ensureDriverReady();
  runCli(['terminateApp', 'com.apple.Preferences']);
  runCli(['activateApp', 'com.apple.Preferences']);
  await sleep(1000);
}

async function openGeneralPage() {
  await resetSettingsHome();
  runCli(['tap', 'BackButton', '--traits', 'Button']);
  await sleep(500);
  const byId = runCli(['tap', 'com.apple.settings.general', '--traits', 'Button']);
  if (byId.code !== 0) runCli(['tap', 'General', '--traits', 'Button']);
  await sleep(1000);
  runCli(['swipe', '--distance', '900', '--dir', 'back']);
  runCli(['swipe', '--distance', '900', '--dir', 'back']);
}

async function openContactsNewContact() {
  await ensureDriverReady();
  runCli(['terminateApp', 'com.apple.MobileAddressBook']);
  runCli(['activateApp', 'com.apple.MobileAddressBook']);
  await sleep(1000);
  runCli(['dismissAlert']);

  const formVisible = () => runCli(['waitFor', '--label', 'Last name', '--traits', 'Input', '--timeout', '0.5']).code === 0;
  if (formVisible()) return;

  for (let i = 0; i < 3; i++) {
    const addVisible = runCli(['waitFor', '--label', 'Add', '--traits', 'Button', '--timeout', '1']);
    if (addVisible.code === 0) {
      const add = runCli(['tap', 'Add', '--traits', 'Button']);
      if (add.code !== 0) runCli(['tap', '340,800']);
    } else {
      runCli(['tap', '340,800']);
    }
    await sleep(1000);
    if (formVisible()) return;

    runCli(['tap', 'close', '--traits', 'Button']);
    await sleep(500);
    runCli(['dismissAlert']);
    if (formVisible()) return;
  }

  const finalWait = runCli(['waitFor', '--label', 'Last name', '--traits', 'Input', '--timeout', '3']);
  if (finalWait.code !== 0) {
    throw new Error(`failed to open Contacts New Contact form\n${finalWait.stdout}${finalWait.stderr}`);
  }
}

async function openSpringboardIconMenu(id) {
  await openHomeScreenWithSafariIcon();
  runCliToFiles(
    ['longpress', 'Safari', '--traits', 'Icon', '--duration', '900'],
    path.join(artifactDir, `${id}-icon-menu.out`),
    path.join(artifactDir, `${id}-icon-menu.err`),
  );
  await sleep(1000);
}

async function openHomeScreenWithSafariIcon() {
  await ensureDriverReady();
  for (let attempt = 0; attempt < 3; attempt++) {
    runCli(['home']);
    await sleep(1000 + attempt * 500);
    const visible = runCli(['waitFor', '--label', 'Safari', '--traits', 'Icon', '--timeout', '1']);
    if (visible.code === 0) return;
  }
}

async function verifyExampleDomainOpened(id) {
  for (let attempt = 0; attempt < 12; attempt++) {
    await sleep(1000);
    const dom = runCliToFiles(
      ['dom', '--fresh'],
      path.join(artifactDir, `${id}-verify-dom.out`),
      path.join(artifactDir, `${id}-verify-dom.err`),
    );
    if (
      dom.code === 0
      && dom.stdout.includes('App: com.apple.mobilesafari')
      && dom.stdout.includes('Example Domain')
    ) {
      return true;
    }
  }
  return false;
}

async function discardContactIfNeeded() {
  runCli(['tap', 'close', '--traits', 'Button']);
  await sleep(500);
  runCli(['dismissAlert']);
}

async function openContactsDiscardAlert() {
  await openContactsNewContact();
  runCli(['input', '--label', 'First name', '--content', 'AlertTest', '--traits', 'Input']);
  runCli(['tap', 'close', '--traits', 'Button']);
  await sleep(500);
}

async function runInputAndVerifyDom(
  id,
  label,
  content,
  expected,
  args,
  setup,
) {
  if (!selected(id)) return recordSkip(id);
  if (!await runSetup(id, setup)) return;
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  const domOut = path.join(artifactDir, `${id}-dom.out`);
  const domErr = path.join(artifactDir, `${id}-dom.err`);
  console.log(`[sim-test] RUN ${id}: ios-use input --label ${label} --content ${content} ${args.join(' ')}`);
  let attempts = 1;
  let res = runCliToFiles(['input', '--label', label, '--content', content, ...args], out, err);
  if (res.code !== 0 && /not connected|connection refused|read timeout/i.test(`${res.stdout}\n${res.stderr}`)) {
    console.log(`[sim-test] ${id}: driver connection lost, rebuilding once and rerunning setup before retry`);
    recordRecovery('case-retry', id, 'input driver connection lost');
    runCliToFiles(['config', '--simulator', '--udid', sim.udid], path.join(artifactDir, `${id}-reconfig.out`), path.join(artifactDir, `${id}-reconfig.err`));
    await waitForDriver();
    attempts++;
    if (!await runSetup(id, setup)) return;
    res = runCliToFiles(['input', '--label', label, '--content', content, ...args], out, err);
  }
  const dom = runCliToFiles(['dom', '--fresh'], domOut, domErr);
  if (res.stdout.includes('Input') && dom.code === 0 && dom.stdout.includes(expected)) recordPass(id, { attempts });
  else recordFail(id, `${readFileIfExists(out)}${readFileIfExists(err)}${readFileIfExists(domOut)}${readFileIfExists(domErr)}`, res.code === 0 ? 'assertion' : 'command', { attempts });
}

async function verifyContactsNameFields(id, suffix) {
  const out = path.join(artifactDir, `${id}${suffix}.out`);
  const err = path.join(artifactDir, `${id}${suffix}.err`);
  const domOut = path.join(artifactDir, `${id}${suffix}-dom.out`);
  const domErr = path.join(artifactDir, `${id}${suffix}-dom.err`);
  await openContactsNewContact();
  const first = runCli(['input', '--label', 'First name', '--content', 'Alpha', '--traits', 'Input']);
  const last = runCli(['input', '--label', 'Last name', '--content', 'Beta', '--traits', 'Input']);
  writeFile(out, first.stdout + last.stdout);
  writeFile(err, first.stderr + last.stderr);
  const dom = runCliToFiles(['dom', '--fresh'], domOut, domErr);
  return first.code === 0 && last.code === 0 && dom.code === 0 && dom.stdout.includes('First name=Alpha') && dom.stdout.includes('Last name=Beta');
}

async function unsupportedCase(id, reason) {
  if (!selected(id)) return recordSkip(id);
  const resolvedReason = reason ?? unsupportedCaseReasons.get(id);
  if (!resolvedReason) {
    recordFail(id, `unsupported case ${id} is missing a registry reason\n`, 'assertion');
    return;
  }
  recordUnsupported(id, resolvedReason);
}

function writeFlowFixtures() {
  flowDir = path.join(artifactDir, 'flows');
  ensureDir(flowDir);
  writeFile(path.join(flowDir, 'basic.yaml'), `name: simulator-basic-flow
app: com.apple.Preferences
vars:
  targetLabel: com.apple.settings.general
steps:
  - action: waitFor
    label: \${vars.targetLabel}
    traits: Button
    timeout: 3
  - action: find
    label: \${vars.targetLabel}
    traits: Button
    outputs: found
  - action: dom
    fresh: true
    candidates:
      - \${vars.targetLabel}
      - Search
    outputs: page
  - action: returnIf
    value: \${page.firstMatch}
    is: null
  - action: sleep
    ms: 10
  - action: dom
    fresh: true
`);
  writeFile(path.join(flowDir, 'child.yaml'), `name: simulator-child-flow
vars:
  targetLabel: com.apple.settings.general
outputs: found
steps:
  - action: waitFor
    label: \${vars.targetLabel}
    traits: Button
    timeout: 3
  - action: find
    label: \${vars.targetLabel}
    traits: Button
    outputs: found
`);
  writeFile(path.join(flowDir, 'parent.yaml'), `name: simulator-parent-flow
app: com.apple.Preferences
steps:
  - action: runFlow
    file: ./child.yaml
    vars:
      targetLabel: com.apple.settings.general
    outputs: found
  - action: find
    label: \${found.firstMatch.label}
    traits: Button
`);
  writeFile(path.join(flowDir, 'missing-output.yaml'), `name: simulator-missing-output-flow
app: com.apple.Preferences
steps:
  - action: runFlow
    file: ./child.yaml
    outputs: missingValue
`);
  writeFile(path.join(flowDir, 'cycle-a.yaml'), 'name: cycle-a\nsteps:\n  - action: runFlow\n    file: ./cycle-b.yaml\n');
  writeFile(path.join(flowDir, 'cycle-b.yaml'), 'name: cycle-b\nsteps:\n  - action: runFlow\n    file: ./cycle-a.yaml\n');
  writeFile(path.join(flowDir, 'return-null.yaml'), `name: simulator-return-null-flow
app: com.apple.Preferences
steps:
  - action: dom
    candidates:
      - __ios_use_missing_label__
    outputs: page
  - action: returnIf
    value: \${page.firstMatch}
    is: null
  - action: tap
    label: __must_not_run__
`);
  writeFile(path.join(flowDir, 'invalid-return.yaml'), 'name: simulator-invalid-return-flow\nsteps:\n  - action: returnIf\n    value: true\n    is: invalid\n');
  writeFile(path.join(flowDir, 'tap-offset.yaml'), 'name: simulator-tap-offset-flow\napp: com.apple.Preferences\nsteps:\n  - action: tap\n    label: com.apple.settings.general\n    traits: Button\n    offsetRatio: "0.5,"\n');
  writeFile(path.join(flowDir, 'tap-dom.yaml'), 'name: simulator-tap-dom-flow\napp: com.apple.Preferences\nsteps:\n  - action: tap\n    label: com.apple.settings.general\n    traits: Button\n    dom: 0\n');
  writeFile(path.join(flowDir, 'sleep-default.yaml'), 'name: simulator-sleep-default-flow\napp: com.apple.Preferences\nsteps:\n  - action: sleep\n  - action: dom\n    fresh: true\n');
  writeFile(path.join(flowDir, 'dom-save.yaml'), 'name: simulator-dom-save-flow\napp: com.apple.Preferences\nsteps:\n  - action: dom\n    save: true\n    name: simulator-dom-save\n');
  writeFile(path.join(flowDir, 'oslog-timeout.yaml'), 'name: simulator-oslog-timeout-flow\napp: com.apple.Preferences\nsteps:\n  - action: oslog\n    pattern: __ios_use_no_such_log_line__\n    timeout: 0.2\n    name: simulator-flow-oslog-timeout\n');
  writeFile(path.join(flowDir, 'standard-smoke.yaml'), 'name: simulator-standard-smoke-flow\napp: com.apple.Preferences\nsteps:\n  - action: waitFor\n    label: com.apple.settings.general\n    traits: Button\n    timeout: 5\n  - action: dom\n    outputs: smokeDom\n  - action: screenshot\n    name: simulator-flow-smoke-screenshot\n  - action: oslog\n    clear: true\n    bundleId: com.apple.Preferences\n  - action: swipe\n    distance: 300\n    dir: forth\n  - action: oslog\n    pattern: __ios_use_no_such_log_line__\n    timeout: 0.2\n    name: simulator-flow-smoke-oslog\n    bundleId: com.apple.Preferences\n  - action: activateApp\n    bundleId: com.apple.Preferences\n  - action: dom\n    raw: true\n    outputs: smokeRaw\n');
}

async function runDomPerfCase() {
  const id = 'DOM-7';
  if (!selected(id)) return recordSkip(id);
  await resetSettingsHome();
  const coldOut = path.join(artifactDir, `${id}-cold.out`);
  const coldErr = path.join(artifactDir, `${id}-cold.err`);
  const warmOut = path.join(artifactDir, `${id}-warm.out`);
  const warmErr = path.join(artifactDir, `${id}-warm.err`);
  console.log(`[sim-test] RUN ${id}: cold/warm dom stability`);
  const coldStart = performance.now();
  const cold = runCliToFiles(['dom', '--fresh'], coldOut, coldErr);
  const coldMs = Math.round(performance.now() - coldStart);
  const warmStart = performance.now();
  const warm = runCliToFiles(['dom'], warmOut, warmErr);
  const warmMs = Math.round(performance.now() - warmStart);
  if (cold.code === 0 && warm.code === 0 && cold.stdout.includes('App:') && warm.stdout.includes('App:') && coldMs < 20000 && warmMs < 10000) {
    writeFile(path.join(artifactDir, `${id}.json`), JSON.stringify({ coldMs, warmMs }));
    recordPass(id);
  } else {
    recordFail(id, `[sim-test] DOM perf outside guardrail: cold=${coldMs}ms warm=${warmMs}ms\n`, cold.code === 0 && warm.code === 0 ? 'assertion' : 'command');
  }
}

async function runProxyDoctorCase() {
  const id = 'PROXY-1';
  if (!selected(id)) return recordSkip(id);
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use proxy doctor`);
  const res = await runCommand(id, ['proxy', 'doctor'], out, err);
  if (!res) return;
  if (res.code === 0 && res.stdout.includes('Wi-Fi LAN IP') && res.stdout.includes('Proxy: not running') && !/SSID/i.test(`${res.stdout}\n${res.stderr}`)) recordPass(id);
  else recordFail(id, res.stdout + res.stderr, res.code === 0 ? 'assertion' : 'command');
}

async function runSwiftBridgeCase(id) {
  if (!selected(id)) return recordSkip(id);
  const bridge = bridgeCase(id);
  if (id === 'PROXY-4') {
    const precheckHits = findProxyPrecheckReferences();
    writeFile(path.join(artifactDir, 'PROXY-4-no-precheck.json'), JSON.stringify({ forbiddenReferences: precheckHits }, null, 2));
    if (precheckHits.length > 0) {
      recordFail(id, `proxy precheck references remain:\n${precheckHits.join('\n')}\n`, 'assertion');
      return;
    }
  }
  recordBridged(id, bridge.source, bridge.reason);
}

async function runProxyReadMissingCaptureCase() {
  await runCaseFailsContains('PROXY-7', 'ios-use proxy start', ['proxy', 'read']);
}

async function runProxyReadDoctorNoLockCase() {
  const id = 'AS-8';
  if (!selected(id)) return recordSkip(id);
  console.log(`[sim-test] RUN ${id}: proxy read/doctor without active driver.lock`);
  const stop = stopDriverIfLocked(`${id}-stop-before`) ?? { code: 0, stdout: '', stderr: '' };
  fs.rmSync(path.join(iosHome, 'state/proxy-session.json'), { force: true });
  const doctor = runCliToFiles(['proxy', 'doctor'], path.join(artifactDir, `${id}-doctor.out`), path.join(artifactDir, `${id}-doctor.err`));
  const read = runCliToFiles(['proxy', 'read'], path.join(artifactDir, `${id}-read.out`), path.join(artifactDir, `${id}-read.err`));
  const readText = `${read.stdout}\n${read.stderr}`;
  const ok = stop.code === 0
    && doctor.code === 0
    && doctor.stdout.includes('Proxy:')
    && read.code !== 0
    && readText.includes('ios-use proxy start')
    && !readText.includes('No active driver');
  ensureDriverStarted(`${id}-restore`);
  if (ok) recordPass(id);
  else recordFail(id, stop.stdout + stop.stderr + doctor.stdout + doctor.stderr + read.stdout + read.stderr, 'assertion');
}

async function runDriverBridgeCase(id) {
  if (!selected(id)) return recordSkip(id);
  const bridge = bridgeCase(id);
  recordBridged(id, bridge.source, bridge.reason);
}

function buildCaseContext() {
  const settingsHome = async () => { await resetSettingsHome(); };
  const generalPage = async () => { await openGeneralPage(); };
  return {
    artifactDir,
    caseFilterIds,
    discardContactIfNeeded,
    emptyHomeName,
    ensureDriverReady,
    ensureDriverStarted,
    findProxyPrecheckReferences,
    flowDir,
    fs,
    generalPage,
    iosHome,
    iosUseCli,
    openContactsDiscardAlert,
    openContactsNewContact,
    openGeneralPage,
    openHomeScreenWithSafariIcon,
    openSpringboardIconMenu,
    path,
    readDriverLockInfo,
    readFileIfExists,
    recordFail,
    recordPass,
    recordRecovery,
    recordSkip,
    resetSettingsHome,
    rootDir,
    runAutoLabelFindCase,
    runCase,
    runCaseContains,
    runCaseContainsAndDomContains,
    runCaseContainsRetryTransient,
    runCaseFailsContains,
    runCaseFailsMatches,
    runCaseFileExists,
    runCaseMatches,
    runCli,
    runCliToFiles,
    runCommand,
    runConfigDriverVersionCase,
    runDomNoWindowHeaderCase,
    runDomPayloadShapeCase,
    runDomPerfCase,
    runDomPresentationCase,
    runDriverBridgeCase,
    runExternalToFiles,
    runFindExactPreferredCase,
    runInputAndVerifyDom,
    runProxyDoctorCase,
    runProxyReadDoctorNoLockCase,
    runProxyReadMissingCaptureCase,
    runPostDomMutationCase,
    runStartCreatesDriverLockCase,
    runStopClearsDriverLockCase,
    runStopWithoutDriverLockCase,
    runSwiftBridgeCase,
    selected,
    settingsHome,
    sim,
    sleep,
    stopDriverIfLocked,
    unsupportedCase,
    verifyContactsNameFields,
    verifyExampleDomainOpened,
    waitForDriver,
    writeFile,
  };
}

function buildCases() {
  const ctx = buildCaseContext();
  return [
    ...buildDeviceConfigCases(ctx),
    ...buildSettingsBeforeContactsCases(ctx),
    ...buildContactsCases(ctx),
    ...buildSettingsAfterContactsCases(ctx),
    ...buildFlowCases(ctx),
    ...buildHostBridgeCases(ctx),
  ];
}
async function cleanup() {
  runCli(['stop']);
  const cliLog = path.join(iosHome, 'logs/cli.log');
  if (fs.existsSync(cliLog)) fs.copyFileSync(cliLog, path.join(artifactDir, 'cli.log'));
  restoreLocalState();
  releaseRunLock();
}

async function main() {
  const parsedArgs = parseRunnerArgs(process.argv.slice(2));
  skipBuild = parsedArgs.skipBuild;
  caseFilterIds = parsedArgs.caseFilterIds;
  driverIpaPath = parsedArgs.driverIpaPath;

  if (!skipBuild) {
    const swiftCliBuild = execCmd(['bash', path.join(rootDir, 'scripts/build_swift_cli.sh')], { cwd: rootDir });
    process.stdout.write(swiftCliBuild.stdout);
    process.stderr.write(swiftCliBuild.stderr);
    if (swiftCliBuild.code !== 0) process.exit(swiftCliBuild.code);
  }

  console.log('[sim-test] Resolving IOSUseTest Simulator...');
  const simRes = execCmd(['node', path.join(rootDir, 'scripts/ios_use_test_simulator.js')], { env: { IOS_USE_HOME: testIosUseHome } });
  if (simRes.code !== 0) throw new Error(simRes.stderr || simRes.stdout);
  sim = JSON.parse(simRes.stdout);
  iosHome = sim.iosUseHome;
  acquireRunLock();
  artifactDir = path.join(iosHome, 'artifacts/simulator-command-tests', stamp());
  stateBackupDir = path.join(artifactDir, 'local-state-backup');
  ensureDir(artifactDir);
  ensureDir(path.join(artifactDir, emptyHomeName));
  writeRecoveryEvents();

  console.log(`[sim-test] IOS_USE_HOME: ${iosHome}`);
  console.log(`[sim-test] Simulator: ${sim.name} | ${sim.runtime} | ${sim.state} | UDID: ${sim.udid}`);
  const driverArtifact = prepareSimulatorDriverAsset(driverIpaPath);
  console.log(`[sim-test] CLI: ${iosUseCli}`);
  console.log(`[sim-test] driver-sim IPA source: ${driverArtifact.sourcePath}`);
  console.log(`[sim-test] driver-sim IPA installed: ${driverArtifact.installedPath}`);
  console.log(`[sim-test] Artifacts: ${artifactDir}`);

  backupLocalState();
  writeFlowFixtures();
  let cleanupDone = false;
  const safeCleanup = async () => {
    if (cleanupDone) return;
    cleanupDone = true;
    await cleanup();
  };
  process.on('SIGINT', () => { void safeCleanup().finally(() => process.exit(130)); });
  process.on('SIGTERM', () => { void safeCleanup().finally(() => process.exit(143)); });

  try {
    validateCaseMetadataSchema();
    const cases = buildCases();
    const caseIds = cases.map(testCase => testCase.id);
    validateCaseRegistry(caseIds);
    validateCaseFilter(simulatorCaseIds, caseFilterIds);
    if (shouldRunPrerequisiteConfig({ caseFilterIds })) {
      await prerequisiteConfig();
    }
    for (const testCase of cases) {
      currentCaseId = testCase.id;
      currentPhase = 'case';
      caseStartTimes.set(testCase.id, performance.now());
      try {
        await testCase.run();
      } catch (error) {
        recordFail(testCase.id, `${error instanceof Error ? error.stack || error.message : String(error)}\n`, currentPhase || 'case');
      } finally {
        currentCaseId = '';
        currentPhase = 'case';
      }
    }

    const summary = {
      iosUseHome: iosHome,
      simulator: sim.name,
      simulatorUdid: sim.udid,
      runtime: sim.runtime,
      passed,
      failed,
      skipped,
      bridged,
      unsupported,
      recoveryEvents: recoveryEvents.length,
      artifacts: artifactDir,
    };
    writeFile(path.join(artifactDir, 'summary.json'), `${JSON.stringify(summary, null, 2)}\n`);
    console.log(JSON.stringify(summary, null, 2));
  } finally {
    await safeCleanup();
  }

  if (failed !== 0) process.exit(1);
}

if (import.meta.main) {
  main().catch(async error => {
    console.error(error instanceof Error ? error.message : String(error));
    if (artifactDir) await cleanup();
    else releaseRunLock();
    process.exit(1);
  });
}
