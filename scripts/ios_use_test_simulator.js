#!/usr/bin/env node
import { execFileSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';

const IOS_USE_HOME = path.resolve(process.env.IOS_USE_HOME || path.join(os.homedir(), '.ios-use'));
const STATE_FILE = path.join(IOS_USE_HOME, 'simulators', 'ios-use-test.json');
const DEFAULT_NAME = process.env.IOS_USE_TEST_SIM_NAME || 'IOSUseTest';
const DEFAULT_DEVICE_TYPE = process.env.IOS_USE_TEST_SIM_DEVICE_TYPE || 'iPhone 16';
const DEFAULT_RUNTIME = process.env.IOS_USE_TEST_SIM_RUNTIME || '';
const BOOT_TIMEOUT_MS = parsePositiveIntEnv('IOS_USE_TEST_SIM_BOOT_TIMEOUT_MS', 300_000);

function parsePositiveIntEnv(name, fallback) {
  const raw = process.env[name];
  if (!raw) return fallback;
  if (!/^[1-9]\d*$/.test(raw)) {
    throw new Error(`${name} must be a positive integer, got ${JSON.stringify(raw)}`);
  }
  return Number(raw);
}

function run(command, args, options = {}) {
  return execFileSync(command, args, {
    encoding: 'utf8',
    stdio: options.stdio || ['ignore', 'pipe', 'pipe'],
    timeout: options.timeout,
  }).trim();
}

function simctlJson(args) {
  return JSON.parse(run('xcrun', ['simctl', 'list', '-j', ...args]));
}

function flattenDevices() {
  const listed = simctlJson(['devices', 'available']).devices || {};
  const devices = [];
  for (const [runtimeIdentifier, items] of Object.entries(listed)) {
    for (const device of items || []) {
      if (device?.isAvailable !== false) {
        devices.push({ ...device, runtimeIdentifier });
      }
    }
  }
  return devices;
}

function readState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return null;
  }
}

function compareVersions(a, b) {
  const aa = String(a || '').split('.').map((v) => Number(v) || 0);
  const bb = String(b || '').split('.').map((v) => Number(v) || 0);
  for (let i = 0; i < Math.max(aa.length, bb.length); i++) {
    const delta = (aa[i] || 0) - (bb[i] || 0);
    if (delta !== 0) return delta;
  }
  return 0;
}

function chooseRuntime() {
  const runtimes = (simctlJson(['runtimes']).runtimes || [])
    .filter((runtime) => runtime?.isAvailable && /^iOS/i.test(runtime.name || runtime.platform || 'iOS'))
    .filter((runtime) => !DEFAULT_RUNTIME || runtime.name === DEFAULT_RUNTIME || runtime.version === DEFAULT_RUNTIME || runtime.identifier === DEFAULT_RUNTIME)
    .sort((a, b) => compareVersions(b.version, a.version));

  if (runtimes.length === 0) {
    throw new Error(DEFAULT_RUNTIME
      ? `No available iOS Simulator runtime matches ${DEFAULT_RUNTIME}`
      : 'No available iOS Simulator runtime found');
  }
  return runtimes[0];
}

function chooseDeviceType(runtime) {
  const supported = runtime.supportedDeviceTypes || [];
  return supported.find((type) => type.name === DEFAULT_DEVICE_TYPE)
    || supported.find((type) => type.productFamily === 'iPhone' && type.name === 'iPhone 16')
    || supported.find((type) => type.productFamily === 'iPhone')
    || supported[0];
}

function writeState(info) {
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, `${JSON.stringify(info, null, 2)}\n`);
}

function deviceInfo(device) {
  return {
    iosUseHome: IOS_USE_HOME,
    stateFile: STATE_FILE,
    name: device.name,
    udid: device.udid,
    runtimeIdentifier: device.runtimeIdentifier,
    runtime: device.runtimeIdentifier.replace(/^com\.apple\.CoreSimulator\.SimRuntime\.iOS-/, 'iOS ').replace(/-/g, '.'),
    deviceTypeIdentifier: device.deviceTypeIdentifier,
    state: device.state,
  };
}

function findReusableDevice() {
  const devices = flattenDevices();
  const state = readState();
  if (state?.udid) {
    const byUdid = devices.find((device) => device.udid === state.udid);
    if (byUdid) return byUdid;
  }
  return devices.find((device) => device.name === DEFAULT_NAME) || null;
}

function createDevice() {
  const runtime = chooseRuntime();
  const deviceType = chooseDeviceType(runtime);
  if (!deviceType?.identifier) {
    throw new Error(`No usable device type found for runtime ${runtime.name || runtime.identifier}`);
  }
  const udid = run('xcrun', ['simctl', 'create', DEFAULT_NAME, deviceType.identifier, runtime.identifier]);
  const device = flattenDevices().find((item) => item.udid === udid);
  if (!device) {
    throw new Error(`Created Simulator ${udid}, but simctl did not list it as available`);
  }
  return device;
}

function bootDevice(udid) {
  try {
    run('xcrun', ['simctl', 'boot', udid]);
  } catch {
    // Already booted or booting.
  }
  execFileSync('xcrun', ['simctl', 'bootstatus', udid, '-b'], { stdio: 'pipe', timeout: BOOT_TIMEOUT_MS });
}

function ensure() {
  const device = findReusableDevice() || createDevice();
  bootDevice(device.udid);
  const fresh = flattenDevices().find((item) => item.udid === device.udid) || device;
  const info = {
    ...deviceInfo(fresh),
    updatedAt: new Date().toISOString(),
  };
  if (!readState()?.createdAt || readState()?.udid !== info.udid) {
    info.createdAt = info.updatedAt;
  } else {
    info.createdAt = readState().createdAt;
  }
  writeState(info);
  return info;
}

const command = process.argv[2] || 'ensure';
if (command !== 'ensure') {
  throw new Error(`Unknown command: ${command}`);
}

console.log(JSON.stringify(ensure()));
