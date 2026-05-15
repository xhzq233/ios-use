import { afterAll, afterEach, beforeEach, describe, expect, mock, spyOn, test } from 'bun:test';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { proxyStart, proxyStop, setProxyTestOverrides } from '../src/commands/proxy.ts';
import { logger } from '../src/utils/logger.js';

const testHome = fs.mkdtempSync(path.join(os.tmpdir(), 'ios-use-proxy-test-'));
const iosUseHome = path.join(testHome, '.ios-use');
const stateDir = path.join(iosUseHome, 'state');
const proxyStateFile = path.join(stateDir, 'proxy-session.json');
const mitmproxyDir = path.join(testHome, '.mitmproxy');
const fakeCert = [
  '-----BEGIN CERTIFICATE-----',
  'AA==',
  '-----END CERTIFICATE-----',
  '',
].join('\n');

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
    fs.rmSync(mitmproxyDir, { recursive: true, force: true });
    fs.mkdirSync(mitmproxyDir, { recursive: true });
    fs.writeFileSync(path.join(mitmproxyDir, 'mitmproxy-ca-cert.pem'), fakeCert);
    runFlowFileMock = mock(async () => undefined);
    setProxyTestOverrides({ iosUseHome, flowRunner: runFlowFileMock, mitmproxyDir });
    loggerInfoSpy = spyOn(logger, 'info').mockImplementation(() => {});
    loggerWarnSpy = spyOn(logger, 'warn').mockImplementation(() => {});
    loggerSuccessSpy = spyOn(logger, 'success').mockImplementation(() => {});
  });

  afterEach(() => {
    setProxyTestOverrides({
      iosUseHome: null,
      flowRunner: null,
      lanInfoDetector: null,
      deviceReachVerifier: null,
      mitmdumpStarter: null,
      mitmproxyDir: null,
    });
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

  test('proxyStart uses Wi-Fi interface by default and passes server/port as flow vars', async () => {
    const calls = [];
    setProxyTestOverrides({
      iosUseHome,
      flowRunner: mock(async (_client, _file, _ctx, vars) => { calls.push(['flow', vars]); }),
      mitmproxyDir,
      lanInfoDetector: mock((interfaceName) => {
        calls.push(['lan', interfaceName ?? 'default']);
        return { interface: interfaceName ?? 'en0', macLanIp: interfaceName ? '10.0.0.6' : '192.168.1.10' };
      }),
      deviceReachVerifier: mock(async () => { calls.push(['probe']); }),
      mitmdumpStarter: mock(async () => {
        calls.push(['mitmdump']);
        return { pid: 23456, kill: mock(() => true), once: mock(() => undefined), on: mock(() => undefined) };
      }),
    });

    await proxyStart({ terminateApp: mock(async () => undefined), activateApp: mock(async () => undefined) }, { udid: 'sim-udid' });

    expect(calls.map(c => c[0])).toEqual(['lan', 'probe', 'mitmdump', 'flow']);
    expect(calls[0][1]).toBe('default');
    expect(calls[3][1]).toEqual({ server: '192.168.1.10', port: '9080' });
    const state = readProxyStateFile();
    expect(state.network).toEqual({ interface: 'en0', macLanIp: '192.168.1.10' });
    expect(state.status).toBe('running');
  });

  test('proxyStart honors requested interface', async () => {
    const lanInfo = mock((interfaceName) => ({ interface: interfaceName, macLanIp: '10.0.0.6' }));
    setProxyTestOverrides({
      iosUseHome,
      flowRunner: runFlowFileMock,
      mitmproxyDir,
      lanInfoDetector: lanInfo,
      deviceReachVerifier: mock(async () => undefined),
      mitmdumpStarter: mock(async () => ({ pid: 23457, kill: mock(() => true), once: mock(() => undefined), on: mock(() => undefined) })),
    });

    await proxyStart({ terminateApp: mock(async () => undefined), activateApp: mock(async () => undefined) }, { udid: 'sim-udid', interfaceName: 'en6' });

    expect(lanInfo).toHaveBeenCalledWith('en6');
    expect(readProxyStateFile().network).toEqual({ interface: 'en6', macLanIp: '10.0.0.6' });
  });

  test('proxyStart records CA readiness by UDID and fingerprint', async () => {
    fs.mkdirSync(stateDir, { recursive: true });
    const fingerprint = '6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d';
    fs.writeFileSync(path.join(stateDir, 'proxy-ca.json'), JSON.stringify({
      'sim-udid': { fingerprint, installedAt: 1 },
    }));
    setProxyTestOverrides({
      iosUseHome,
      flowRunner: runFlowFileMock,
      mitmproxyDir,
      lanInfoDetector: mock(() => ({ interface: 'en0', macLanIp: '192.168.1.10' })),
      deviceReachVerifier: mock(async () => undefined),
      mitmdumpStarter: mock(async () => ({ pid: 23458, kill: mock(() => true), once: mock(() => undefined), on: mock(() => undefined) })),
    });

    await proxyStart({ terminateApp: mock(async () => undefined), activateApp: mock(async () => undefined) }, { udid: 'sim-udid' });

    expect(readProxyStateFile().caInstalled).toBe(true);
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
