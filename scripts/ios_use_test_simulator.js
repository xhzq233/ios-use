#!/usr/bin/env node
import { execFileSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

const IOS_USE_HOME = path.resolve(process.env.IOS_USE_HOME || path.join(os.homedir(), '.ios-use'));
const STATE_FILE = path.join(IOS_USE_HOME, 'simulators', 'ios-use-test.json');
const DEFAULT_NAME = process.env.IOS_USE_TEST_SIM_NAME || 'IOSUseTest';
const DEFAULT_DEVICE_TYPE = process.env.IOS_USE_TEST_SIM_DEVICE_TYPE || '';
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

export function chooseRuntime(listed, requestedRuntime = '', requestedDevice = '') {
  const runtimes = listed
    .filter((runtime) => runtime?.isAvailable && /^iOS/i.test(runtime.name || runtime.platform || ''))
    .filter((runtime) => !requestedRuntime || [runtime.name, runtime.version, runtime.identifier].includes(requestedRuntime))
    .filter((runtime) => !requestedDevice || (runtime.supportedDeviceTypes || [])
      .some((type) => [type.name, type.identifier].includes(requestedDevice)))
    .sort((a, b) => compareVersions(b.version, a.version));
  if (runtimes.length === 0) {
    throw new Error(`No available iOS Simulator runtime matches runtime=${requestedRuntime || 'latest compatible'}, device=${requestedDevice || 'automatic'}`);
  }
  return runtimes[0];
}

export function chooseDeviceType(runtime, requested = '') {
  const supported = runtime.supportedDeviceTypes || [];
  const selected = requested
    ? supported.find((type) => [type.name, type.identifier].includes(requested))
    : supported.find((type) => type.name === 'iPhone 16')
      || supported.find((type) => type.productFamily === 'iPhone')
      || supported[0];
  if (!selected?.identifier) {
    throw new Error(`Runtime ${runtime.name || runtime.identifier} does not support device ${requested || 'automatic'}`);
  }
  return selected;
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

export function findReusableDevice(devices, state, runtime, deviceType, name) {
  const compatible = devices.filter((device) =>
    device.name === name && device.runtimeIdentifier === runtime.identifier &&
    device.deviceTypeIdentifier === deviceType.identifier);
  return compatible.find((device) => device.udid === state?.udid)
    || compatible[0] || null;
}

function resolveDevice() {
  const runtime = chooseRuntime(simctlJson(['runtimes']).runtimes || [], DEFAULT_RUNTIME, DEFAULT_DEVICE_TYPE);
  const deviceType = chooseDeviceType(runtime, DEFAULT_DEVICE_TYPE);
  const existing = findReusableDevice(flattenDevices(), readState(), runtime, deviceType, DEFAULT_NAME);
  if (existing) return existing;
  const udid = run('xcrun', ['simctl', 'create', DEFAULT_NAME, deviceType.identifier, runtime.identifier]);
  const device = flattenDevices().find((item) => item.udid === udid);
  if (!device) throw new Error(`Created Simulator ${udid}, but simctl did not list it as available`);
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

function ensure(boot = true) {
  const device = resolveDevice();
  if (boot) bootDevice(device.udid);
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

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const command = process.argv[2] || 'ensure';
  if (!['ensure', 'resolve'].includes(command)) throw new Error(`Unknown command: ${command}`);
  console.log(JSON.stringify(ensure(command === 'ensure')));
}
