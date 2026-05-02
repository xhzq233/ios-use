import { describe, test, expect } from 'bun:test';
import { spawnSync } from 'child_process';

const CLI_PATH = new URL('../src/cli.ts', import.meta.url).pathname;

function runCli(args) {
  return spawnSync('bun', [CLI_PATH, ...args], {
    encoding: 'utf-8',
    env: { ...process.env },
  });
}

describe('app commands', () => {
  test('activateApp expects bundleId argument', () => {
    const result = runCli(['activateApp', '--help']);
    expect(result.status).toBe(0);
    expect(result.stdout).toContain('activateApp');
    expect(result.stdout).toContain('<bundleId>');
    expect(result.stdout).toContain('--udid');
  });

  test('terminateApp expects bundleId argument', () => {
    const result = runCli(['terminateApp', '--help']);
    expect(result.status).toBe(0);
    expect(result.stdout).toContain('terminateApp');
    expect(result.stdout).toContain('<bundleId>');
  });
});
