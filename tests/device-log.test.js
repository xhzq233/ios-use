import { afterEach, describe, expect, mock, test } from 'bun:test';
import { clearBuffer, fetchOslog, configureOslog } from '../src/device-log/oslog.ts';

// ── clearBuffer ──

describe('clearBuffer', () => {
  test('returns 0 for empty buffer', () => {
    // Clear twice to ensure buffer starts empty
    clearBuffer();
    expect(clearBuffer()).toBe(0);
  });
});

// ── fetchOslog real device (mock collectSyslog) ──

describe('fetchOslog', () => {
  afterEach(() => {
    clearBuffer();
    configureOslog({ simulator: false });
    mock.restore();
  });

  test('collects lines from real device and deduplicates', async () => {
    // Push some data into the buffer by faking a syslog collect
    const collectSyslogMock = mock(async (_udid, _timeoutMs, _signal) => ['line one', 'line two']);
    mock.module('../src/device-log/syslog-relay.js', () => ({
      collectSyslog: collectSyslogMock,
    }));

    // Reset buffer
    clearBuffer();
    configureOslog({ simulator: false });

    const result = await fetchOslog({ udid: 'test-udid' });
    expect(result.total).toBe(2);
    expect(result.matched).toBe(2);
    expect(result.content).toBe('line one\nline two\n');
  });

  test('filters by pattern with regex', async () => {
    const collectSyslogMock = mock(async () => ['error: disk full', 'info: ok', 'error: timeout']);
    mock.module('../src/device-log/syslog-relay.js', () => ({
      collectSyslog: collectSyslogMock,
    }));

    clearBuffer();
    configureOslog({ simulator: false });

    const result = await fetchOslog({ udid: 'test-udid', pattern: 'error' });
    expect(result.matched).toBe(2);
    expect(result.content).toContain('error: disk full');
    expect(result.content).toContain('error: timeout');
    expect(result.content).not.toContain('info: ok');
  });

  test('filters by pattern with case-insensitive flag', async () => {
    const collectSyslogMock = mock(async () => ['Error: disk full', 'info: ok']);
    mock.module('../src/device-log/syslog-relay.js', () => ({
      collectSyslog: collectSyslogMock,
    }));

    clearBuffer();
    configureOslog({ simulator: false });

    const result = await fetchOslog({ udid: 'test-udid', pattern: 'error', flags: 'i' });
    expect(result.matched).toBe(1);
    expect(result.content).toContain('Error: disk full');
  });

  test('filters by bundleId (process name match)', async () => {
    const collectSyslogMock = mock(async () => [
      'May 11 15:30:45 iPhone Preferences(Preferences)[123] <Notice>: settings opened',
      'May 11 15:30:46 iPhone SpringBoard(SpringBoard)[456] <Notice>: app launched',
      'May 11 15:30:47 iPhone Preferences(Preferences)[123] <Notice>: settings closed',
    ]);
    mock.module('../src/device-log/syslog-relay.js', () => ({
      collectSyslog: collectSyslogMock,
    }));

    clearBuffer();
    configureOslog({ simulator: false });

    const result = await fetchOslog({ udid: 'test-udid', bundleId: 'Preferences' });
    expect(result.matched).toBe(2);
    expect(result.content).toContain('settings opened');
    expect(result.content).toContain('settings closed');
    expect(result.content).not.toContain('app launched');
  });

  test('combines bundleId and pattern filters', async () => {
    const collectSyslogMock = mock(async () => [
      'May 11 15:30:45 iPhone Preferences(Preferences)[123] <Notice>: settings opened',
      'May 11 15:30:46 iPhone SpringBoard(SpringBoard)[456] <Notice>: error in springboard',
      'May 11 15:30:47 iPhone Preferences(Preferences)[123] <Error>: settings error',
      'May 11 15:30:48 iPhone Preferences(Preferences)[123] <Notice>: settings closed',
    ]);
    mock.module('../src/device-log/syslog-relay.js', () => ({
      collectSyslog: collectSyslogMock,
    }));

    clearBuffer();
    configureOslog({ simulator: false });

    const result = await fetchOslog({ udid: 'test-udid', bundleId: 'Preferences', pattern: 'error' });
    expect(result.matched).toBe(1);
    expect(result.content).toContain('settings error');
    expect(result.content).not.toContain('settings opened');
    expect(result.content).not.toContain('springboard');
  });

  test('deduplicates repeated lines across polls', async () => {
    const collectSyslogMock = mock(async () => ['line one', 'line two']);
    mock.module('../src/device-log/syslog-relay.js', () => ({
      collectSyslog: collectSyslogMock,
    }));

    clearBuffer();
    configureOslog({ simulator: false });

    // First poll: adds 2 lines
    const r1 = await fetchOslog({ udid: 'test-udid' });
    expect(r1.total).toBe(2);
    // Second poll returns same lines — buffer doesn't grow
    const r2 = await fetchOslog({ udid: 'test-udid' });
    expect(r2.total).toBe(2); // no new unique lines added
  });

  test('keeps buffers isolated per udid', async () => {
    const collectSyslogMock = mock(async (udid) => [`${udid}-line`]);
    mock.module('../src/device-log/syslog-relay.js', () => ({
      collectSyslog: collectSyslogMock,
    }));

    configureOslog({ simulator: false, udid: 'device-a' });
    clearBuffer();
    configureOslog({ simulator: false, udid: 'device-b' });
    clearBuffer();

    configureOslog({ simulator: false, udid: 'device-a' });
    const a = await fetchOslog({ udid: 'device-a' });
    expect(a.content).toContain('device-a-line');

    configureOslog({ simulator: false, udid: 'device-b' });
    const b = await fetchOslog({ udid: 'device-b' });
    expect(b.content).toContain('device-b-line');
    expect(b.content).not.toContain('device-a-line');
  });

  test('passes abort signal through to collectSyslog', async () => {
    let receivedSignal = undefined;
    const collectSyslogMock = mock(async (_udid, _timeoutMs, signal) => {
      receivedSignal = signal;
      return [];
    });
    mock.module('../src/device-log/syslog-relay.js', () => ({
      collectSyslog: collectSyslogMock,
    }));

    clearBuffer();
    configureOslog({ simulator: false });

    const ctrl = new AbortController();
    await fetchOslog({ udid: 'test-udid', signal: ctrl.signal });
    expect(receivedSignal).toBe(ctrl.signal);
  });

  test('simulator log collection uses simctl path', async () => {
    const simLogMock = mock(async (_udid, _opts) => ['simulator log line']);
    mock.module('../src/device-log/syslog-relay.js', () => ({
      collectSyslog: mock(async () => []),
    }));
    mock.module('../src/device-log/simulator-log.js', () => ({
      collectSimulatorLog: simLogMock,
    }));

    clearBuffer();
    configureOslog({ simulator: true, udid: 'sim-udid' });

    const result = await fetchOslog({ udid: 'sim-udid' });
    expect(result.total).toBe(1);
    expect(result.content).toContain('simulator log line');
  });

  test('simulator log collection forwards bundleId for simctl predicate filtering', async () => {
    let receivedOpts = undefined;
    const simLogMock = mock(async (_udid, opts) => {
      receivedOpts = opts;
      return ['May 11 15:30:45 Mac Preferences[123] <Notice>: settings opened'];
    });
    mock.module('../src/device-log/syslog-relay.js', () => ({
      collectSyslog: mock(async () => []),
    }));
    mock.module('../src/device-log/simulator-log.js', () => ({
      collectSimulatorLog: simLogMock,
    }));

    clearBuffer();
    configureOslog({ simulator: true, udid: 'sim-udid' });

    const result = await fetchOslog({ udid: 'sim-udid', bundleId: 'Preferences' });
    expect(receivedOpts).toMatchObject({ bundleId: 'Preferences' });
    expect(result.matched).toBe(1);
  });
});
