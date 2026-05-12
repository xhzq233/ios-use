import { describe, test, expect, beforeEach, afterEach } from 'bun:test';
import fs from 'fs';
import path from 'path';
import { clearSessionInfo, readSessionInfo, writeSessionInfo } from '../src/session.js';
import { SESSION_FILE } from '../src/utils/paths.js';

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

  test('readSessionInfo returns null when file missing', () => {
    clearSessionInfo();
    expect(readSessionInfo()).toBeNull();
  });
});
