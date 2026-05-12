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

function isolatedHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ios-use-cli-test-'));
  fs.mkdirSync(path.join(home, '.ios-use'), { recursive: true });
  return home;
}

function combinedOutput(result) {
  return `${result.stdout}${result.stderr}`;
}

describe('cli surface', () => {
  test('current top-level commands expose help', () => {
    for (const args of [['devices', '--help'], ['stop', '--help'], ['activateApp', '--help'], ['nslog', '--help']]) {
      const result = runCli(args, { HOME: isolatedHome() });
      expect(result.status).toBe(0);
      expect(combinedOutput(result)).toContain(args[0]);
    }
  });

  test('device alias remains accepted during migration', () => {
    const result = runCli(['device', '--help'], { HOME: isolatedHome() });
    expect(result.status).toBe(0);
    expect(combinedOutput(result)).toContain('devices');
  });

  test('rejects invalid numeric option values before session setup', () => {
    const cases = [
      [['config', '--port', 'abc', '--list'], 'Invalid integer: "abc"'],
      [['swipe', '--distance', 'abc'], 'Invalid number: "abc"'],
      [['waitFor', '--label', 'foo', '--timeout', 'abc'], 'Invalid number: "abc"'],
      [['longpress', 'foo', '--duration', 'abc'], 'Invalid integer: "abc"'],
      [['longpress', 'foo', '--duration', '500ms'], 'Invalid integer: "500ms"'],
      [['dismissAlert', '--index', '1.5'], 'Invalid integer: "1.5"'],
    ];
    for (const [args, message] of cases) {
      const result = runCli(args, { HOME: isolatedHome() });
      expect(result.status).toBe(1);
      expect(combinedOutput(result)).toContain(message);
    }
  });

  test('fails safely for missing flow file', () => {
    const result = runCli(['flow', 'missing-file.yaml'], { HOME: isolatedHome() });
    expect(result.status).toBe(1);
    expect(combinedOutput(result)).toContain('Flow file not found');
  });

  test('flow accepts external vars before session setup', () => {
    const result = runCli(['flow', 'missing-file.yaml', '--server', '192.168.1.10', '--port', '9080'], { HOME: isolatedHome() });
    expect(result.status).toBe(1);
    expect(combinedOutput(result)).toContain('Flow file not found');
    expect(combinedOutput(result)).not.toContain('too many arguments');
  });
});
