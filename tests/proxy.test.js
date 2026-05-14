import { afterAll, afterEach, beforeEach, describe, expect, mock, spyOn, test } from 'bun:test';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { proxyStop, setProxyTestOverrides } from '../src/commands/proxy.ts';
import { logger } from '../src/utils/logger.js';

const testHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ios-use-proxy-test-'));
const iosUseHome = path.join(testHome, '.ios-use');
const stateDir = path.join(iosUseHome, 'state');
const proxyStateFile = path.join(stateDir, 'proxy-session.json');

function writeProxyState(state) {
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(proxyStateFile, JSON.stringify(state, null, 2) + '\n');
}

function readProxyStateFile() {
  return JSON.parse(fs.readFileSync(proxyStateFile, 'utf-8'));
}

describe('proxy commands', () => {
  let runFlowFileMock;
  let loggerInfoSpy;
  let loggerWarnSpy;
  let loggerSuccessSpy;

  beforeEach(() => {
    fs.rmSync(iosUseHome, { recursive: true, force: true });
    runFlowFileMock = mock(async () => undefined);
    setProxyTestOverrides({ iosUseHome, flowRunner: runFlowFileMock });
    loggerInfoSpy = spyOn(logger, 'info').mockImplementation(() => {});
    loggerWarnSpy = spyOn(logger, 'warn').mockImplementation(() => {});
    loggerSuccessSpy = spyOn(logger, 'success').mockImplementation(() => {});
  });

  afterEach(() => {
    setProxyTestOverrides({ iosUseHome: null, flowRunner: null });
    loggerInfoSpy.mockRestore();
    loggerWarnSpy.mockRestore();
    loggerSuccessSpy.mockRestore();
  });

  afterAll(() => {
    fs.rmSync(testHome, { recursive: true, force: true });
  });

  test('proxyStop clears device proxy before marking state stopped', async () => {
    writeProxyState({
      sessionId: 'proxy-1',
      status: 'running',
      startedAt: 1,
      udid: 'state-udid',
      flowFile: '/tmp/proxy.flow',
      mitmdumpPid: 12345,
      mitmdumpPort: 9080,
    });
    const client = {
      terminateApp: mock(async () => undefined),
      activateApp: mock(async () => undefined),
    };

    await proxyStop(client, {});

    expect(client.terminateApp).toHaveBeenCalledWith('com.apple.Preferences');
    expect(client.activateApp).toHaveBeenCalledWith('com.apple.Preferences');
    expect(runFlowFileMock).toHaveBeenCalled();
    const state = readProxyStateFile();
    expect(state.status).toBe('stopped');
    expect(state.stoppedAt).toBeNumber();
    expect(state.mitmdumpPid).toBeUndefined();
    expect(loggerSuccessSpy).toHaveBeenCalledWith('Proxy stopped.');
  });

  test('proxyStop fails with manual cleanup guidance when Wi-Fi proxy clear flow fails', async () => {
    writeProxyState({
      sessionId: 'proxy-1',
      status: 'running',
      startedAt: 1,
      udid: 'state-udid',
      flowFile: '/tmp/proxy.flow',
      mitmdumpPid: 12345,
      mitmdumpPort: 9080,
    });
    const client = {
      terminateApp: mock(async () => { throw new Error('flow failed'); }),
      activateApp: mock(async () => undefined),
    };

    await expect(proxyStop(client, { udid: 'test-udid' })).rejects.toThrow('Manually disable Wi-Fi proxy');

    expect(client.activateApp).not.toHaveBeenCalled();
    expect(readProxyStateFile().status).toBe('running');
    expect(loggerWarnSpy.mock.calls.flat().join(' ')).toContain('Failed to clear Wi-Fi proxy via flow');
  });
});
