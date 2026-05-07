import fs from 'fs';
import path from 'path';
import os from 'os';
import { describe, expect, test } from 'bun:test';

import { rewriteIpaBundleIds } from '../src/config.js';

const DEV_RUNNER_BUNDLE_ID = 'com.iosuse.xcuidriver.xctrunner';
const DEV_XCTEST_BUNDLE_ID = 'com.iosuse.xcuidriver';

function createTestIpa(tmpDir) {
  const stagingDir = path.join(tmpDir, 'ipa-staging');
  const payloadDir = path.join(stagingDir, 'Payload');
  const appDir = path.join(payloadDir, 'IOSUseDriver-Runner.app');
  const xctestDir = path.join(appDir, 'PlugIns', 'IOSUseDriver.xctest');
  fs.mkdirSync(xctestDir, { recursive: true });

  fs.writeFileSync(path.join(appDir, 'Info.plist'), [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0"><dict>',
    '<key>CFBundleIdentifier</key><string>com.iosuse.xcuidriver.xctrunner</string>',
    '<key>CFBundleName</key><string>IOSUseDriver</string>',
    '</dict></plist>',
  ].join('\n'));

  fs.writeFileSync(path.join(xctestDir, 'Info.plist'), [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0"><dict>',
    '<key>CFBundleIdentifier</key><string>com.iosuse.xcuidriver</string>',
    '<key>CFBundleName</key><string>IOSUseDriver</string>',
    '</dict></plist>',
  ].join('\n'));

  const ipaPath = path.join(tmpDir, 'test-driver.ipa');
  const { execFileSync } = require('child_process');
  execFileSync('zip', ['-r', '-q', ipaPath, 'Payload'], { cwd: stagingDir });
  fs.rmSync(stagingDir, { recursive: true, force: true });
  return ipaPath;
}

function extractPlistFromIpa(ipaPath, plistRelPath) {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ipa-check-'));
  try {
    const { execFileSync } = require('child_process');
    execFileSync('unzip', ['-q', '-o', ipaPath, '-d', tmpDir], { stdio: 'pipe' });
    const fullPath = path.join(tmpDir, plistRelPath);
    return fs.readFileSync(fullPath, 'utf-8');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

describe('rewriteIpaBundleIds', () => {
  test('rewrites both runner and xctest bundle IDs', () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rewrite-test-'));
    try {
      const ipaPath = createTestIpa(tmpDir);
      const newRunnerId = 'com.ios-use.driver.testuser.xctrunner';
      const newXctestId = 'com.ios-use.driver.testuser';

      const outPath = rewriteIpaBundleIds(ipaPath, newRunnerId, newXctestId);
      expect(outPath).toContain('-rewritten.ipa');
      expect(fs.existsSync(outPath)).toBe(true);

      // Verify runner plist
      const runnerPlist = extractPlistFromIpa(outPath, 'Payload/IOSUseDriver-Runner.app/Info.plist');
      expect(runnerPlist).toContain(newRunnerId);
      expect(runnerPlist).not.toContain(DEV_RUNNER_BUNDLE_ID);

      // Verify xctest plist
      const xctestPlist = extractPlistFromIpa(outPath, 'Payload/IOSUseDriver-Runner.app/PlugIns/IOSUseDriver.xctest/Info.plist');
      expect(xctestPlist).toContain(newXctestId);
      expect(xctestPlist).not.toContain(DEV_XCTEST_BUNDLE_ID);

      // Cleanup
      fs.rmSync(outPath, { force: true });
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });

  test('does not touch plists that already have target bundle ID', () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rewrite-test-'));
    try {
      const ipaPath = createTestIpa(tmpDir);
      // Use the same IDs as dev — nothing should change
      const outPath = rewriteIpaBundleIds(ipaPath, DEV_RUNNER_BUNDLE_ID, DEV_XCTEST_BUNDLE_ID);
      expect(fs.existsSync(outPath)).toBe(true);

      const runnerPlist = extractPlistFromIpa(outPath, 'Payload/IOSUseDriver-Runner.app/Info.plist');
      expect(runnerPlist).toContain(DEV_RUNNER_BUNDLE_ID);

      fs.rmSync(outPath, { force: true });
    } finally {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
