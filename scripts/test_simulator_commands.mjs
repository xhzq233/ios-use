#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const decoder = new TextDecoder();
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');
let skipBuild = false;
let caseFilterIds;
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
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--skip-build') {
      parsedSkipBuild = true;
    } else if (arg === '--case') {
      const value = argv[++i];
      if (!value) throw new Error('--case requires a value');
      parsedCaseFilterIds = parseCaseFilter(value);
    } else {
      throw new Error(`unknown option ${arg}`);
    }
  }
  return { skipBuild: parsedSkipBuild, caseFilterIds: parsedCaseFilterIds };
}

export function validateCaseFilter(caseIds, filterIds) {
  if (!filterIds) return;
  const available = new Set([...caseIds].map(id => id.toUpperCase()));
  const unknown = [...filterIds].filter(id => !available.has(id));
  if (unknown.length > 0) {
    throw new Error(`unknown --case id: ${unknown.join(', ')}`);
  }
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
    'swift-cli/Sources/IOSUseCLI/ProxyService.swift',
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

function prepareSimulatorDriverAsset() {
  const src = path.join(rootDir, 'assets/driver-sim.ipa');
  const dst = path.join(iosHome, 'driver-sim.ipa');
  if (!fs.existsSync(src)) {
    throw new Error(`prebuilt Simulator driver IPA not found: ${src}`);
  }
  ensureDir(path.dirname(dst));
  fs.copyFileSync(src, dst);
}

function execCmd(cmd, opts = {}) {
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

async function sleep(ms) {
  await new Promise(resolve => setTimeout(resolve, ms));
}

function runCli(args) {
  return execCmd([iosUseCli, ...args], { env: { IOS_USE_HOME: iosHome } });
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

function anySelected(ids) {
  return ids.some(id => selected(id));
}

function recordPass(id) {
  passed++;
  console.log(`[sim-test] PASS ${id}`);
}

function recordFail(id, details) {
  failed++;
  console.log(`[sim-test] FAIL ${id}`);
  if (details) process.stderr.write(details);
}

function recordSkip(id) {
  skipped++;
  if (caseFilterIds) return;
  console.log(`[sim-test] SKIP ${id}`);
}

async function runCase(id, args, setup) {
  if (!selected(id)) return recordSkip(id);
  await setup?.();
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')}`);
  const res = runCliToFiles(args, out, err);
  if (res.code === 0) recordPass(id);
  else recordFail(id, res.stderr || res.stdout);
}

async function runCaseContains(id, expected, args, setup) {
  if (!selected(id)) return recordSkip(id);
  await setup?.();
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')}`);
  const res = runCliToFiles(args, out, err);
  if (res.code === 0 && res.stdout.includes(expected)) recordPass(id);
  else recordFail(id, res.stdout + res.stderr);
}

function isTransientDriverFailure(output) {
  return /driver TCP read failed|not connected|connection refused|read timeout/i.test(output);
}

async function runCaseContainsRetryTransient(id, expected, args, setup) {
  if (!selected(id)) return recordSkip(id);
  await setup?.();
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')}`);
  let res = runCliToFiles(args, out, err);
  if ((res.code !== 0 || !res.stdout.includes(expected)) && isTransientDriverFailure(`${res.stdout}\n${res.stderr}`)) {
    console.log(`[sim-test] ${id}: transient driver failure, rebuilding once before retry`);
    runCliToFiles(['config', '--simulator', '--udid', sim.udid], path.join(artifactDir, `${id}-reconfig.out`), path.join(artifactDir, `${id}-reconfig.err`));
    await waitForDriver();
    await setup?.();
    res = runCliToFiles(args, out, err);
  }
  if (res.code === 0 && res.stdout.includes(expected)) recordPass(id);
  else recordFail(id, res.stdout + res.stderr);
}

async function runCaseMatches(id, expected, args, setup) {
  if (!selected(id)) return recordSkip(id);
  await setup?.();
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')}`);
  const res = runCliToFiles(args, out, err);
  if (res.code === 0 && expected.test(res.stdout)) recordPass(id);
  else recordFail(id, res.stdout + res.stderr);
}

async function runCaseFailsContains(id, expected, args, setup) {
  if (!selected(id)) return recordSkip(id);
  await setup?.();
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')} (expect fail)`);
  const res = runCliToFiles(args, out, err);
  const haystack = `${res.stdout}\n${res.stderr}`.toLowerCase();
  if (res.code !== 0 && haystack.includes(expected.toLowerCase())) recordPass(id);
  else recordFail(id, res.stdout + res.stderr);
}

async function runCaseFailsMatches(id, expected, args, setup) {
  if (!selected(id)) return recordSkip(id);
  await setup?.();
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')} (expect fail)`);
  const res = runCliToFiles(args, out, err);
  if (res.code !== 0 && expected.test(`${res.stdout}\n${res.stderr}`)) recordPass(id);
  else recordFail(id, res.stdout + res.stderr);
}

async function runCaseFileExists(id, filePath, args, setup) {
  if (!selected(id)) return recordSkip(id);
  await setup?.();
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use ${args.join(' ')}`);
  const res = runCliToFiles(args, out, err);
  if (res.code === 0 && fs.existsSync(filePath) && fs.statSync(filePath).size > 0) {
    fs.copyFileSync(filePath, path.join(artifactDir, path.basename(filePath)));
    recordPass(id);
  } else {
    recordFail(id, `${res.stdout}${res.stderr}[sim-test] missing file: ${filePath}\n`);
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
  const dom = runCliToFiles(['dom', '--fresh', '--udid', sim.udid], domOut, domErr);
  const match = dom.stdout.match(/^\s+([^\s]+Applicationc\d*) \[CollectionView\]:/m);
  if (dom.code !== 0 || !match) {
    return recordFail(id, dom.stdout + dom.stderr);
  }
  const autoLabel = match[1];
  const found = runCliToFiles(['find', autoLabel, '--traits', 'CollectionView', '--udid', sim.udid], findOut, findErr);
  if (found.code === 0 && found.stdout.includes(autoLabel)) {
    recordPass(id);
  } else {
    recordFail(id, found.stdout + found.stderr);
  }
}

async function runFindExactPreferredCase(id) {
  if (!selected(id)) return recordSkip(id);
  await resetSettingsHome();
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: find exact label should not return contains ambiguity`);
  const res = runCliToFiles(['find', 'General', '--udid', sim.udid], out, err);
  if (res.code === 0 && res.stdout.includes('Find "General":') && !/Find "General" \(\d+ matches\):/.test(res.stdout)) {
    recordPass(id);
  } else {
    recordFail(id, res.stdout + res.stderr);
  }
}

async function runConfigDriverIdentityCase() {
  const id = 'CFG-7';
  if (!selected(id)) return recordSkip(id);
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: config writes driver identity`);
  const devices = runCliToFiles(['devices', '--simulator'], out, err);
  let entry;
  try {
    const config = JSON.parse(fs.readFileSync(path.join(iosHome, 'config.json'), 'utf8'));
    entry = config.devices?.[sim.udid];
  } catch (error) {
    return recordFail(id, `${devices.stdout}${devices.stderr}${error}\n`);
  }
  const identity = entry?.driverIdentity;
  if (
    devices.code === 0 &&
    !devices.stdout.includes('driver update required') &&
    entry?.driverVersion === identity?.version &&
    typeof identity?.version === 'string' &&
    typeof identity?.build === 'string' &&
    /^\d{14}-[0-9a-fA-F]{12}$/.test(identity.build)
  ) {
    recordPass(id);
  } else {
    recordFail(id, `${devices.stdout}${devices.stderr}${JSON.stringify(entry, null, 2)}\n`);
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
  const res = runCliToFiles(['start', sim.udid], out, err);
  let lock;
  try {
    lock = JSON.parse(readFileIfExists(path.join(iosHome, 'state/driver.lock')) || '{}');
  } catch (error) {
    return recordFail(id, `${res.stdout}${res.stderr}${error}\n`);
  }
  const dom = runCliToFiles(['dom', '--fresh', '--udid', sim.udid], domOut, domErr);
  if (
    res.code === 0 &&
    res.stdout.includes(`Driver started for ${sim.udid}`) &&
    lock.udid === sim.udid &&
    dom.code === 0 &&
    dom.stdout.includes('App:')
  ) {
    recordPass(id);
  } else {
    recordFail(id, `${res.stdout}${res.stderr}${readFileIfExists(path.join(iosHome, 'state/driver.lock'))}\n${dom.stdout}${dom.stderr}`);
  }
}

async function runStopClearsDriverLockCase() {
  const id = 'STOP-3';
  if (!selected(id)) return recordSkip(id);
  const startOut = path.join(artifactDir, `${id}-start.out`);
  const startErr = path.join(artifactDir, `${id}-start.err`);
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use start <sim> && ios-use stop`);
  const start = runCliToFiles(['start', sim.udid], startOut, startErr);
  const stop = runCliToFiles(['stop'], out, err);
  const lockExists = fs.existsSync(path.join(iosHome, 'state/driver.lock'));
  const sessionExists = fs.existsSync(path.join(iosHome, 'state/session.json'));
  if (start.code === 0 && stop.code === 0 && !lockExists && !sessionExists) {
    recordPass(id);
  } else {
    recordFail(id, `${start.stdout}${start.stderr}${stop.stdout}${stop.stderr}[sim-test] lockExists=${lockExists} sessionExists=${sessionExists}\n`);
  }
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
  const startedAt = performance.now();
  let attempt = 0;
  while (performance.now() - startedAt < driverReadyTimeoutMs) {
    attempt++;
    const res = runCliToFiles(['dom', '--fresh', '--udid', sim.udid], out, err);
    if (res.code === 0) {
      console.log('[sim-test] Driver ready');
      return;
    }
    if (attempt % 5 === 0) {
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

async function ensureDriverReady() {
  const probe = runCli(['dom', '--fresh', '--udid', sim.udid]);
  if (probe.code === 0) return;
  recoveryCount++;
  console.log('[sim-test] Driver unavailable, reconfiguring simulator driver');
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
  runCli(['terminateApp', 'com.apple.Preferences', '--udid', sim.udid]);
  runCli(['activateApp', 'com.apple.Preferences', '--udid', sim.udid]);
  await sleep(1000);
}

async function openGeneralPage() {
  await resetSettingsHome();
  runCli(['tap', 'BackButton', '--traits', 'Button', '--udid', sim.udid]);
  await sleep(500);
  const byId = runCli(['tap', 'com.apple.settings.general', '--traits', 'Button', '--udid', sim.udid]);
  if (byId.code !== 0) runCli(['tap', 'General', '--traits', 'Button', '--udid', sim.udid]);
  await sleep(1000);
  runCli(['swipe', '--distance', '900', '--dir', 'back', '--udid', sim.udid]);
  runCli(['swipe', '--distance', '900', '--dir', 'back', '--udid', sim.udid]);
}

async function openContactsNewContact() {
  await ensureDriverReady();
  runCli(['terminateApp', 'com.apple.MobileAddressBook', '--udid', sim.udid]);
  runCli(['activateApp', 'com.apple.MobileAddressBook', '--udid', sim.udid]);
  await sleep(1000);
  runCli(['dismissAlert', '--udid', sim.udid]);

  const formVisible = () => runCli(['waitFor', '--label', 'Last name', '--traits', 'TextField', '--timeout', '0.5', '--udid', sim.udid]).code === 0;
  if (formVisible()) return;

  for (let i = 0; i < 3; i++) {
    const addVisible = runCli(['waitFor', '--label', 'Add', '--traits', 'Button', '--timeout', '1', '--udid', sim.udid]);
    if (addVisible.code === 0) {
      const add = runCli(['tap', 'Add', '--traits', 'Button', '--udid', sim.udid]);
      if (add.code !== 0) runCli(['tap', '340,800', '--udid', sim.udid]);
    } else {
      runCli(['tap', '340,800', '--udid', sim.udid]);
    }
    await sleep(1000);
    if (formVisible()) return;

    runCli(['tap', 'close', '--traits', 'Button', '--udid', sim.udid]);
    await sleep(500);
    runCli(['dismissAlert', '--udid', sim.udid]);
    if (formVisible()) return;
  }

  const finalWait = runCli(['waitFor', '--label', 'Last name', '--traits', 'TextField', '--timeout', '3', '--udid', sim.udid]);
  if (finalWait.code !== 0) {
    throw new Error(`failed to open Contacts New Contact form\n${finalWait.stdout}${finalWait.stderr}`);
  }
}

async function openSpringboardIconMenu(id) {
  await openHomeScreenWithSafariIcon();
  runCliToFiles(
    ['longpress', 'Safari', '--traits', 'Icon', '--duration', '900', '--udid', sim.udid],
    path.join(artifactDir, `${id}-icon-menu.out`),
    path.join(artifactDir, `${id}-icon-menu.err`),
  );
  await sleep(1000);
}

async function openHomeScreenWithSafariIcon() {
  await ensureDriverReady();
  for (let attempt = 0; attempt < 3; attempt++) {
    runCli(['home', '--udid', sim.udid]);
    await sleep(1000 + attempt * 500);
    const visible = runCli(['waitFor', '--label', 'Safari', '--traits', 'Icon', '--timeout', '1', '--udid', sim.udid]);
    if (visible.code === 0) return;
  }
}

async function discardContactIfNeeded() {
  runCli(['tap', 'close', '--traits', 'Button', '--udid', sim.udid]);
  await sleep(500);
  runCli(['dismissAlert', '--udid', sim.udid]);
}

async function openContactsDiscardAlert() {
  await openContactsNewContact();
  runCli(['input', '--label', 'First name', '--content', 'AlertTest', '--traits', 'TextField', '--udid', sim.udid]);
  runCli(['tap', 'close', '--traits', 'Button', '--udid', sim.udid]);
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
  await setup?.();
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  const domOut = path.join(artifactDir, `${id}-dom.out`);
  const domErr = path.join(artifactDir, `${id}-dom.err`);
  console.log(`[sim-test] RUN ${id}: ios-use input --label ${label} --content ${content} ${args.join(' ')}`);
  let res = runCliToFiles(['input', '--label', label, '--content', content, ...args], out, err);
  if (res.code !== 0 && /not connected|connection refused|read timeout/i.test(`${res.stdout}\n${res.stderr}`)) {
    console.log(`[sim-test] ${id}: driver connection lost, rebuilding once and rerunning setup before retry`);
    runCliToFiles(['config', '--simulator', '--udid', sim.udid], path.join(artifactDir, `${id}-reconfig.out`), path.join(artifactDir, `${id}-reconfig.err`));
    await waitForDriver();
    await setup?.();
    res = runCliToFiles(['input', '--label', label, '--content', content, ...args], out, err);
  }
  const dom = runCliToFiles(['dom', '--fresh', '--udid', sim.udid], domOut, domErr);
  if (res.stdout.includes('Input') && dom.code === 0 && dom.stdout.includes(expected)) recordPass(id);
  else recordFail(id, `${readFileIfExists(out)}${readFileIfExists(err)}${readFileIfExists(domOut)}${readFileIfExists(domErr)}`);
}

async function verifyContactsNameFields(id, suffix) {
  const out = path.join(artifactDir, `${id}${suffix}.out`);
  const err = path.join(artifactDir, `${id}${suffix}.err`);
  const domOut = path.join(artifactDir, `${id}${suffix}-dom.out`);
  const domErr = path.join(artifactDir, `${id}${suffix}-dom.err`);
  await openContactsNewContact();
  const first = runCli(['input', '--label', 'First name', '--content', 'Alpha', '--traits', 'TextField', '--udid', sim.udid]);
  const last = runCli(['input', '--label', 'Last name', '--content', 'Beta', '--traits', 'TextField', '--udid', sim.udid]);
  writeFile(out, first.stdout + last.stdout);
  writeFile(err, first.stderr + last.stderr);
  const dom = runCliToFiles(['dom', '--fresh', '--udid', sim.udid], domOut, domErr);
  return first.code === 0 && last.code === 0 && dom.code === 0 && dom.stdout.includes('First name=Alpha') && dom.stdout.includes('Last name=Beta');
}

async function unsupportedCase(id, reason) {
  if (!selected(id)) return recordSkip(id);
  skipped++;
  console.log(`[sim-test] SKIP ${id}: ${reason}`);
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
    print: false
    outputs: found
  - action: dom
    fresh: true
    candidates:
      - \${vars.targetLabel}
      - Search
    print: false
    outputs: page
  - action: returnIf
    value: \${page.firstMatch}
    is: null
  - action: sleep
    ms: 10
  - action: dom
    fresh: true
    print: false
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
    print: false
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
    print: false
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
    print: false
    outputs: page
  - action: returnIf
    value: \${page.firstMatch}
    is: null
  - action: tap
    label: __must_not_run__
`);
  writeFile(path.join(flowDir, 'invalid-return.yaml'), 'name: simulator-invalid-return-flow\nsteps:\n  - action: returnIf\n    value: true\n    is: invalid\n');
  writeFile(path.join(flowDir, 'tap-offset.yaml'), 'name: simulator-tap-offset-flow\napp: com.apple.Preferences\nsteps:\n  - action: tap\n    label: com.apple.settings.general\n    traits: Button\n    offset:\n      xRatio: 0.5\n');
  writeFile(path.join(flowDir, 'sleep-default.yaml'), 'name: simulator-sleep-default-flow\napp: com.apple.Preferences\nsteps:\n  - action: sleep\n  - action: dom\n    fresh: true\n    print: false\n');
  writeFile(path.join(flowDir, 'dom-save.yaml'), 'name: simulator-dom-save-flow\napp: com.apple.Preferences\nsteps:\n  - action: dom\n    save: true\n    name: simulator-dom-save\n    print: false\n  - action: dom\n    raw: true\n    save: true\n    name: simulator-dom-raw-save\n    print: false\n');
  writeFile(path.join(flowDir, 'oslog-timeout.yaml'), 'name: simulator-oslog-timeout-flow\napp: com.apple.Preferences\nsteps:\n  - action: oslog\n    pattern: __ios_use_no_such_log_line__\n    timeout: 0.2\n    name: simulator-flow-oslog-timeout\n');
  writeFile(path.join(flowDir, 'standard-smoke.yaml'), 'name: simulator-standard-smoke-flow\napp: com.apple.Preferences\nsteps:\n  - action: waitFor\n    label: com.apple.settings.general\n    traits: Button\n    timeout: 5\n  - action: dom\n    save: true\n    name: simulator-flow-smoke-dom\n    print: false\n  - action: screenshot\n    name: simulator-flow-smoke-screenshot\n  - action: oslog\n    clear: true\n    bundleId: com.apple.Preferences\n  - action: swipe\n    distance: 300\n    dir: forth\n  - action: oslog\n    pattern: __ios_use_no_such_log_line__\n    timeout: 0.2\n    name: simulator-flow-smoke-oslog\n    bundleId: com.apple.Preferences\n  - action: activateApp\n    bundleId: com.apple.Preferences\n  - action: dom\n    raw: true\n    save: true\n    name: simulator-flow-smoke-raw\n    print: false\n');
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
  const cold = runCliToFiles(['dom', '--fresh', '--udid', sim.udid], coldOut, coldErr);
  const coldMs = Math.round(performance.now() - coldStart);
  const warmStart = performance.now();
  const warm = runCliToFiles(['dom', '--udid', sim.udid], warmOut, warmErr);
  const warmMs = Math.round(performance.now() - warmStart);
  if (cold.code === 0 && warm.code === 0 && cold.stdout.includes('App:') && warm.stdout.includes('App:') && coldMs < 20000 && warmMs < 10000) {
    writeFile(path.join(artifactDir, `${id}.json`), JSON.stringify({ coldMs, warmMs }));
    recordPass(id);
  } else {
    recordFail(id, `[sim-test] DOM perf outside guardrail: cold=${coldMs}ms warm=${warmMs}ms\n`);
  }
}

async function runProxyDoctorCase() {
  const id = 'PROXY-1';
  if (!selected(id)) return recordSkip(id);
  const out = path.join(artifactDir, `${id}.out`);
  const err = path.join(artifactDir, `${id}.err`);
  console.log(`[sim-test] RUN ${id}: ios-use proxy doctor`);
  const res = runCliToFiles(['proxy', 'doctor'], out, err);
  if (res.code === 0 && res.stdout.includes('Wi-Fi LAN IP') && res.stdout.includes('Proxy: not running') && !/SSID/i.test(`${res.stdout}\n${res.stderr}`)) recordPass(id);
  else recordFail(id, res.stdout + res.stderr);
}

async function runSwiftCLIUnitCases() {
  const ids = ['PROXY-2', 'PROXY-3', 'PROXY-4', 'PROXY-5', 'PROXY-5B', 'PROXY-6', 'FLOW-24', 'FLOW-25', 'FLOW-26'];
  if (!anySelected(ids)) {
    ids.forEach(recordSkip);
    return;
  }
  console.log('[sim-test] RUN Swift CLI unit coverage: bash scripts/test_swift_cli.sh');
  const res = runExternalToFiles(['bash', 'scripts/test_swift_cli.sh'], path.join(artifactDir, 'swift-cli-unit.out'), path.join(artifactDir, 'swift-cli-unit.err'), { IOS_USE_HOME: iosHome });
  const precheckHits = selected('PROXY-4') ? findProxyPrecheckReferences() : [];
  if (selected('PROXY-4')) {
    writeFile(path.join(artifactDir, 'PROXY-4-no-precheck.json'), JSON.stringify({ forbiddenReferences: precheckHits }, null, 2));
  }
  for (const id of ids) {
    if (!selected(id)) recordSkip(id);
    else if (res.code !== 0) recordFail(id, res.stdout + res.stderr);
    else if (id === 'PROXY-4' && precheckHits.length > 0) recordFail(id, `proxy precheck references remain:\n${precheckHits.join('\n')}\n`);
    else recordPass(id);
  }
}

async function runProxyReadMissingCaptureCase() {
  await runCaseFailsContains('PROXY-7', 'ios-use proxy start', ['proxy', 'read']);
}

async function runDriverUnitCases() {
  const ids = ['DOM-9', 'FIND-5A', 'FIND-6', 'FIND-6B', 'FIND-6C', 'FIND-6D', 'FIND-6E', 'SW-16'];
  if (!anySelected(ids)) {
    ids.forEach(recordSkip);
    return;
  }
  console.log('[sim-test] RUN driver unit coverage: bash scripts/test_driver_unit.sh');
  const res = runExternalToFiles(['bash', 'scripts/test_driver_unit.sh'], path.join(artifactDir, 'driver-unit.out'), path.join(artifactDir, 'driver-unit.err'), { IOS_USE_HOME: iosHome });
  for (const id of ids) {
    if (!selected(id)) recordSkip(id);
    else if (res.code === 0) recordPass(id);
    else recordFail(id, res.stdout + res.stderr);
  }
}

function addCases(cases, defs) {
  cases.push(...defs);
}

function buildCases() {
  const cases = [];
  const settingsHome = async () => { await resetSettingsHome(); };
  const generalPage = async () => { await openGeneralPage(); };

  addCases(cases, [
    { id: 'DEV-2', run: () => runCaseContains('DEV-2', 'Simulator', ['devices', '--simulator']) },
    { id: 'DEV-3', run: () => runCaseContains('DEV-3', 'Usage:', ['devices', '--help']) },
    { id: 'DEV-1', run: () => runCaseMatches('DEV-1', /Device|No connected real devices/, ['devices']) },
    { id: 'DEV-5', run: async () => {
      if (!selected('DEV-5')) return recordSkip('DEV-5');
      const out = path.join(artifactDir, 'DEV-5.out');
      const err = path.join(artifactDir, 'DEV-5.err');
      console.log('[sim-test] RUN DEV-5: ios-use devices --simulator (empty IOS_USE_HOME)');
      const res = runExternalToFiles([iosUseCli, 'devices', '--simulator'], out, err, { IOS_USE_HOME: path.join(artifactDir, emptyHomeName) });
      if (res.code === 0 && !res.stdout.includes('configured')) recordPass('DEV-5');
      else recordFail('DEV-5', res.stdout + res.stderr);
    } },
    { id: 'CFG-4', run: async () => {
      await runCase('CFG-4', ['config', '--simulator', '--udid', sim.udid]);
      if (selected('CFG-4') || !caseFilterIds) await waitForDriver();
    } },
    { id: 'CFG-1', run: () => runCaseContains('CFG-1', sim.udid, ['config', '--list']) },
    { id: 'CFG-7', run: runConfigDriverIdentityCase },
    { id: 'CFG-5', run: () => runCaseFailsContains('CFG-5', 'unknown option', ['config', '--ipa', path.join(rootDir, 'assets/driver-sim.ipa')]) },
    { id: 'CFG-6', run: () => runCaseFailsContains('CFG-6', 'unknown option', ['config', '--port', '8100']) },
    { id: 'START-1', run: runStartCreatesDriverLockCase },
    { id: 'DEV-4', run: () => runCaseContains('DEV-4', 'configured', ['devices', '--simulator']) },
    { id: 'DEV-6', run: () => runCaseMatches('DEV-6', /Simulator|Device/, ['devices', '--simulator']) },
    { id: 'AA-1', run: async () => {
      if (!selected('AA-1')) return recordSkip('AA-1');
      console.log('[sim-test] RUN AA-1: ios-use home && stop && sleep 1s && dom --fresh');
      const home = runCliToFiles(['home', '--udid', sim.udid], path.join(artifactDir, 'AA-1-home.out'), path.join(artifactDir, 'AA-1-home.err'));
      const stop = runCliToFiles(['stop'], path.join(artifactDir, 'AA-1-stop.out'), path.join(artifactDir, 'AA-1-stop.err'));
      await sleep(1000);
      const dom = runCliToFiles(['dom', '--fresh', '--udid', sim.udid], path.join(artifactDir, 'AA-1.out'), path.join(artifactDir, 'AA-1.err'));
      if (home.code === 0 && stop.code === 0 && dom.code === 0 && dom.stdout.includes('App: com.apple.springboard')) recordPass('AA-1');
      else recordFail('AA-1', home.stdout + home.stderr + stop.stdout + stop.stderr + dom.stdout + dom.stderr);
    } },
    { id: 'AS-7', run: () => runCaseContains('AS-7', 'App: com.apple.springboard', ['dom', '--fresh', '--udid', sim.udid], async () => {
      runCli(['home', '--udid', sim.udid]);
      await sleep(1000);
    }) },
    { id: 'AA-2', run: () => runCaseContains('AA-2', 'App com.apple.Preferences activated', ['activateApp', 'com.apple.Preferences', '--udid', sim.udid]) },
    { id: 'AS-2', run: () => runCaseContains('AS-2', 'App: com.apple.Preferences', ['dom', '--fresh', '--udid', sim.udid]) },
    { id: 'AA-3', run: async () => {
      await runCaseContains('AA-3', 'activated', ['activateApp', 'com.apple.Preferences', '--udid', sim.udid], async () => {
        runCliToFiles(['activateApp', 'com.apple.mobilesafari', '--udid', sim.udid], path.join(artifactDir, 'AA-3-safari.out'), path.join(artifactDir, 'AA-3-safari.err'));
      });
    } },
  ]);

  addCases(cases, [
    { id: 'DOM-1', run: () => runCaseContains('DOM-1', 'App: com.apple.Preferences', ['dom', '--fresh', '--udid', sim.udid], settingsHome) },
    { id: 'DOM-2', run: () => runCaseContains('DOM-2', 'Application', ['dom', '--raw', '--fresh', '--udid', sim.udid], settingsHome) },
    { id: 'DOM-5', run: () => runCaseContains('DOM-5', 'Settings', ['dom', '--fresh', '--udid', sim.udid], settingsHome) },
    { id: 'DOM-6', run: () => runCaseContains('DOM-6', 'Window:', ['dom', '--fresh', '--udid', sim.udid], settingsHome) },
    { id: 'DOM-7', run: runDomPerfCase },
    { id: 'DOM-8', run: () => runCaseContains('DOM-8', 'App: com.apple.Preferences', ['dom', '--fresh', '--udid', sim.udid], settingsHome) },
    { id: 'FIND-1', run: () => runCaseContains('FIND-1', 'Find', ['find', 'General', '--udid', sim.udid], settingsHome) },
    { id: 'FIND-2', run: () => runFindExactPreferredCase('FIND-2') },
    { id: 'FIND-3', run: () => runCaseContains('FIND-3', 'Find', ['find', 'com.apple.settings.general', '--traits', 'Button', '--udid', sim.udid], settingsHome) },
    { id: 'FIND-4', run: () => runCaseContains('FIND-4', 'Find', ['find', 'chevron', '--traits', 'Button,disabled', '--udid', sim.udid], generalPage) },
    { id: 'FIND-5', run: () => runCaseMatches('FIND-5', /suggestions|Did you mean|General/, ['find', 'Generak', '--udid', sim.udid], settingsHome) },
    { id: 'FIND-7', run: () => runCaseContains('FIND-7', 'Find', ['find', 'HomeScreen', '--udid', sim.udid], settingsHome) },
    { id: 'FIND-8', run: () => runCaseContains('FIND-8', 'Find', ['find', 'com.apple.settings.search', '--traits', 'Button', '--udid', sim.udid], settingsHome) },
    { id: 'FIND-9', run: () => runCaseContains('FIND-9', 'chevron', ['find', 'chevron', '--traits', 'Button,disabled', '--udid', sim.udid], generalPage) },
    { id: 'FIND-12', run: runAutoLabelFindCase },
    { id: 'FIND-10A', run: () => runCaseContains('FIND-10A', 'Other "General"', ['find', 'com.apple.settings.general', '--traits', 'Button', '--cindex', '0', '--udid', sim.udid], settingsHome) },
    { id: 'FIND-10B', run: () => runCaseContains('FIND-10B', 'chevron.forward', ['find', 'com.apple.settings.general', '--traits', 'Button', '--cindex', '-1', '--udid', sim.udid], settingsHome) },
    { id: 'FIND-11A', run: () => runCaseFailsContains('FIND-11A', 'not found', ['find', 'com.apple.settings.general', '--traits', 'Button', '--cindex', '99', '--udid', sim.udid], settingsHome) },
    { id: 'FIND-1B', run: async () => {
      await runCaseContains('FIND-1B', 'First name=iosuse-find', ['find', 'iosuse-find', '--traits', 'TextField', '--udid', sim.udid], async () => {
        await openContactsNewContact();
        const input = runCliToFiles(['input', '--label', 'First name', '--content', 'iosuse-find', '--traits', 'TextField', '--udid', sim.udid], path.join(artifactDir, 'FIND-1B-input.out'), path.join(artifactDir, 'FIND-1B-input.err'));
        if (input.code !== 0) {
          throw new Error(`FIND-1B setup input failed\n${input.stdout}${input.stderr}`);
        }
      });
      if (selected('FIND-1B')) await discardContactIfNeeded();
    } },
    { id: 'FIND-5B', run: () => runCaseFailsContains('FIND-5B', 'not found', ['find', '__ios_use_missing_label__', '--udid', sim.udid], settingsHome) },
    { id: 'WF-1', run: () => runCaseContains('WF-1', 'waited=', ['waitFor', '--label', 'com.apple.settings.general', '--traits', 'Button', '--timeout', '2', '--udid', sim.udid], settingsHome) },
    { id: 'WF-2', run: () => runCaseFailsMatches('WF-2', /timed out|not found/i, ['waitFor', '--label', '__ios_use_missing_label__', '--timeout', '0.3', '--udid', sim.udid], settingsHome) },
    { id: 'WF-4', run: () => runCaseFailsMatches('WF-4', /timed out|not found/i, ['waitFor', '--label', '__ios_use_missing_label__', '--timeout', '0.2', '--udid', sim.udid], settingsHome) },
    { id: 'WF-5', run: () => runCaseContains('WF-5', 'General', ['waitFor', '--label', 'com.apple.settings.general', '--traits', 'Button', '--cindex', '0', '--timeout', '2', '--udid', sim.udid], settingsHome) },
  ]);

  addCases(cases, [
    { id: 'SC-2', run: async () => {
      await runCase('SC-2', ['screenshot', '--name', 'sim_command_screenshot', '--udid', sim.udid], settingsHome);
      if (selected('SC-2')) {
        const screenshot = path.join(iosHome, 'artifacts/sim_command_screenshot.jpg');
        if (fs.existsSync(screenshot) && fs.statSync(screenshot).size > 0) fs.copyFileSync(screenshot, path.join(artifactDir, 'sim_command_screenshot.jpg'));
        else recordFail('SC-2', `[sim-test] FAIL SC-2 screenshot file missing: ${screenshot}\n`);
      }
    } },
    { id: 'SC-1', run: async () => {
      if (!selected('SC-1')) return recordSkip('SC-1');
      await settingsHome();
      console.log('[sim-test] RUN SC-1: ios-use screenshot smoke');
      const out = path.join(artifactDir, 'SC-1.out');
      const err = path.join(artifactDir, 'SC-1.err');
      const name = 'sim_command_protocol_screenshot';
      const res = runCliToFiles(['screenshot', '--name', name, '--udid', sim.udid], out, err);
      const screenshot = path.join(iosHome, 'artifacts', `${name}.jpg`);
      if (res.code === 0 && fs.existsSync(screenshot) && fs.statSync(screenshot).size > 2) recordPass('SC-1');
      else recordFail('SC-1', res.stdout + res.stderr);
    } },
  ]);

  const tapCases = [
    { id: 'TAP-1', run: () => runCaseContains('TAP-1', 'Tap', ['tap', 'com.apple.settings.general', '--traits', 'Button', '--udid', sim.udid], settingsHome) },
    { id: 'TAP-5', run: () => runCaseContains('TAP-5', 'Tap', ['tap', 'com.apple.settings.general', '--offset', '10,10', '--traits', 'Button', '--udid', sim.udid], settingsHome) },
    { id: 'TAP-6', run: () => runCaseContains('TAP-6', 'Tap', ['tap', 'com.apple.settings.general', '--offset-ratio', '0.5,0.5', '--traits', 'Button', '--udid', sim.udid], settingsHome) },
    { id: 'TAP-7', run: () => runCaseContains('TAP-7', 'Tap', ['tap', 'com.apple.settings.general', '--offset-ratio', '0.5,', '--traits', 'Button', '--udid', sim.udid], settingsHome) },
    { id: 'TAP-8', run: () => runCaseContains('TAP-8', 'Tap', ['tap', 'com.apple.settings.general', '--offset', ',10', '--traits', 'Button', '--udid', sim.udid], settingsHome) },
    { id: 'TAP-2', run: () => runCaseContains('TAP-2', 'Tap', ['tap', 'About', '--traits', 'Cell', '--udid', sim.udid], generalPage) },
    { id: 'TAP-9', run: () => runCaseFailsContains('TAP-9', 'offset requires element label', ['tap', '200,400', '--offset', '1,1', '--udid', sim.udid], generalPage) },
    { id: 'TAP-10', run: () => runCaseContains('TAP-10', 'Tap', ['tap', 'About', '--offset', '500,500', '--traits', 'Cell', '--udid', sim.udid], generalPage) },
    { id: 'TAP-12', run: async () => {
      if (!selected('TAP-12')) return recordSkip('TAP-12');
      await settingsHome();
      const out = path.join(artifactDir, 'TAP-12.out');
      const err = path.join(artifactDir, 'TAP-12.err');
      console.log('[sim-test] RUN TAP-12: tap cindex child and verify navigation');
      const tap = runCliToFiles(['tap', 'com.apple.settings.general', '--traits', 'Button', '--cindex', '0', '--udid', sim.udid], out, err);
      const verify = runCliToFiles(['find', 'About', '--traits', 'Cell', '--udid', sim.udid], path.join(artifactDir, 'TAP-12-verify.out'), path.join(artifactDir, 'TAP-12-verify.err'));
      if (tap.code === 0 && verify.code === 0) recordPass('TAP-12');
      else recordFail('TAP-12', tap.stdout + tap.stderr + verify.stdout + verify.stderr);
    } },
    { id: 'TAP-13', run: () => runCaseFailsContains('TAP-13', 'point target does not support traits or cindex', ['tap', '200,400', '--cindex', '0', '--udid', sim.udid], settingsHome) },
    { id: 'TAP-3', run: () => runCase('TAP-3', ['tap', '200,400', '--udid', sim.udid], generalPage) },
    { id: 'TAP-4', run: () => runCaseFailsContains('TAP-4', 'not found', ['tap', '__ios_use_missing_label__', '--udid', sim.udid], settingsHome) },
  ];
  addCases(cases, tapCases);

  const swipeCases = [
    { id: 'SW-7B', run: () => runCaseMatches('SW-7B', /scrolls=\d+ direction=down/, ['swipe', '--distance', '200', '--dir', 'forth', '--udid', sim.udid], generalPage) },
    { id: 'SW-10', run: () => runCaseFailsMatches('SW-10', /boundary.*direction=up/, ['swipe', '--distance', '200', '--dir', 'back', '--udid', sim.udid], async () => {
      await generalPage();
      runCli(['swipe', '--distance', '200', '--dir', 'back', '--udid', sim.udid]);
    }) },
    { id: 'SW-12', run: () => runCaseFailsMatches('SW-12', /not found|suggestions/i, ['swipe', '--to', '__ios_use_missing_label__', '--udid', sim.udid], generalPage) },
    { id: 'SW-13', run: () => runCaseContains('SW-13', 'scrolls=', ['swipe', '--to', 'Settings', '--udid', sim.udid], settingsHome) },
    { id: 'SW-14', run: () => runCaseContains('SW-14', 'scrolls=', ['swipe', '--to', 'Settings', '--udid', sim.udid], settingsHome) },
    { id: 'SW-15', run: () => runCaseContains('SW-15', 'scrolls=', ['swipe', '--to', 'Settings', '--from', 'com.apple.settings.general', '--udid', sim.udid], settingsHome) },
    { id: 'SW-17', run: () => runCaseContains('SW-17', 'scrolls=', ['swipe', '--to', 'com.apple.settings.general', '--traits', 'Button', '--udid', sim.udid], settingsHome) },
    { id: 'SW-1', run: () => runCaseContains('SW-1', 'scrolls=', ['swipe', '--to', 'Keyboard', '--traits', 'Cell', '--udid', sim.udid], generalPage) },
    { id: 'SW-2', run: () => runCaseContains('SW-2', 'scrolls=', ['swipe', '--to', 'Keyboard', '--dir', 'forth', '--traits', 'Cell', '--udid', sim.udid], generalPage) },
    { id: 'SW-3', run: () => runCaseContains('SW-3', 'scrolls=', ['swipe', '--to', 'Keyboard', '--traits', 'Cell', '--udid', sim.udid], generalPage) },
    { id: 'SW-3B', run: () => runCaseContains('SW-3B', 'Other "Search"', ['swipe', '--to', 'com.apple.settings.search', '--from', 'com.apple.settings.general', '--traits', 'Button', '--cindex', '0', '--udid', sim.udid], settingsHome) },
    { id: 'SW-4', run: () => runCaseMatches('SW-4', /scrolls=\d+ direction=up/, ['swipe', '--to', 'About', '--from', 'Keyboard', '--dir', 'back', '--traits', 'Cell', '--udid', sim.udid], async () => {
      await generalPage();
      runCliToFiles(['swipe', '--to', 'Keyboard', '--traits', 'Cell', '--udid', sim.udid], path.join(artifactDir, 'SW-4-setup.out'), path.join(artifactDir, 'SW-4-setup.err'));
    }) },
    { id: 'SW-5', run: () => runCaseContains('SW-5', 'scrolls=', ['swipe', '--to', 'About', '--from', '200,650', '--traits', 'Cell', '--udid', sim.udid], generalPage) },
    { id: 'SW-6', run: () => runCaseContains('SW-6', 'scrolls=', ['swipe', '--to', '100,700', '--udid', sim.udid], generalPage) },
    { id: 'SW-7', run: () => runCaseContains('SW-7', 'scrolls=', ['swipe', '--distance', '200', '--dir', 'forth', '--udid', sim.udid], generalPage) },
    { id: 'SW-8', run: () => runCaseContains('SW-8', 'scrolls=', ['swipe', '--distance', '200', '--dir', 'forth', '--udid', sim.udid], generalPage) },
    { id: 'SW-9', run: () => runCaseMatches('SW-9', /scrolls=\d+ direction=down/, ['swipe', '--distance', '900', '--dir', 'forth', '--udid', sim.udid], generalPage) },
    { id: 'SW-11', run: () => runCaseFailsMatches('SW-11', /boundary.*direction=down|not connected/i, ['swipe', '--distance', '200', '--dir', 'forth', '--udid', sim.udid], async () => {
      await generalPage();
      for (let i = 0; i < 6; i++) runCli(['swipe', '--distance', '900', '--dir', 'forth', '--udid', sim.udid]);
    }) },
  ];
  addCases(cases, swipeCases);

  addCases(cases, [
    { id: 'LP-1', run: () => runCaseContains('LP-1', 'Longpress', ['longpress', 'About', '--traits', 'Cell', '--udid', sim.udid], generalPage) },
    { id: 'LP-2', run: () => runCaseContains('LP-2', 'Longpress', ['longpress', '200,400', '--udid', sim.udid], generalPage) },
    { id: 'LP-3', run: () => runCaseContains('LP-3', 'Longpress', ['longpress', 'About', '--traits', 'Cell', '--udid', sim.udid], generalPage) },
    { id: 'LP-4', run: () => runCaseContains('LP-4', 'Longpress', ['longpress', 'About', '--duration', '500', '--traits', 'Cell', '--udid', sim.udid], generalPage) },
    { id: 'LP-5', run: () => runCaseContains('LP-5', 'Longpress', ['longpress', 'About', '--traits', 'Cell', '--udid', sim.udid], generalPage) },
    { id: 'LP-6', run: () => runCaseContains('LP-6', 'Longpress', ['longpress', 'Safari', '--traits', 'Icon', '--duration', '900', '--udid', sim.udid], openHomeScreenWithSafariIcon) },
    { id: 'DOM-5B', run: () => runCaseContains('DOM-5B', 'com.apple.springboardhome.application-shortcut-item', ['dom', '--fresh', '--udid', sim.udid], () => openSpringboardIconMenu('DOM-5B')) },
    { id: 'SW-16B', run: () => runCaseContains('SW-16B', 'com.apple.springboardhome.application-shortcut-item', ['dom', '--fresh', '--udid', sim.udid], () => openSpringboardIconMenu('SW-16B')) },
  ]);

  addCases(cases, [
    { id: 'IN-1', run: async () => { await runInputAndVerifyDom('IN-1', 'First name', 'Alpha', 'First name=Alpha', ['--udid', sim.udid], openContactsNewContact); if (selected('IN-1')) await discardContactIfNeeded(); } },
    { id: 'IN-2', run: async () => { await runInputAndVerifyDom('IN-2', 'Last name', 'Beta', 'Last name=Beta', ['--traits', 'TextField', '--udid', sim.udid], openContactsNewContact); if (selected('IN-2')) await discardContactIfNeeded(); } },
    { id: 'IN-3', run: async () => { await runInputAndVerifyDom('IN-3', 'Alpha', 'More', 'First name=AlphaMore', ['--traits', 'TextField', '--udid', sim.udid], async () => { await openContactsNewContact(); runCliToFiles(['input', '--label', 'First name', '--content', 'Alpha', '--traits', 'TextField', '--udid', sim.udid], path.join(artifactDir, 'IN-3-setup.out'), path.join(artifactDir, 'IN-3-setup.err')); }); if (selected('IN-3')) await discardContactIfNeeded(); } },
    { id: 'IN-4', run: () => runCaseFailsMatches('IN-4', /not inputtable|not found|failed/i, ['input', '--label', 'General', '--content', 'Nope', '--traits', 'Button', '--udid', sim.udid], settingsHome) },
    { id: 'IN-5', run: () => runInputAndVerifyDom('IN-5', 'Search', 'ZZZIOSUse', 'ZZZIOSUse', ['--traits', 'SearchField', '--udid', sim.udid], async () => {
      runCli(['terminateApp', 'com.apple.MobileAddressBook', '--udid', sim.udid]);
      runCli(['activateApp', 'com.apple.MobileAddressBook', '--udid', sim.udid]);
      await sleep(1000);
    }) },
    { id: 'IN-6', run: async () => {
      if (!selected('IN-6')) return recordSkip('IN-6');
      console.log('[sim-test] RUN IN-6: input two Contacts fields with keyboard open');
      const firstAttempt = await verifyContactsNameFields('IN-6', '');
      if (!firstAttempt) {
        await discardContactIfNeeded();
        console.log('[sim-test] IN-6: retrying after rebuilding Contacts form');
      }
      const casePassed = firstAttempt || await verifyContactsNameFields('IN-6', '-retry');
      if (casePassed) {
        recordPass('IN-6');
      } else {
        const details = [
          'IN-6.out',
          'IN-6.err',
          'IN-6-dom.out',
          'IN-6-dom.err',
          'IN-6-retry.out',
          'IN-6-retry.err',
          'IN-6-retry-dom.out',
          'IN-6-retry-dom.err',
        ].map(file => readFileIfExists(path.join(artifactDir, file))).join('');
        recordFail('IN-6', details);
      }
      await discardContactIfNeeded();
    } },
    { id: 'DA-1', run: () => runCaseContains('DA-1', 'Alert dismissed', ['dismissAlert', '--udid', sim.udid], openContactsDiscardAlert) },
    { id: 'DA-2', run: () => runCaseContains('DA-2', 'Alert dismissed', ['dismissAlert', '--index', '0', '--udid', sim.udid], openContactsDiscardAlert) },
    { id: 'TAP-11', run: async () => {
      if (!selected('TAP-11')) return recordSkip('TAP-11');
      const out = path.join(artifactDir, 'TAP-11.out');
      const err = path.join(artifactDir, 'TAP-11.err');
      console.log('[sim-test] RUN TAP-11: waitFor Discard Changes then immediate tap');
      await openContactsDiscardAlert();
      const wait = runCli(['waitFor', '--label', 'Discard Changes', '--traits', 'Button', '--timeout', '3', '--udid', sim.udid]);
      const tap = runCli(['tap', 'Discard Changes', '--traits', 'Button', '--udid', sim.udid]);
      writeFile(out, wait.stdout + tap.stdout);
      writeFile(err, wait.stderr + tap.stderr);
      if (wait.code === 0 && tap.code === 0) recordPass('TAP-11');
      else recordFail('TAP-11', wait.stdout + wait.stderr + tap.stdout + tap.stderr);
    } },
  ]);

  addCases(cases, [
    { id: 'TA-1', run: () => runCaseContains('TA-1', 'terminated', ['terminateApp', 'com.apple.Preferences', '--udid', sim.udid], settingsHome) },
    { id: 'TA-2', run: () => runCaseContains('TA-2', 'terminated', ['terminateApp', 'com.apple.Preferences', '--udid', sim.udid], settingsHome) },
    { id: 'AA-6', run: () => runCaseContains('AA-6', 'activated', ['activateApp', 'com.apple.Preferences', '--udid', sim.udid]) },
    { id: 'OU-1', run: () => runCaseContains('OU-1', 'Opened URL: https://example.com', ['open', 'https://example.com', '--udid', sim.udid]) },
    { id: 'OU-2', run: async () => {
      if (!selected('OU-2')) return recordSkip('OU-2');
      console.log('[sim-test] RUN OU-2: ios-use stop && open https://example.com --udid <sim>');
      const stop = runCliToFiles(['stop'], path.join(artifactDir, 'OU-2-stop.out'), path.join(artifactDir, 'OU-2-stop.err'));
      const open = runCliToFiles(['open', 'https://example.com', '--udid', sim.udid], path.join(artifactDir, 'OU-2.out'), path.join(artifactDir, 'OU-2.err'));
      await waitForDriver();
      if (stop.code === 0 && open.code === 0 && open.stdout.includes('Opened URL: https://example.com')) recordPass('OU-2');
      else recordFail('OU-2', stop.stdout + stop.stderr + open.stdout + open.stderr);
    } },
    { id: 'HOME-1', run: () => runCaseContains('HOME-1', 'Home', ['home', '--udid', sim.udid]) },
    { id: 'DOM-3', run: () => runCaseContains('DOM-3', 'App:', ['dom', '--fresh', '--udid', sim.udid], async () => { runCli(['home', '--udid', sim.udid]); await sleep(1000); }) },
    { id: 'HOME-2', run: () => runCaseContains('HOME-2', 'App: com.apple.springboard', ['dom', '--fresh', '--udid', sim.udid], async () => { runCli(['home', '--udid', sim.udid]); await sleep(1000); }) },
    { id: 'AA-4', run: () => runCaseContains('AA-4', 'activated', ['activateApp', 'com.apple.Preferences', '--udid', sim.udid]) },
    { id: 'AA-5', run: () => runCaseFailsMatches('AA-5', /app not found|state=unknown|not installed/i, ['activateApp', 'com.iosuse.invalid.bundle', '--udid', sim.udid]) },
    { id: 'AS-1', run: async () => { if (!selected('AS-1')) return recordSkip('AS-1'); runCli(['stop']); await runCaseContains('AS-1', 'App:', ['dom', '--fresh', '--udid', sim.udid]); } },
    { id: 'AS-3', run: () => runCaseContains('AS-3', 'Find', ['find', 'General', '--udid', sim.udid], settingsHome) },
    { id: 'AS-4', run: async () => { if (selected('AS-4')) runCli(['stop']); await runCaseContains('AS-4', 'App:', ['dom', '--fresh', '--udid', sim.udid]); } },
    { id: 'AS-5', run: () => runCaseFailsMatches('AS-5', /No signing config|Run .*config|not found/i, ['dom', '--fresh', '--udid', '00000000-0000-0000-0000-000000000000']) },
    { id: 'AS-6', run: async () => {
      if (!selected('AS-6')) return recordSkip('AS-6');
      const out = path.join(artifactDir, 'AS-6.out');
      const err = path.join(artifactDir, 'AS-6.err');
      console.log('[sim-test] RUN AS-6: ios-use dom --fresh (empty IOS_USE_HOME)');
      const res = runExternalToFiles([iosUseCli, 'dom', '--fresh'], out, err, { IOS_USE_HOME: path.join(artifactDir, emptyHomeName) });
      if (res.code === 0 || /Using default device:|Device \| UDID:|Session created/i.test(`${res.stdout}\n${res.stderr}`)) {
        console.log('[sim-test] SKIP AS-6: USB real device is available, no-USB precondition is not met');
        recordSkip('AS-6');
      } else if (/No signing config|Run .*config|No USB|No connected real devices|not found/i.test(`${res.stdout}\n${res.stderr}`)) recordPass('AS-6');
      else recordFail('AS-6', res.stdout + res.stderr);
    } },
    { id: 'AS-8', run: () => runCaseContains('AS-8', 'App:', ['dom', '--fresh', '--udid', sim.udid]) },
  ]);

  const flow = (name) => path.join(flowDir, name);
  addCases(cases, [
    { id: 'FLOW-1', run: () => runCaseContains('FLOW-1', 'Running flow', ['flow', flow('basic.yaml'), '--udid', sim.udid], settingsHome) },
    { id: 'FLOW-2', run: () => runCaseFailsContains('FLOW-2', 'Flow file not found', ['flow', flow('missing-file.yaml'), '--udid', sim.udid]) },
    { id: 'FLOW-3', run: () => runCaseContainsRetryTransient('FLOW-3', 'Running flow', ['flow', flow('basic.yaml'), '--udid', sim.udid], settingsHome) },
    { id: 'FLOW-4', run: () => runCaseContains('FLOW-4', 'Running flow', ['flow', flow('basic.yaml'), '--udid', sim.udid], settingsHome) },
    { id: 'FLOW-6', run: () => runCaseContains('FLOW-6', 'Running flow', ['flow', flow('basic.yaml'), '--targetLabel', 'com.apple.settings.general', '--udid', sim.udid], settingsHome) },
    { id: 'FLOW-7', run: () => runCaseContains('FLOW-7', 'Running flow', ['flow', flow('basic.yaml'), '--targetLabel', 'com.apple.settings.general', '--udid', sim.udid], settingsHome) },
    { id: 'FLOW-8', run: () => runCaseContains('FLOW-8', 'Running flow', ['flow', flow('parent.yaml'), '--udid', sim.udid], settingsHome) },
    { id: 'FLOW-9', run: () => runCaseFailsContains('FLOW-9', 'requested undeclared output', ['flow', flow('missing-output.yaml'), '--udid', sim.udid]) },
    { id: 'FLOW-10', run: () => runCaseFailsContains('FLOW-10', 'cycle detected', ['flow', flow('cycle-a.yaml'), '--udid', sim.udid]) },
    { id: 'FLOW-11', run: () => runCaseContains('FLOW-11', 'Running flow', ['flow', flow('basic.yaml'), '--targetLabel', 'com.apple.settings.general', '--udid', sim.udid], settingsHome) },
    { id: 'FLOW-12', run: () => runCaseContains('FLOW-12', 'returnIf matched', ['flow', flow('return-null.yaml'), '--udid', sim.udid]) },
    { id: 'FLOW-13', run: () => runCaseFailsContains('FLOW-13', 'returnIf requires', ['flow', flow('invalid-return.yaml'), '--udid', sim.udid]) },
    { id: 'FLOW-14', run: () => runCaseContains('FLOW-14', 'Tap', ['flow', flow('tap-offset.yaml'), '--udid', sim.udid], settingsHome) },
    { id: 'FLOW-15', run: () => runCaseContains('FLOW-15', 'oslog: matched=', ['flow', flow('oslog-timeout.yaml'), '--udid', sim.udid]) },
    { id: 'FLOW-16', run: () => unsupportedCase('FLOW-16', 'nslog flow timeout is intentionally excluded from Simulator command coverage') },
    { id: 'FLOW-5', run: () => runCaseFileExists('FLOW-5', path.join(iosHome, 'artifacts/simulator-flow-smoke-screenshot.jpg'), ['flow', flow('standard-smoke.yaml'), '--udid', sim.udid], settingsHome) },
    { id: 'FLOW-17', run: () => runCaseContains('FLOW-17', 'Running flow', ['flow', flow('basic.yaml'), '--targetLabel', 'com.apple.settings.general', '--udid', sim.udid], settingsHome) },
    { id: 'FLOW-18', run: () => runCaseContains('FLOW-18', 'Running flow', ['flow', flow('sleep-default.yaml'), '--udid', sim.udid], settingsHome) },
    { id: 'FLOW-19', run: () => runCaseContains('FLOW-19', 'Running flow', ['flow', flow('basic.yaml'), '--targetLabel', 'com.apple.settings.general', '--udid', sim.udid], async () => { runCli(['config', '--simulator', '--udid', sim.udid]); await waitForDriver(); await settingsHome(); }) },
    { id: 'FLOW-20', run: () => runCaseContains('FLOW-20', 'Running flow', ['flow', flow('basic.yaml'), '--targetLabel', 'com.apple.settings.general', '--udid', sim.udid], settingsHome) },
    { id: 'FLOW-21', run: () => runCaseContains('FLOW-21', 'Running flow', ['flow', flow('basic.yaml'), '--targetLabel', 'com.apple.settings.search', '--udid', sim.udid], settingsHome) },
    { id: 'FLOW-22', run: () => runCaseContains('FLOW-22', 'Running flow', ['flow', flow('basic.yaml'), '--targetLabel', 'com.apple.settings.general', '--verbose', '--udid', sim.udid], settingsHome) },
    { id: 'FLOW-23', run: () => runCaseContains('FLOW-23', 'Running flow', ['flow', flow('basic.yaml'), '--targetLabel', 'com.apple.settings.general', '--udid', sim.udid], settingsHome) },
    ...['FLOW-24', 'FLOW-25', 'FLOW-26'].map(id => ({ id, run: runSwiftCLIUnitCases })),
    { id: 'DOM-4', run: () => runCaseFileExists('DOM-4', path.join(iosHome, 'artifacts/simulator-dom-save.json'), ['flow', flow('dom-save.yaml'), '--udid', sim.udid], settingsHome) },
  ]);

  addCases(cases, [
    { id: 'OL-2', run: () => runCaseContains('OL-2', 'cleared=', ['oslog', '--clear', '--udid', sim.udid]) },
    { id: 'OL-1', run: () => runCaseFileExists('OL-1', path.join(iosHome, 'artifacts/oslog.log'), ['oslog', '--name', 'oslog', '--udid', sim.udid]) },
    { id: 'OL-3', run: () => runCaseFileExists('OL-3', path.join(iosHome, 'artifacts/oslog-pattern.log'), ['oslog', '--name', 'oslog-pattern', '--pattern', '__ios_use_no_such_log_line__', '--udid', sim.udid]) },
    { id: 'OL-4', run: () => runCaseFileExists('OL-4', path.join(iosHome, 'artifacts/oslog-flags.log'), ['oslog', '--name', 'oslog-flags', '--pattern', '__IOS_USE_NO_SUCH_LOG_LINE__', '--flags', 'i', '--udid', sim.udid]) },
    { id: 'OL-5', run: () => runCaseFileExists('OL-5', path.join(iosHome, 'artifacts/custom-oslog-name.log'), ['oslog', '--name', 'custom-oslog-name', '--udid', sim.udid]) },
    { id: 'OL-6', run: () => runCaseFileExists('OL-6', path.join(iosHome, 'artifacts/oslog-bundle.log'), ['oslog', '--name', 'oslog-bundle', '--bundle-id', 'com.apple.Preferences', '--udid', sim.udid]) },
    { id: 'OL-7', run: () => runCaseFileExists('OL-7', path.join(iosHome, 'artifacts/oslog-global.log'), ['oslog', '--name', 'oslog-global', '--udid', sim.udid]) },
    { id: 'OL-8', run: () => runCaseContains('OL-8', 'cleared=', ['oslog', '--clear', '--bundle-id', 'com.apple.Preferences', '--udid', sim.udid]) },
    { id: 'OL-9', run: () => runCaseFileExists('OL-9', path.join(iosHome, 'artifacts/oslog-timeout.log'), ['oslog', '--name', 'oslog-timeout', '--pattern', '__ios_use_no_such_log_line__', '--timeout', '0.2', '--udid', sim.udid]) },
    { id: 'NSL-3', run: () => runCaseFailsContains('NSL-3', 'nslog read', ['nslog', '--grep', 'ready']) },
    { id: 'NSL-4', run: () => runCaseFailsContains('NSL-4', 'ios-use nslog start', ['nslog', 'read']) },
    { id: 'CFG-2', run: () => unsupportedCase('CFG-2', 'real-device signing/install path, not Simulator') },
    { id: 'CFG-3', run: () => unsupportedCase('CFG-3', 'Apple ID first-login signing path, not Simulator and must not touch local credentials') },
    ...['DOM-9', 'FIND-5A', 'FIND-6', 'FIND-6B', 'FIND-6C', 'FIND-6D', 'FIND-6E', 'SW-16'].map(id => ({ id, run: runDriverUnitCases })),
    { id: 'PROXY-1', run: runProxyDoctorCase },
    ...['PROXY-2', 'PROXY-3', 'PROXY-4', 'PROXY-5', 'PROXY-5B', 'PROXY-6'].map(id => ({ id, run: runSwiftCLIUnitCases })),
    { id: 'PROXY-7', run: runProxyReadMissingCaptureCase },
    { id: 'STOP-1', run: () => runCase('STOP-1', ['stop']) },
    { id: 'STOP-2', run: () => runCase('STOP-2', ['stop']) },
    { id: 'STOP-3', run: runStopClearsDriverLockCase },
  ]);

  return cases;
}

async function cleanup() {
  runCli(['stop']);
  const driverLog = path.join(iosHome, 'logs/driver.log');
  if (fs.existsSync(driverLog)) fs.copyFileSync(driverLog, path.join(artifactDir, 'driver.log'));
  restoreLocalState();
  releaseRunLock();
}

async function main() {
  const parsedArgs = parseRunnerArgs(process.argv.slice(2));
  skipBuild = parsedArgs.skipBuild;
  caseFilterIds = parsedArgs.caseFilterIds;

  if (!skipBuild) {
    const swiftCliBuild = execCmd(['bash', path.join(rootDir, 'scripts/build_swift_cli.sh')], { cwd: rootDir });
    process.stdout.write(swiftCliBuild.stdout);
    process.stderr.write(swiftCliBuild.stderr);
    if (swiftCliBuild.code !== 0) process.exit(swiftCliBuild.code);

    const build = execCmd(['bash', path.join(rootDir, 'scripts/build_driver.sh'), '--simulator-only'], { cwd: rootDir });
    process.stdout.write(build.stdout);
    process.stderr.write(build.stderr);
    if (build.code !== 0) process.exit(build.code);
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

  console.log(`[sim-test] IOS_USE_HOME: ${iosHome}`);
  console.log(`[sim-test] Simulator: ${sim.name} | ${sim.runtime} | ${sim.state} | UDID: ${sim.udid}`);
  console.log(`[sim-test] CLI: ${iosUseCli}`);
  console.log(`[sim-test] driver-sim IPA: ${path.join(rootDir, 'assets/driver-sim.ipa')}`);
  console.log(`[sim-test] Artifacts: ${artifactDir}`);

  prepareSimulatorDriverAsset();
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
    const cases = buildCases();
    validateCaseFilter(cases.map(testCase => testCase.id), caseFilterIds);
    await prerequisiteConfig();
    const unitGroups = new Set();
    for (const testCase of cases) {
      if ((testCase.run === runDriverUnitCases || testCase.run === runSwiftCLIUnitCases) && unitGroups.has(testCase.run)) {
        continue;
      }
      if (testCase.run === runDriverUnitCases || testCase.run === runSwiftCLIUnitCases) unitGroups.add(testCase.run);
      await testCase.run();
    }

    const summary = {
      iosUseHome: iosHome,
      simulator: sim.name,
      simulatorUdid: sim.udid,
      runtime: sim.runtime,
      passed,
      failed,
      skipped,
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
