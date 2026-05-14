import { describe, test, expect, beforeEach, afterEach, afterAll, mock } from 'bun:test';
import fs from 'fs';
import path from 'path';
import os from 'os';

const testHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ios-use-session-test-'));
const stateDir = path.join(testHome, '.ios-use', 'state');
const logDir = path.join(testHome, '.ios-use', 'logs');
const sessionFile = path.join(stateDir, 'session.json');
const driverLogFile = path.join(logDir, 'driver.log');

mock.module('../src/utils/paths.js', () => ({
  DRIVER_LOG_FILE: driverLogFile,
  SESSION_FILE: sessionFile,
  ensureLogDir: () => fs.mkdirSync(logDir, { recursive: true }),
  ensureStateDir: () => fs.mkdirSync(stateDir, { recursive: true }),
}));

describe('session file helpers', () => {
  let originalHome;

  beforeEach(() => {
    originalHome = process.env.HOME;
    process.env.HOME = testHome;
    fs.rmSync(path.join(testHome, '.ios-use'), { recursive: true, force: true });
  });

  afterEach(() => {
    process.env.HOME = originalHome;
  });

  afterAll(() => {
    fs.rmSync(testHome, { recursive: true, force: true });
  });

  test('write/read/clear session info', async () => {
    const { clearSessionInfo, readSessionInfo, writeSessionInfo } = await import(`../src/session.ts?session-test=${Date.now()}`);
    clearSessionInfo();
    expect(readSessionInfo()).toBeNull();

    writeSessionInfo({ sessionId: 's1', bundleId: 'com.demo.app' });
    expect(fs.existsSync(sessionFile)).toBe(true);
    expect(readSessionInfo()).toEqual({ sessionId: 's1', bundleId: 'com.demo.app' });

    clearSessionInfo();
    expect(fs.existsSync(sessionFile)).toBe(false);
    expect(readSessionInfo()).toBeNull();
  });
});
