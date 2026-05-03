import { execFileSync, spawn } from 'child_process';
import type { ChildProcess } from 'child_process';
import fs from 'fs';
import { getDeviceSigningConfig } from './config.js';
import { DriverClient } from './driver-client/index.js';
import { formatDeviceLabel, resolveDefaultDevice, resolveDevice } from './device.js';
import { logger } from './utils/logger.js';
import {
  DRIVER_LOG_FILE,
  SESSION_FILE,
  ensureLogDir,
  ensureStateDir,
} from './utils/paths.js';

const DEFAULT_PORT = 8100;
const DRIVER_HOST = '127.0.0.1';
const DEVICECTL_LOG = DRIVER_LOG_FILE;

const delay = (ms: number) => new Promise<void>(r => setTimeout(r, ms));
const shellQuote = (value: string) => `'${value.replace(/'/g, `'\''`)}'`;
const nextSessionId = () => `session-${Date.now()}`;
const DRIVER_RUNNER_EXECUTABLE = 'XCUIDriverRunner-Runner';

export interface SessionInfo {
  sessionId: string;
  udid: string;
  bundleId?: string;
  port?: number;
  deviceName?: string;
  deviceVersion?: string;
  deviceType?: 'real' | 'simulator';
  createdAt: number;
}

interface StartXctestRunnerOpts {
  verbose?: boolean;
}

interface CreateClientOpts {
  port?: number;
  udid?: string;
  verbose?: boolean;
  directTcp?: boolean;
  ownsSession?: boolean;
  sessionId?: string;
  bundleId?: string;
}

interface WithAutoSessionOpts {
  bundleId?: string;
  udid?: string;
  verbose?: boolean;
}

interface StartSessionOpts {
  bundleId?: string;
  udid?: string;
  verbose?: boolean;
}

interface CreateDriverFromSessionOpts {
  verbose?: boolean;
}

interface IsDriverAliveOpts {
  verbose?: boolean;
}

function disconnectClient(client: DriverClient | null | undefined): void {
  try {
    client?.disconnect();
  } catch {}
}

function listDeviceProcesses(udid: string): Array<{ executable?: string; processIdentifier?: number }> {
  try {
    const output = execFileSync(
      'xcrun',
      ['devicectl', 'device', 'info', 'processes', '--device', udid, '--quiet', '--json-output', '-'],
      { encoding: 'utf8', stdio: 'pipe', timeout: 5000 },
    );
    const parsed = JSON.parse(output);
    const processes = parsed?.result?.runningProcesses ?? parsed?.result?.processTokens ?? [];
    return Array.isArray(processes) ? processes : [];
  } catch {
    return [];
  }
}

function terminateDeviceProcessesByExecutable(udid: string, executableName: string): boolean {
  let terminated = false;
  for (const processInfo of listDeviceProcesses(udid)) {
    const executable = String(processInfo?.executable || '');
    const basename = executable.split('/').pop() || '';
    const pid = processInfo?.processIdentifier;
    if (basename !== executableName || !pid) continue;
    try {
      execFileSync(
        'xcrun',
        ['devicectl', 'device', 'process', 'terminate', '--device', udid, '--pid', String(pid), '--kill'],
        { stdio: 'pipe', timeout: 5000 },
      );
      terminated = true;
    } catch {
      // Process may already be gone.
    }
  }
  return terminated;
}

function startXctestRunner(udid: string, { verbose = false }: StartXctestRunnerOpts = {}): ChildProcess {
  const { bundleId: runnerBundleId } = getDeviceSigningConfig(udid);

  if (terminateDeviceProcessesByExecutable(udid, DRIVER_RUNNER_EXECUTABLE) && verbose) {
    logger.info('Terminated existing driver runner process');
  }

  const args = [
    'devicectl', 'device', 'process', 'launch',
    '--device', udid,
    '--terminate-existing',
    '--console',
    runnerBundleId,
  ];

  if (verbose) {
    logger.info(`Running: xcrun ${args.join(' ')}`);
  }
  ensureLogDir();
  fs.writeFileSync(DEVICECTL_LOG, '');
  const shellCommand = `exec ${['xcrun', ...args].map(shellQuote).join(' ')} >> ${shellQuote(DEVICECTL_LOG)} 2>&1`;
  if (verbose) {
    logger.info(`Driver console log: ${DEVICECTL_LOG}`);
  }
  const proc = spawn('/bin/sh', ['-lc', shellCommand], {
    stdio: 'ignore',
    detached: true,
  });
  proc.unref();

  proc.on('error', (err: Error) => logger.warn(`devicectl error: ${err.message}`));
  return proc;
}

async function createClient({
  port = DEFAULT_PORT,
  udid,
  verbose = false,
  directTcp = false,
  ownsSession = true,
  sessionId,
  bundleId,
}: CreateClientOpts = {}): Promise<DriverClient> {
  const client = new DriverClient({
    host: DRIVER_HOST,
    port,
    udid,
    directTcp,
    verbose,
    ownsSession,
    sessionId,
    bundleId,
  });
  await client.connect();
  return client;
}

async function createClientFromSession(
  info: SessionInfo,
  { verbose = false, ownsSession = false }: { verbose?: boolean; ownsSession?: boolean } = {},
): Promise<DriverClient> {
  return await createClient({
    port: info.port || DEFAULT_PORT,
    udid: info.udid,
    verbose,
    directTcp: info.deviceType === 'simulator',
    ownsSession,
    sessionId: info.sessionId,
    bundleId: info.bundleId,
  });
}

export function readSessionInfo(): SessionInfo | null {
  try {
    return JSON.parse(fs.readFileSync(SESSION_FILE, 'utf-8'));
  } catch {
    return null;
  }
}

export function writeSessionInfo(info: SessionInfo): void {
  ensureStateDir();
  const tmp = SESSION_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(info));
  fs.renameSync(tmp, SESSION_FILE);
}

export function clearSessionInfo(): void {
  try { fs.unlinkSync(SESSION_FILE); } catch {}
}

function buildSessionInfo(info: {
  sessionId?: string;
  udid: string;
  bundleId?: string;
  deviceName?: string;
  deviceVersion?: string;
  deviceType?: 'real' | 'simulator';
  port?: number;
  createdAt?: number;
}): SessionInfo {
  return {
    sessionId: info.sessionId ?? nextSessionId(),
    udid: info.udid,
    bundleId: info.bundleId,
    deviceName: info.deviceName,
    deviceVersion: info.deviceVersion,
    deviceType: info.deviceType,
    port: info.port ?? DEFAULT_PORT,
    createdAt: info.createdAt ?? Date.now(),
  };
}

function normalizeDeviceError(error: unknown, udid: string): Error {
  const message = (error instanceof Error ? error.message : String(error)) || String(error);
  if (message.includes('No signing config found for device')) {
    return new Error(`${message} Configure the device first, then retry session/app/flow commands.`);
  }
  if (message.includes('not found via usbmux')) {
    return new Error(
      `Device ${udid} not found via USB (usbmux). WiFi-only connections are not supported for TCP communication.
`
      + '  → Connect the device via USB cable and retry.',
    );
  }
  if (message.includes('Tunnel registry port not found')) {
    return new Error(`${message}
  → Try: 1) re-plug the USB cable, or 2) run \`ios-use config --udid ${udid}\`.`);
  }
  return error instanceof Error ? error : new Error(String(error));
}

function isSessionBroken(error: unknown): boolean {
  const message = (error instanceof Error ? error.message : String(error)).toLowerCase();
  return [
    'no active session',
    'not connected',
    'socket closed',
    'connection disconnected',
    'econnrefused',
    'connect timeout',
    'broken pipe',
  ].some(fragment => message.includes(fragment));
}

async function isDriverAlive(info: SessionInfo | null, { verbose = false }: IsDriverAliveOpts = {}): Promise<boolean> {
  if (!info?.udid) return false;
  let client: DriverClient | null = null;
  try {
    client = await createClientFromSession(info, { verbose, ownsSession: false });
    return true;
  } catch {
    return false;
  } finally {
    disconnectClient(client);
  }
}

function persistSession(info: SessionInfo): SessionInfo {
  writeSessionInfo(info);
  return info;
}

export async function withAutoSession<T>(opts: WithAutoSessionOpts, fn: (driver: DriverClient) => Promise<T>): Promise<T> {
  const info = readSessionInfo();
  const requestedBundleId = opts.bundleId;
  const requestedUdid = opts.udid;
  const verbose = opts.verbose || false;
  const fallbackUdid = requestedUdid || info?.udid;
  const canRecreateDeviceSession = !requestedBundleId && !info?.bundleId && !!info?.sessionId && !!fallbackUdid;

  if (info?.sessionId) {
    const udidMatch = !requestedUdid || requestedUdid === info.udid;

    if (udidMatch) {
      let client: DriverClient | null = null;
      try {
        client = await createClientFromSession(info, { verbose, ownsSession: false });
        if (requestedBundleId && requestedBundleId !== info.bundleId) {
          logger.info(`Switching app to ${requestedBundleId}`);
          await client.activateApp(requestedBundleId);
          persistSession({ ...info, bundleId: requestedBundleId });
        }

        opts.bundleId = requestedBundleId || info.bundleId;
        return await fn(client);
      } catch (error) {
        if (isSessionBroken(error)) {
          logger.warn('Existing session became unconnected, clearing session info');
          clearSessionInfo();
        } else {
          throw error;
        }
      } finally {
        disconnectClient(client);
      }
    }

    clearSessionInfo();
  }

  if (!opts.bundleId && !canRecreateDeviceSession) {
    throw new Error('No active session found. Please pass --bundle-id or run `ios-use session start`.');
  }

  const device = fallbackUdid ? resolveDevice(fallbackUdid) : await resolveDefaultDevice();
  logger.info(`${opts.udid ? 'Using requested device' : 'Using default device'}: ${formatDeviceLabel(device)}`);
  if (opts.bundleId) {
    logger.info(`Creating session for bundleId=${opts.bundleId}`);
  } else {
    logger.info('Recreating device session');
  }

  const client = await createClient({
    port: DEFAULT_PORT,
    udid: device.udid,
    verbose,
    directTcp: device.type === 'simulator',
    ownsSession: true,
  });

  try {
    await client.createSession(opts.bundleId);
    const sessionInfo = persistSession(buildSessionInfo({
      sessionId: client.sessionId,
      udid: device.udid,
      bundleId: opts.bundleId,
      deviceName: device.name,
      deviceVersion: device.version,
      deviceType: device.type,
      port: DEFAULT_PORT,
    }));
    logger.info(`Session created: ${sessionInfo.sessionId.substring(0, 8)}...`);
    return await fn(client);
  } finally {
    disconnectClient(client);
  }
}

function logSessionReady(bundleId: string | undefined, sessionId: string): void {
  if (bundleId) {
    logger.success(`Session ready: ${sessionId.substring(0, 8)}...`);
  } else {
    logger.success(`Device session ready: ${sessionId.substring(0, 8)}...`);
  }
  logger.info('Run `ios-use session stop` to end the session.');
}

function saveReadySession(client: DriverClient, device: { udid: string; name: string; version: string; type: 'real' | 'simulator' }, bundleId?: string): SessionInfo {
  return persistSession(buildSessionInfo({
    sessionId: client.sessionId,
    udid: device.udid,
    bundleId,
    deviceName: device.name,
    deviceVersion: device.version,
    deviceType: device.type,
    port: DEFAULT_PORT,
  }));
}

export async function startSession(opts: StartSessionOpts): Promise<void> {
  const bundleId = opts.bundleId;
  const verbose = opts.verbose || false;

  const device = opts.udid ? resolveDevice(opts.udid) : await resolveDefaultDevice();
  const isSimulator = device.type === 'simulator';
  const existingInfo = readSessionInfo();
  const hasReachableDriver = !!(existingInfo && existingInfo.udid === device.udid && await isDriverAlive(existingInfo, { verbose }));
  if (existingInfo && !hasReachableDriver) clearSessionInfo();

  logger.info(`Starting session${bundleId ? ` for bundleId=${bundleId}` : ' (device session)'}`);
  logger.info(`${opts.udid ? 'Using requested device' : 'Using default device'}: ${formatDeviceLabel(device)}`);

  let runnerProc: ChildProcess | null = null;
  let client: DriverClient | null = null;
  try {
    const activeInfo = readSessionInfo();
    if (activeInfo && activeInfo.udid === device.udid) {
      try {
        client = await createClientFromSession(activeInfo, { verbose, ownsSession: true });
        await client.createSession(bundleId);
        const nextInfo = saveReadySession(client, device, bundleId);
        logSessionReady(bundleId, nextInfo.sessionId);
        disconnectClient(client);
        client = null;
        return;
      } catch (error) {
        disconnectClient(client);
        client = null;
        if (isSessionBroken(error)) {
          logger.warn('Existing session became unconnected, rebuilding session...');
          clearSessionInfo();
        } else {
          throw error;
        }
      }
    }

    try {
      client = await createClient({
        port: DEFAULT_PORT,
        udid: device.udid,
        verbose,
        directTcp: isSimulator,
        ownsSession: true,
      });
      await client.createSession(bundleId);
      const sessionInfo = saveReadySession(client, device, bundleId);
      logSessionReady(bundleId, sessionInfo.sessionId);
      disconnectClient(client);
      client = null;
      return;
    } catch {
      disconnectClient(client);
      client = null;
    }

    if (isSimulator) {
      throw new Error(
        'Simulator driver is not running. Please run:\n'
        + '  ios-use config --simulator\n'
        + 'Then retry `ios-use session start`.',
      );
    }

    logger.info('Launching driver on device...');
    runnerProc = startXctestRunner(device.udid, { verbose });

    const maxWaitMs = 30_000;
    const intervalMs = 2_000;
    const deadline = Date.now() + maxWaitMs;

    while (Date.now() < deadline) {
      try {
        client = await createClient({
          port: DEFAULT_PORT,
          udid: device.udid,
          verbose,
          ownsSession: true,
        });
        logger.info('Driver TCP server ready');
        break;
      } catch (error) {
        const message = error instanceof Error ? error.message : '';
        if (message.includes('not found via usbmux')) {
          throw normalizeDeviceError(error, device.udid);
        }
        if (runnerProc.exitCode !== null && runnerProc.exitCode !== 0) {
          throw new Error(`Runner process exited with code ${runnerProc.exitCode}. Run with --verbose for details.`);
        }
        await delay(intervalMs);
      }
    }

    if (!client) {
      throw new Error(`Driver did not start within ${maxWaitMs / 1000}s`);
    }

    await client.createSession(bundleId);
    const sessionInfo = saveReadySession(client, device, bundleId);
    if (bundleId) {
      logger.success(`Session created: ${sessionInfo.sessionId.substring(0, 8)}...`);
    } else {
      logger.success(`Device session created: ${sessionInfo.sessionId.substring(0, 8)}...`);
    }
    logger.info('Run `ios-use session stop` to end the session.');
    disconnectClient(client);
    client = null;
  } catch (error) {
    disconnectClient(client);
    if (runnerProc && !runnerProc.killed) {
      runnerProc.kill();
    }
    if (isSimulator) {
      const message = error instanceof Error ? error.message : String(error);
      if (message.includes('ECONNREFUSED') || message.includes('connect')) {
        throw new Error(
          `Simulator connection failed: ${message}\n`
          + '  → Make sure XCUIDriverRunner is running in the Simulator.\n'
          + '  → Open driver/XCUIDriver.xcodeproj in Xcode, select the simulator, and run XCUIDriverRunner.',
        );
      }
    }
    throw normalizeDeviceError(error, device.udid);
  }
}

export async function createDriverFromSession(opts: CreateDriverFromSessionOpts = {}): Promise<DriverClient> {
  const verbose = opts.verbose || false;
  const info = readSessionInfo();
  if (!info?.udid) {
    throw new Error('No active session found. Run `ios-use session start` first.');
  }
  if (!(await isDriverAlive(info, { verbose }))) {
    clearSessionInfo();
    throw new Error('No active session found. Run `ios-use session start` first.');
  }
  return await createClientFromSession(info, { verbose, ownsSession: false });
}

export async function stopSession(): Promise<void> {
  const info = readSessionInfo();

  let udid = info?.udid;
  let deviceType = info?.deviceType;
  if (!udid) {
    try {
      const device = await resolveDefaultDevice();
      udid = device.udid;
      deviceType = device.type;
    } catch {}
  }

  if (!udid) {
    logger.warn('No active session and no device found');
    return;
  }

  const isSimulator = deviceType === 'simulator';

  let client: DriverClient | null = null;
  try {
    client = info
      ? await createClientFromSession(info, { ownsSession: true })
      : await createClient({ port: DEFAULT_PORT, udid, directTcp: isSimulator, ownsSession: true });
    await client.deleteSession();
    logger.info('Session deleted');
  } catch {
    // Session already gone.
  } finally {
    disconnectClient(client);
  }

  if (!isSimulator) {
    try {
      getDeviceSigningConfig(udid);
      if (terminateDeviceProcessesByExecutable(udid, DRIVER_RUNNER_EXECUTABLE)) {
        logger.info('Driver app terminated on device');
      }
    } catch {
      // Missing config or process already gone.
    }
  }

  clearSessionInfo();
  logger.success('Session stopped');
}

export async function sessionStatus(): Promise<void> {
  const info = readSessionInfo();
  if (!info) {
    logger.info('No active session');
    return;
  }

  const alive = await isDriverAlive(info);
  console.log('\n  Session Info:');
  console.log(`    Bundle ID:  ${info.bundleId || '(device session)'}`);
  if (info.deviceName || info.deviceVersion) {
    console.log(`    Device:     ${info.deviceName || 'Unknown device'} | iOS ${info.deviceVersion || 'unknown'}`);
  }
  console.log(`    UDID:       ${info.udid}`);
  console.log(`    Session ID: ${info.sessionId?.substring(0, 16)}...`);
  console.log(`    Port:       ${info.port}`);
  console.log(`    Driver:     ${alive ? 'running' : 'stopped'}`);
  console.log(`    Created:    ${new Date(info.createdAt).toLocaleString()}`);
  console.log('');
}
