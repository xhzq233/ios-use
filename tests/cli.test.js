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
  test('config --list runs without error', () => {
    const result = runCli(['config', '--list']);
    expect(result.status).toBe(0);
    expect(result.stdout).toMatch(/No configured devices|Configured devices:/);
  });

  test('accepts traits option on label commands', () => {
    expectAcceptedWithoutSession(['find', '通用', '--traits', 'Cell']);
    expectAcceptedWithoutSession(['find', '通用', '--traits', 'Cell,Button']);
    expectAcceptedWithoutSession(['tap', '通用', '--traits', 'Cell']);
    expectAcceptedWithoutSession(['tap', '通用', '--traits', 'Cell,Button']);
    expectAcceptedWithoutSession(['tap', '通用', '--offset', '12,5']);
    expectAcceptedWithoutSession(['tap', '通用', '--offset-ratio', '0.8,0.5']);
    expectAcceptedWithoutSession(['tap', '通用', '--offset-ratio', '0.8']);
    expectAcceptedWithoutSession(['tap', '通用', '--offset', '0,5']);
    expectAcceptedWithoutSession(['input', '--label', '通用', '--content', 'abc', '--traits', 'Cell']);
    expectAcceptedWithoutSession(['input', '--label', '通用', '--content', 'abc', '--traits', 'Cell,Button']);
    expectAcceptedWithoutSession(['swipe', '--to', '通用', '--traits', 'Cell']);
    expectAcceptedWithoutSession(['swipe', '--to', '通用', '--traits', 'Cell,Button']);
    expectAcceptedWithoutSession(['longpress', '通用', '--traits', 'Cell']);
    expectAcceptedWithoutSession(['waitFor', '--label', '通用', '--traits', 'Cell']);
  });

  test('rejects invalid numeric option values', () => {
    expectNumericParseError(['config', '--port', 'abc', '--list'], 'Invalid integer: "abc"');
    expectNumericParseError(['swipe', '--distance', 'abc'], 'Invalid number: "abc"');
    expectNumericParseError(['waitFor', '--label', 'foo', '--timeout', 'abc'], 'Invalid number: "abc"');
    expectNumericParseError(['longpress', 'foo', '--duration', 'abc'], 'Invalid integer: "abc"');
    expectNumericParseError(['nslog', '--port', 'abc'], 'Invalid integer: "abc"');
  });

  test('fails safely for missing flow file', () => {
    const result = runCli(['flow', 'missing-file.json']);
    expect(result.status).toBe(1);
    expect(`${result.stdout}${result.stderr}`).toContain('Flow file not found');
  });
});
