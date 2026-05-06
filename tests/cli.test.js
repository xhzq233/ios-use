import { describe, test, expect } from 'bun:test';
import { spawnSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';

const CLI_PATH = new URL('../src/cli.ts', import.meta.url).pathname;

function runCli(args, envOverrides = {}) {
  return spawnSync('bun', [CLI_PATH, ...args], {
    encoding: 'utf-8',
    env: { ...process.env, ...envOverrides },
  });
}

function expectHelp(args, includes = [], excludes = []) {
  const result = runCli(args);
  expect(result.status).toBe(0);
  for (const needle of includes) {
    expect(result.stdout).toContain(needle);
  }
  for (const needle of excludes) {
    expect(result.stdout).not.toContain(needle);
  }
}

function expectNumericParseError(args, fragment) {
  const result = runCli(args);
  expect(result.status).toBe(1);
  expect(`${result.stdout}${result.stderr}`).toContain(fragment);
}

function makeIsolatedHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ios-use-cli-test-'));
  fs.mkdirSync(path.join(home, '.ios-use'), { recursive: true });
  return home;
}

function expectAcceptedWithoutSession(args) {
  const result = runCli(args, { HOME: makeIsolatedHome() });
  expect(result.status).toBe(1);
  expect(`${result.stdout}${result.stderr}`).toContain('No active session found');
  expect(`${result.stdout}${result.stderr}`).not.toContain('unknown option');
}

describe('cli', () => {
  test('shows top-level help with all host API commands', () => {
    expectHelp(['--help'], [
      'ios-use',
      'device',
      'config',
      'session',
      'activateApp',
      'terminateApp',
      'dom',
      'find',
      'tap',
      'swipe',
      'input',
      'longpress',
      'screenshot',
      'waitFor',
      'oslog',
      'flow',
      'nslog',
    ]);
  });

  test('shows device help with all options', () => {
    expectHelp(['device', '--help'], [
      'Show connected iOS device info',
      '-s, --simulator',
      '--verbose',
    ]);
  });

  test('shows config help with all fields', () => {
    expectHelp(['config', '--help'], [
      'Configure driver for device or Simulator',
      '--udid',
      '--list',
      '--simulator',
      '--apple-id',
      '--password',
      '--ipa',
      '--port',
      '--verbose',
    ]);
  });

  test('config --list runs without error', () => {
    const result = runCli(['config', '--list']);
    expect(result.status).toBe(0);
    expect(result.stdout).toMatch(/No configured devices|Configured devices:/);
  });

  test('shows session subcommand help', () => {
    expectHelp(['session', 'start', '--help'], [
      'Start a persistent session',
      '--bundle-id',
      '--udid',
      '--verbose',
    ]);
    expectHelp(['session', 'stop', '--help'], ['Stop the current session and driver']);
    expectHelp(['session', 'status', '--help'], ['Show current session info']);
  });

  test('shows app command help with session fields', () => {
    expectHelp(['activateApp', '--help'], [
      'activateApp',
      '<bundleId>',
      '--udid',
      '--bundle-id',
      '--verbose',
    ]);
    expectHelp(['terminateApp', '--help'], [
      'terminateApp',
      '<bundleId>',
      '--udid',
      '--bundle-id',
      '--verbose',
    ]);
  });

  test('shows dom/find/input/screenshot help with all fields', () => {
    expectHelp(['dom', '--help'], [
      'Dump current UI DOM tree',
      '--raw',
      '--save',
      '--name',
      '--udid',
      '--bundle-id',
      '--verbose',
    ], ['--mode']);
    expectHelp(['find', '--help'], [
      'Find UI element by label',
      '--context.ancestor-type',
      '--context.ancestorType',
      '--context.ancestor-label',
      '--context.ancestorLabel',
      '--udid',
      '--bundle-id',
      '--verbose',
    ]);
    expectHelp(['input', '--help'], [
      'Type text into an element',
      '--content',
      '--label',
      '--context.ancestor-type',
      '--context.ancestorType',
      '--context.ancestor-label',
      '--context.ancestorLabel',
      '--udid',
      '--bundle-id',
      '--verbose',
    ]);
    expectHelp(['screenshot', '--help'], [
      'Take a screenshot',
      '--name',
      '--udid',
      '--bundle-id',
      '--verbose',
    ]);
  });

  test('shows tap/longpress/swipe/waitFor/oslog help with all fields', () => {
    expectHelp(['tap', '--help'], [
      '--label',
      '"x,y"',
      '--offset-x',
      '--offset-y',
      '--offset-x-ratio',
      '--offset-y-ratio',
      '--context.ancestor-type',
      '--context.ancestorType',
      '--context.ancestor-label',
      '--context.ancestorLabel',
      '--udid',
      '--bundle-id',
      '--verbose',
    ], ['--x ']);
    expectHelp(['longpress', '--help'], [
      '--label',
      '--duration',
      '--context.ancestor-type',
      '--context.ancestorType',
      '--context.ancestor-label',
      '--context.ancestorLabel',
      '--udid',
      '--bundle-id',
      '--verbose',
    ], ['--x ']);
    expectHelp(['swipe', '--help'], [
      '--to',
      '--from',
      '--dir',
      '--distance',
      '--context.ancestor-type',
      '--context.ancestorType',
      '--context.ancestor-label',
      '--context.ancestorLabel',
      '--udid',
      '--bundle-id',
      '--verbose',
    ], ['--anchor-x', '--until-x', '--length']);
    expectHelp(['waitFor', '--help'], [
      'Wait until an element becomes visible',
      '--label',
      '--timeout',
      '--context.ancestor-type',
      '--context.ancestorType',
      '--context.ancestor-label',
      '--context.ancestorLabel',
      '--udid',
      '--bundle-id',
      '--verbose',
    ], ['--interval']);
    expectHelp(['oslog', '--help'], [
      'Fetch iOS system logs from the device',
      '--pattern',
      '--flags',
      '--name',
      '--clear',
      '--udid',
      '--bundle-id',
      '--verbose',
    ]);
  });

  test('shows flow and nslog help with all fields', () => {
    expectHelp(['flow', '--help'], [
      'Execute a flow file',
      '--udid',
      '--verbose',
    ]);
    expectHelp(['nslog', '--help'], [
      'Start NSLogger server',
      '--port',
      '--grep',
      '--flags',
      '--name',
      '--ssl',
      '--no-ssl',
      '--publish-bonjour',
      '--no-publish-bonjour',
    ]);
  });

  test('accepts both context option spellings on label commands', () => {
    expectAcceptedWithoutSession(['find', '通用', '--context.ancestor-type', 'Table']);
    expectAcceptedWithoutSession(['find', '通用', '--context.ancestorType', 'Table']);
    expectAcceptedWithoutSession(['tap', '--label', '通用', '--context.ancestor-label', '设置']);
    expectAcceptedWithoutSession(['tap', '--label', '通用', '--context.ancestorLabel', '设置']);
    expectAcceptedWithoutSession(['tap', '--label', '通用', '--offset-x', '12', '--offset-y', '5']);
    expectAcceptedWithoutSession(['tap', '--label', '通用', '--offset-x-ratio', '0.8', '--offset-y-ratio', '0.5']);
    expectAcceptedWithoutSession(['tap', '--label', '通用', '--offset-x-ratio', '0.8']);
    expectAcceptedWithoutSession(['tap', '--label', '通用', '--offset-y', '5']);
    expectAcceptedWithoutSession(['input', '--label', '通用', '--content', 'abc', '--context.ancestor-type', 'Table']);
    expectAcceptedWithoutSession(['input', '--label', '通用', '--content', 'abc', '--context.ancestorLabel', '设置']);
    expectAcceptedWithoutSession(['swipe', '--to', '通用', '--context.ancestorType', 'Table']);
    expectAcceptedWithoutSession(['swipe', '--to', '通用', '--context.ancestor-label', '设置']);
    expectAcceptedWithoutSession(['longpress', '--label', '通用', '--context.ancestorType', 'Table']);
    expectAcceptedWithoutSession(['waitFor', '--label', '通用', '--context.ancestorLabel', '设置']);
  });

  test('rejects invalid numeric option values', () => {
    expectNumericParseError(['config', '--port', 'abc', '--list'], 'Invalid integer: "abc"');
    expectNumericParseError(['swipe', '--distance', 'abc'], 'Invalid number: "abc"');
    expectNumericParseError(['waitFor', '--label', 'foo', '--timeout', 'abc'], 'Invalid number: "abc"');
    expectNumericParseError(['longpress', '--label', 'foo', '--duration', 'abc'], 'Invalid integer: "abc"');
    expectNumericParseError(['nslog', '--port', 'abc'], 'Invalid integer: "abc"');
  });

  test('fails safely for missing flow file', () => {
    const result = runCli(['flow', 'missing-file.json']);
    expect(result.status).toBe(1);
    expect(`${result.stdout}${result.stderr}`).toContain('Flow file not found');
  });
});
