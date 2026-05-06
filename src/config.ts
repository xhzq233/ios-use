import fs from 'fs';
import path from 'path';
import { execFileSync, spawn } from 'child_process';
import { formatDeviceLabel, resolveDevice } from './device.js';
import { logger } from './utils/logger.js';
import {
  CONFIG_FILE,
  IOS_USE_HOME,
  ensureIosUseHome,
} from './utils/paths.js';

const DEFAULT_DRIVER_BUNDLE_PREFIX = 'com.ios-use.driver';
const DEFAULT_PORT = '8100';
const CACHED_APPLE_ID_RE = /Using cached session for ([^\s]+)/;
const NON_ALPHANUM_RE = /[^a-z0-9]/g;

export interface DeviceConfig {
  bundleId: string;
  port: string;
}

export interface ConfigFile {
  devices: Record<string, DeviceConfig>;
}

interface RunCommandResult {
  stdout: string;
  stderr: string;
}

function altsignCliPath(): string {
  const candidates = [
    path.join(IOS_USE_HOME, 'altsign-cli', 'altsign-cli'),
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) return p;
  }
  return candidates[0];
}

function normalizeDeviceConfig(deviceConfig: Partial<DeviceConfig> = {}): DeviceConfig {
  return {
    bundleId: String(deviceConfig.bundleId || ''),
    port: String(deviceConfig.port || DEFAULT_PORT),
  };
}

function ensureDir(): void {
  ensureIosUseHome();
}

export function readProjectConfig(): ConfigFile {
  try {
    const parsed = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf-8'));
    return {
      devices: parsed?.devices && typeof parsed.devices === 'object' ? parsed.devices : {},
    };
  } catch {
    return { devices: {} };
  }
}

export function writeProjectConfig(config: ConfigFile): void {
  ensureDir();
  const tmp = CONFIG_FILE + '.tmp';
  fs.writeFileSync(tmp, `${JSON.stringify(config, null, 2)}\n`);
  fs.renameSync(tmp, CONFIG_FILE);
}

export function getDeviceSigningConfig(udid: string): DeviceConfig {
  const config = readProjectConfig();
  const deviceConfig = config.devices?.[udid];
  const normalized = normalizeDeviceConfig(deviceConfig);
  if (!normalized.bundleId) {
    throw new Error(`No signing config found for device ${udid}. Run \`ios-use config --udid ${udid}\` first.`);
  }
  return normalized;
}

export function saveDeviceSigningConfig(udid: string, config: Partial<DeviceConfig>): void {
  const projectConfig = readProjectConfig();
  projectConfig.devices[udid] = normalizeDeviceConfig(config);
  writeProjectConfig(projectConfig);
}

function runCommand(
  command: string,
  args: string[],
  description: string,
  { capture = false } = {},
): Promise<RunCommandResult | undefined> {
  return new Promise((resolve, reject) => {
    const proc = spawn(command, args, { stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit' });
    let stdout = '';
    let stderr = '';

    const MAX_CAPTURE_SIZE = 10 * 1024 * 1024;
    let stdoutSize = 0;
    let stderrSize = 0;
    if (capture) {
      proc.stdout?.on('data', (chunk: Buffer) => {
        if (stdoutSize < MAX_CAPTURE_SIZE) {
          stdout += chunk.toString();
          stdoutSize += chunk.length;
        }
      });
      proc.stderr?.on('data', (chunk: Buffer) => {
        if (stderrSize < MAX_CAPTURE_SIZE) {
          stderr += chunk.toString();
          stderrSize += chunk.length;
        }
      });
    }

    proc.on('error', (error) => reject(new Error(`${description} failed: ${error.message}`)));
    proc.on('close', (code) => {
      if (code === 0) {
        resolve(capture ? { stdout, stderr } : undefined);
        return;
      }
      const output = [stdout, stderr].filter(Boolean).join('\n').trim();
      reject(new Error(`${description} exited with code ${code}${output ? ': ' + output : ''}`));
    });
  });
}

export function getPrebuiltIPAPath(): string {
  const localAsset = path.resolve(import.meta.dirname, '..', 'assets', 'driver.ipa');
  if (fs.existsSync(localAsset)) return localAsset;
  return path.join(IOS_USE_HOME, 'driver.ipa');
}

export function getPrebuiltSimulatorIPAPath(): string {
  const localAsset = path.resolve(import.meta.dirname, '..', 'assets', 'driver-sim.ipa');
  if (fs.existsSync(localAsset)) return localAsset;
  return path.join(IOS_USE_HOME, 'driver-sim.ipa');
}

async function getCachedAppleId(cliPath: string): Promise<string | null> {
  try {
    const result = await runCommand(cliPath, ['list'], 'altsign-cli list', { capture: true });
    if (!result) return null;
    const combined = result.stdout + result.stderr;
    const match = combined.match(CACHED_APPLE_ID_RE);
    return match ? match[1] : null;
  } catch {
    return null;
  }
}

function sanitizeForBundleId(str: string): string {
  return str.toLowerCase().replace(NON_ALPHANUM_RE, '-');
}

interface ConfigureDeviceSigningOpts {
  udid?: string;
  verbose?: boolean;
  appleId?: string;
  password?: string;
  ipa?: string;
  port?: string | number;
  simulator?: boolean;
}

export async function configureDeviceSigning(opts: ConfigureDeviceSigningOpts): Promise<void> {
  if (!opts.udid) {
    throw new Error('UDID is required');
  }
  const device = resolveDevice(opts.udid);
  const verbose = opts.verbose || false;
  logger.info(`Using device: ${formatDeviceLabel(device)}`);

  if (opts.simulator || device.type === 'simulator') {
    return configureSimulator(device.udid, { verbose });
  }

  const cli = altsignCliPath();
  if (!fs.existsSync(cli)) {
    throw new Error(`altsign-cli not found at ${cli}. Run: cd altsign-cli && ./build.sh`);
  }

  // Resolve bundle ID: saved config > dynamic by apple id
  let savedConfig: DeviceConfig | null = null;
  try { savedConfig = getDeviceSigningConfig(device.udid); } catch {}

  let bundleId = savedConfig?.bundleId;
  if (!bundleId) {
    const cachedAppleId = await getCachedAppleId(cli);
    const appleId = opts.appleId || cachedAppleId;
    if (!appleId) {
      throw new Error(
        'No signing config found for this device and no cached altsign session. '
        + 'Please run with --apple-id <email> --password <pwd> to log in.',
      );
    }
    bundleId = `${DEFAULT_DRIVER_BUNDLE_PREFIX}.${sanitizeForBundleId(appleId)}.xctrunner`;
  }
  saveDeviceSigningConfig(device.udid, {
    bundleId,
    port: opts.port !== undefined ? String(opts.port) : undefined,
  });
  logger.info(`Driver Bundle ID: ${bundleId}`);

  // Locate prebuilt IPA
  const ipaPath = opts.ipa || getPrebuiltIPAPath();
  if (!fs.existsSync(ipaPath)) {
    throw new Error(
      `Prebuilt driver IPA not found at ${ipaPath}\n`
      + 'Build it first: ./scripts/build_host_app.sh',
    );
  }
  logger.info(`Using prebuilt driver: ${ipaPath}`);

  // Sign with altsign-cli
  const signedIpa = path.join(IOS_USE_HOME, `driver-signed-${device.udid}.ipa`);
  logger.info('Signing driver via altsign-cli...');

  const signArgs = [
    'sign',
    '--udid', device.udid,
    '--ipa', ipaPath,
    '--bundle-id', bundleId,
    '--output', signedIpa,
  ];
  if (opts.appleId) signArgs.push('--apple-id', opts.appleId);
  if (opts.password) signArgs.push('--password', opts.password);
  if (verbose) signArgs.push('--verbose');

  const signResult = await runCommand(cli, signArgs, 'altsign-cli sign', { capture: true });
  if (signResult && signResult.stdout) process.stdout.write(signResult.stdout);
  if (signResult && signResult.stderr) process.stderr.write(signResult.stderr);
  const combinedOutput = [signResult?.stdout, signResult?.stderr].filter(Boolean).join('\n');
  const hasSuccess = combinedOutput.includes('IPA signed successfully');
  if (!hasSuccess) {
    const errorLine = combinedOutput.split('\n').find(l => l.toLowerCase().includes('error'));
    if (errorLine) {
      throw new Error(`altsign-cli sign failed: ${errorLine.trim()}`);
    }
  }
  logger.success('Driver signed');

  // Extract signed IPA and install
  const extractDir = path.join(IOS_USE_HOME, `driver-install-${device.udid}`);
  if (fs.existsSync(extractDir)) fs.rmSync(extractDir, { recursive: true, force: true });
  fs.mkdirSync(extractDir, { recursive: true });
  execFileSync('unzip', ['-q', '-o', signedIpa, '-d', extractDir], { stdio: 'pipe' });

  const payloadDir = path.join(extractDir, 'Payload');
  const appEntries = fs.readdirSync(payloadDir).filter(e => e.endsWith('.app'));
  if (appEntries.length === 0) {
    throw new Error(`No .app found in signed IPA at ${payloadDir}`);
  }
  const appPath = path.join(payloadDir, appEntries[0]);

  logger.info(`Installing driver to device ${device.udid}...`);
  await runCommand('xcrun', ['devicectl', 'device', 'install', 'app', '--device', device.udid, appPath], 'Install driver to device', { capture: !verbose });
  logger.success('Driver installed to device');

  // Cleanup
  fs.rmSync(extractDir, { recursive: true, force: true });

  logger.success('Device config complete! Run `ios-use session start --bundle-id <app>` to start.');
}

// ── Simulator configuration (no signing required) ──

const SIMULATOR_BUNDLE_ID = 'com.iosuse.xcuidriver.xctrunner';

interface ConfigureSimulatorOpts {
  verbose?: boolean;
}

async function configureSimulator(udid: string, opts: ConfigureSimulatorOpts = {}): Promise<void> {
  const verbose = opts.verbose || false;

  // Locate prebuilt Simulator IPA
  const ipaPath = getPrebuiltSimulatorIPAPath();
  if (!fs.existsSync(ipaPath)) {
    throw new Error(
      'Prebuilt Simulator driver IPA not found.\n'
      + '  Expected: assets/driver-sim.ipa\n'
      + '  Build it first: ./scripts/build_host_app.sh',
    );
  }
  logger.info(`Using prebuilt driver: ${ipaPath}`);

  // Extract IPA
  const extractDir = path.join(IOS_USE_HOME, `driver-sim-install-${udid}`);
  if (fs.existsSync(extractDir)) fs.rmSync(extractDir, { recursive: true, force: true });
  fs.mkdirSync(extractDir, { recursive: true });
  execFileSync('unzip', ['-q', '-o', ipaPath, '-d', extractDir], { stdio: 'pipe' });

  const payloadDir = path.join(extractDir, 'Payload');
  const appEntries = fs.readdirSync(payloadDir).filter(e => e.endsWith('.app'));
  if (appEntries.length === 0) {
    throw new Error(`No .app found in Simulator IPA at ${payloadDir}`);
  }
  const appPath = path.join(payloadDir, appEntries[0]);

  // Terminate existing driver before reinstalling
  try {
    execFileSync('xcrun', ['simctl', 'terminate', udid, SIMULATOR_BUNDLE_ID], { stdio: 'pipe', timeout: 5000 });
    logger.info('Terminated existing driver on Simulator');
  } catch {
    // Not running, ignore
  }

  logger.info(`Installing driver to Simulator ${udid}...`);
  try {
    execFileSync('xcrun', ['simctl', 'install', udid, appPath], { stdio: verbose ? 'inherit' : 'pipe' });
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    if (msg.includes('Shutdown') || msg.includes('current state')) {
      logger.info(`Simulator is not booted, booting ${udid}...`);
      execFileSync('xcrun', ['simctl', 'boot', udid], { stdio: 'pipe' });
      execFileSync('xcrun', ['simctl', 'install', udid, appPath], { stdio: verbose ? 'inherit' : 'pipe' });
    } else {
      throw error;
    }
  }
  logger.success('Driver installed to Simulator');

  // Cleanup
  fs.rmSync(extractDir, { recursive: true, force: true });

  logger.info('Launching driver on Simulator...');
  const launchOutput = execFileSync('xcrun', ['simctl', 'launch', udid, SIMULATOR_BUNDLE_ID], { encoding: 'utf-8', stdio: 'pipe' });
  logger.success(`Driver launched on Simulator (PID: ${launchOutput.trim()})`);

  // Save config so session commands know the bundle ID
  saveDeviceSigningConfig(udid, {
    bundleId: SIMULATOR_BUNDLE_ID,
    port: DEFAULT_PORT,
  });

  logger.success('Simulator config complete! Run `ios-use session start --bundle-id <app>` to connect.');
}

export {
  CONFIG_FILE,
  DEFAULT_DRIVER_BUNDLE_PREFIX,
  DEFAULT_PORT,
  IOS_USE_HOME as IOS_USE_DIR,
};
