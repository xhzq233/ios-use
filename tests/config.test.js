import fs from 'fs';
import path from 'path';
import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test';

const execSyncMock = mock();
const execFileSyncMock = mock();
const spawnMock = mock();
const resolveDeviceMock = mock();
const formatDeviceLabelMock = mock();
const loggerInfoMock = mock();
const loggerSuccessMock = mock();
const loggerWarnMock = mock();
const loggerErrorMock = mock();
const loggerDebugMock = mock();

mock.module('child_process', () => ({
  execSync: execSyncMock,
  execFileSync: execFileSyncMock,
  spawn: spawnMock,
}));

mock.module('../src/device.js', () => ({
  resolveDevice: resolveDeviceMock,
  formatDeviceLabel: formatDeviceLabelMock,
}));

mock.module('../src/utils/logger.js', () => ({
  logger: {
    info: loggerInfoMock,
    success: loggerSuccessMock,
    warn: loggerWarnMock,
    error: loggerErrorMock,
    debug: loggerDebugMock,
  },
}));

import os from 'os';

const configPath = path.resolve(os.homedir(), '.ios-use', 'config.json');

function backupConfig() {
  if (fs.existsSync(configPath)) return fs.readFileSync(configPath, 'utf-8');
  return null;
}

function restoreConfig(saved) {
  if (saved !== null) fs.writeFileSync(configPath, saved);
  else if (fs.existsSync(configPath)) fs.unlinkSync(configPath);
}

describe('config helpers', () => {
  let configModule;
  let originalHome;
  let tempHome;
  let savedConfig;

  beforeEach(async () => {
    savedConfig = backupConfig();
    if (fs.existsSync(configPath)) fs.unlinkSync(configPath);

    originalHome = process.env.HOME;
    tempHome = path.resolve(process.cwd(), `.tmp-home-${Date.now()}`);
    fs.mkdirSync(tempHome, { recursive: true });
    process.env.HOME = tempHome;

    execSyncMock.mockReset();
    execFileSyncMock.mockReset();
    spawnMock.mockReset();
    resolveDeviceMock.mockReset();
    formatDeviceLabelMock.mockReset();
    loggerInfoMock.mockReset();
    loggerSuccessMock.mockReset();
    loggerWarnMock.mockReset();
    loggerErrorMock.mockReset();
    loggerDebugMock.mockReset();

    resolveDeviceMock.mockReturnValue({ udid: 'udid-1', name: 'test-device', version: '18.3.2' });
    formatDeviceLabelMock.mockReturnValue('test-device | iOS 18.3.2 | UDID: udid-1');

    configModule = await import(`../src/config.js?test=${Date.now()}`);
  });

  afterEach(() => {
    restoreConfig(savedConfig);
    if (tempHome && fs.existsSync(tempHome)) {
      fs.rmSync(tempHome, { recursive: true, force: true });
    }
    process.env.HOME = originalHome;

    const altsignBin = path.resolve(process.cwd(), 'altsign-cli', 'altsign-cli');
    if (fs.existsSync(altsignBin)) {
      fs.unlinkSync(altsignBin);
    }
  });

  test('saveDeviceSigningConfig persists per-device config', () => {
    configModule.saveDeviceSigningConfig('udid-1', {
      bundleId: 'com.iosuse.xcuidriver.xctrunner',
    });

    const parsed = JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    const cfg = parsed.devices['udid-1'];
    expect(cfg.bundleId).toBe('com.iosuse.xcuidriver.xctrunner');
    expect(cfg.port).toBe('8100');
  });

  test('getDeviceSigningConfig returns saved config', () => {
    configModule.saveDeviceSigningConfig('udid-1', {
      bundleId: 'io.demo.wda',
      port: 8200,
    });

    expect(configModule.getDeviceSigningConfig('udid-1')).toEqual({
      bundleId: 'io.demo.wda',
      port: '8200',
    });
  });

  test('getDeviceSigningConfig throws when no config found', () => {
    expect(() => configModule.getDeviceSigningConfig('missing-udid')).toThrow('No signing config found');
  });

  test('getPrebuiltIPAPath resolves to local asset', () => {
    const ipaPath = configModule.getPrebuiltIPAPath();
    expect(ipaPath).toContain('driver.ipa');
  });

  test('configureDeviceSigning works without apple-id when altsign-cli has cached session', async () => {
    const altsignDir = path.resolve(process.cwd(), 'altsign-cli');
    const altsignBin = path.join(altsignDir, 'altsign-cli');
    if (!fs.existsSync(altsignBin)) {
      fs.mkdirSync(altsignDir, { recursive: true });
      fs.writeFileSync(altsignBin, '#!/bin/sh\necho mock');
      fs.chmodSync(altsignBin, 0o755);
    }

    execFileSyncMock.mockImplementation((file, args) => {
      if (file === 'unzip') {
        const destIdx = args.indexOf('-d');
        if (destIdx !== -1) {
          const payloadDir = path.join(args[destIdx + 1], 'Payload');
          fs.mkdirSync(payloadDir, { recursive: true });
          const appDir = path.join(payloadDir, 'XCUIDriverRunner.app');
          fs.mkdirSync(appDir, { recursive: true });
        }
        return '';
      }
      return '';
    });

    spawnMock.mockImplementation((command, args) => {
      let stderrHandler = null;
      return {
        stdout: { on: mock() },
        stderr: { on: (event, handler) => { if (event === 'data') stderrHandler = handler; } },
        on: (event, handler) => {
          if (event === 'close') {
            if (args[0] === 'list') {
              stderrHandler?.('Using cached session for test@example.com (no credentials needed)');
            }
            if (args[0] === 'sign') {
              const idx = args.indexOf('--output');
              if (idx !== -1) fs.writeFileSync(args[idx + 1], 'signed');
            }
            handler(0);
          }
        },
      };
    });

    await configModule.configureDeviceSigning({ udid: 'udid-1' });
    expect(loggerSuccessMock).toHaveBeenCalledWith('Device config complete! Run `ios-use session start --bundle-id <app>` to start.');
  });

  test('configureDeviceSigning signs with apple-id and installs driver', async () => {
    const altsignDir = path.resolve(process.cwd(), 'altsign-cli');
    const altsignBin = path.join(altsignDir, 'altsign-cli');
    if (!fs.existsSync(altsignBin)) {
      fs.mkdirSync(altsignDir, { recursive: true });
      fs.writeFileSync(altsignBin, '#!/bin/sh\necho mock');
      fs.chmodSync(altsignBin, 0o755);
    }

    execFileSyncMock.mockImplementation((file, args) => {
      if (file === 'unzip') {
        const destIdx = args.indexOf('-d');
        if (destIdx !== -1) {
          const payloadDir = path.join(args[destIdx + 1], 'Payload');
          fs.mkdirSync(payloadDir, { recursive: true });
          const appDir = path.join(payloadDir, 'XCUIDriverRunner.app');
          fs.mkdirSync(appDir, { recursive: true });
        }
        return '';
      }
      return '';
    });

    const spawnCalls = [];
    spawnMock.mockImplementation((command, args) => {
      spawnCalls.push([command, args]);
      return {
        stdout: { on: mock() },
        stderr: { on: mock() },
        on: (event, handler) => {
          if (event === 'close') {
            if (args[0] === 'sign') {
              const outputMatch = args.indexOf('--output');
              if (outputMatch !== -1) fs.writeFileSync(args[outputMatch + 1], 'signed');
            }
            handler(0);
          }
        },
      };
    });

    await configModule.configureDeviceSigning({
      udid: 'udid-1',
      appleId: 'test@example.com',
      password: 'secret',
    });

    const signCall = spawnCalls.find(c => c[0]?.endsWith('altsign-cli') && c[1]?.[0] === 'sign');
    expect(signCall).toBeDefined();
    expect(signCall[1]).toContain('--apple-id');
    expect(signCall[1]).toContain('test@example.com');

    const installCall = spawnCalls.find(c => c[0] === 'xcrun' && c[1]?.includes('install'));
    expect(installCall).toBeDefined();

    expect(loggerSuccessMock).toHaveBeenCalledWith('Device config complete! Run `ios-use session start --bundle-id <app>` to start.');
  });

  test('configureDeviceSigning uses dynamic bundle ID from cached apple id', async () => {
    const altsignDir = path.resolve(process.cwd(), 'altsign-cli');
    const altsignBin = path.join(altsignDir, 'altsign-cli');
    if (!fs.existsSync(altsignBin)) {
      fs.mkdirSync(altsignDir, { recursive: true });
      fs.writeFileSync(altsignBin, '#!/bin/sh\necho mock');
      fs.chmodSync(altsignBin, 0o755);
    }

    execFileSyncMock.mockImplementation((file, args) => {
      if (file === 'unzip') {
        const destIdx = args.indexOf('-d');
        if (destIdx !== -1) {
          const payloadDir = path.join(args[destIdx + 1], 'Payload');
          fs.mkdirSync(payloadDir, { recursive: true });
          const appDir = path.join(payloadDir, 'XCUIDriverRunner.app');
          fs.mkdirSync(appDir, { recursive: true });
        }
        return '';
      }
      return '';
    });

    const spawnCalls = [];
    spawnMock.mockImplementation((command, args) => {
      spawnCalls.push([command, args]);
      let stderrHandler = null;
      return {
        stdout: { on: mock() },
        stderr: { on: (event, handler) => { if (event === 'data') stderrHandler = handler; } },
        on: (event, handler) => {
          if (event === 'close') {
            if (args[0] === 'list') {
              stderrHandler?.('Using cached session for user@test.com');
            }
            if (args[0] === 'sign') {
              const outputMatch = args.indexOf('--output');
              if (outputMatch !== -1) fs.writeFileSync(args[outputMatch + 1], 'signed');
            }
            handler(0);
          }
        },
      };
    });

    await configModule.configureDeviceSigning({ udid: 'udid-1' });

    const signCall = spawnCalls.find(c => c[1]?.[0] === 'sign');
    expect(signCall).toBeDefined();
    expect(signCall[1]).toContain('com.ios-use.driver.user-test-com.xctrunner');
  });
});
