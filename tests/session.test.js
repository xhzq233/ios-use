import { describe, test, expect, beforeEach, afterEach } from 'bun:test';
import { spawnSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import { clearSessionInfo, readSessionInfo, writeSessionInfo } from '../src/session.js';
import { SESSION_FILE } from '../src/utils/paths.js';

const CLI_PATH = new URL('../src/cli.ts', import.meta.url).pathname;

function runCli(args) {
  return spawnSync('bun', [CLI_PATH, ...args], {
    encoding: 'utf-8',
    env: { ...process.env },
  });
}

function backupSession() {
  if (fs.existsSync(SESSION_FILE)) return fs.readFileSync(SESSION_FILE, 'utf-8');
  return null;
}

function restoreSession(saved) {
  if (saved !== null) {
    fs.mkdirSync(path.dirname(SESSION_FILE), { recursive: true });
    fs.writeFileSync(SESSION_FILE, saved);
  }
  else if (fs.existsSync(SESSION_FILE)) fs.unlinkSync(SESSION_FILE);
}

describe('session file helpers', () => {
  let saved;

  beforeEach(() => { saved = backupSession(); });
  afterEach(() => { restoreSession(saved); });

  test('write/read/clear session info', () => {
    clearSessionInfo();

    writeSessionInfo({ sessionId: 's1', bundleId: 'com.demo.app' });
    expect(fs.existsSync(SESSION_FILE)).toBe(true);
    expect(readSessionInfo()).toEqual({ sessionId: 's1', bundleId: 'com.demo.app' });

    clearSessionInfo();
    expect(fs.existsSync(SESSION_FILE)).toBe(false);
  });
});

describe('session command safety', () => {
  let saved;

  beforeEach(() => { saved = backupSession(); });
  afterEach(() => { restoreSession(saved); });

  test('session status works without active session', () => {
    if (fs.existsSync(SESSION_FILE)) fs.unlinkSync(SESSION_FILE);
    const result = runCli(['session', 'status']);
    expect(result.status).toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain('No active session');
  });

  test('session status prints device info when present in session file', () => {
    fs.writeFileSync(SESSION_FILE, JSON.stringify({
      bundleId: 'com.demo.app',
      udid: 'u1',
      deviceName: 'QA Phone',
      deviceVersion: '18.3.2',
      sessionId: 'abcdef1234567890',
      createdAt: 1700000000000,
    }));

    const result = runCli(['session', 'status']);
    expect(result.status).toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain('QA Phone | iOS 18.3.2');
  });

  test('tap without active session fails safely', () => {
    if (fs.existsSync(SESSION_FILE)) fs.unlinkSync(SESSION_FILE);
    const result = runCli(['tap', 'Settings']);
    expect(result.status).toBe(1);
    expect(`${result.stdout}${result.stderr}`).toContain('No active session found');
  });
});
