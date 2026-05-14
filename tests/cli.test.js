import { afterAll, describe, test, expect } from 'bun:test';
import { spawnSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';

const CLI_PATH = new URL('../src/cli.ts', import.meta.url).pathname;
const isolatedHomes = [];

function runCli(args, envOverrides = {}) {
  return spawnSync('bun', [CLI_PATH, ...args], {
    encoding: 'utf-8',
    env: { ...process.env, ...envOverrides },
  });
}

function isolatedHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ios-use-cli-test-'));
  fs.mkdirSync(path.join(home, '.ios-use'), { recursive: true });
  isolatedHomes.push(home);
  return home;
}

function combinedOutput(result) {
  return `${result.stdout}${result.stderr}`;
}

describe('cli surface', () => {
  afterAll(() => {
    for (const home of isolatedHomes) {
      fs.rmSync(home, { recursive: true, force: true });
    }
  });

  test('registered action commands reject missing args before session setup', () => {
    const cases = [
      { args: ['activateApp'], message: 'missing required argument' },
      { args: ['terminateApp'], message: 'missing required argument' },
      { args: ['find'], message: 'missing required argument' },
      { args: ['openURL'], message: "required option '--url <url>' not specified" },
    ];
    for (const { args, message } of cases) {
      const result = runCli(args, { HOME: isolatedHome() });
      expect(result.status).toBe(1);
      expect(combinedOutput(result)).toContain(message);
      expect(combinedOutput(result)).not.toContain('No configured device');
    }
  });

  test('device alias is registered but still rejects invalid options locally', () => {
    const result = runCli(['device', '--not-a-real-option'], { HOME: isolatedHome() });
    expect(result.status).toBe(1);
    expect(combinedOutput(result)).toContain("unknown option '--not-a-real-option'");
    expect(combinedOutput(result)).not.toContain('No connected real devices found');
  });

  test('rejects invalid numeric option values before session setup', () => {
    const cases = [
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

  test('config no longer exposes ipa or port options', () => {
    const help = runCli(['config', '--help'], { HOME: isolatedHome() });
    expect(help.status).toBe(0);
    expect(combinedOutput(help)).not.toContain('--ipa');
    expect(combinedOutput(help)).not.toContain('--port');

    for (const args of [['config', '--ipa', 'driver.ipa', '--list'], ['config', '--port', '8101', '--list']]) {
      const result = runCli(args, { HOME: isolatedHome() });
      expect(result.status).toBe(1);
      expect(combinedOutput(result)).toContain('unknown option');
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
