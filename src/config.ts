import fs from 'fs';
import path from 'path';
import { execFileSync, spawn } from 'child_process';
import { fileURLToPath } from 'url';
import { formatDeviceLabel, getConfiguredUdids, resolveDevice } from './device.js';
import { logger } from './utils/logger.js';
import {
  CONFIG_FILE,
  IOS_USE_HOME,
  ensureIosUseHome,
} from './utils/paths.js';

import { DEFAULT_PORT } from './constants.js';

const DEFAULT_DRIVER_BUNDLE_PREFIX = 'com.ios-use.driver';
const CACHED_APPLE_ID_RE = /Using cached session for ([^\s]+)/;
const NON_ALPHANUM_RE = /[^a-z0-9]/g;
const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));

// Bundle IDs baked into the prebuilt driver.ipa by xcodegen (local dev values).
const DEV_RUNNER_BUNDLE_ID = 'com.iosuse.xcuidriver.xctrunner';
const DEV_XCTEST_BUNDLE_ID = 'com.iosuse.xcuidriver';

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

/**
 * Rewrite bundle IDs in a prebuilt driver IPA.
 * The prebuilt IPA uses dev bundle IDs (com.iosuse.xcuidriver.*).
 * For real-device signing we need per-developer IDs (com.ios-use.driver.{appleId}.*).
 * Returns the path to the rewritten IPA (a temp file next to the original).
 */
export function rewriteIpaBundleIds(
  ipaPath: string,
  runnerBundleId: string,
  xctestBundleId: string,
): string {
  const tmpDir = fs.mkdtempSync(path.join(IOS_USE_HOME, 'ipa-rewrite-'));
  try {
    execFileSync('unzip', ['-q', '-o', ipaPath, '-d', tmpDir], { stdio: 'pipe' });

    // Rewrite runner app Info.plist
    const payloadDir = path.join(tmpDir, 'Payload');
    const appEntries = fs.readdirSync(payloadDir).filter(e => e.endsWith('.app'));
    if (appEntries.length === 0) throw new Error('No .app found in IPA');
    const runnerPlist = path.join(payloadDir, appEntries[0], 'Info.plist');
    rewritePlistBundleId(runnerPlist, DEV_RUNNER_BUNDLE_ID, runnerBundleId);

    // Rewrite xctest bundle Info.plist (inside PlugIns/)
    const plugInsDir = path.join(payloadDir, appEntries[0], 'PlugIns');
    if (fs.existsSync(plugInsDir)) {
      for (const entry of fs.readdirSync(plugInsDir)) {
        if (entry.endsWith('.xctest')) {
          const xctestPlist = path.join(plugInsDir, entry, 'Info.plist');
          if (fs.existsSync(xctestPlist)) {
            rewritePlistBundleId(xctestPlist, DEV_XCTEST_BUNDLE_ID, xctestBundleId);
          }
        }
      }
    }

    const outPath = ipaPath.replace(/\.ipa$/, '-rewritten.ipa');
    execFileSync('zip', ['-r', '-q', outPath, 'Payload'], { cwd: tmpDir, stdio: 'pipe' });
    return outPath;
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

function rewritePlistBundleId(plistPath: string, oldId: string, newId: string): void {
  // Read current value via plutil (works for both binary and XML plists)
  const current = execFileSync('plutil', ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', plistPath], {
    stdio: ['pipe', 'pipe', 'pipe'],
  }).toString().trim();

  if (current === newId) return; // already correct
  if (current !== oldId) return; // unexpected value, don't touch

  execFileSync('plutil', ['-replace', 'CFBundleIdentifier', '-string', newId, plistPath], {
    stdio: ['pipe', 'pipe', 'pipe'],
  });
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
  const localAsset = path.resolve(MODULE_DIR, '..', 'assets', 'driver.ipa');
  if (fs.existsSync(localAsset)) return localAsset;
  return path.join(IOS_USE_HOME, 'driver.ipa');
}

export function getPrebuiltSimulatorIPAPath(): string {
  const localAsset = path.resolve(MODULE_DIR, '..', 'assets', 'driver-sim.ipa');
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
  simulator?: boolean;
}

export async function configureDeviceSigning(opts: ConfigureDeviceSigningOpts): Promise<void> {
  if (!opts.udid) {
    throw new Error('UDID is required');
  }
  const device = resolveDevice(opts.udid);
  const verbose = opts.verbose || false;
  logger.info(`Using device: ${formatDeviceLabel(device, getConfiguredUdids())}`);

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
  // xctest bundle ID = runner bundle ID without the .xctrunner suffix
  const xctestBundleId = bundleId.replace(/\.xctrunner$/, '');
  logger.info(`Driver Bundle ID: ${bundleId}`);
  logger.info(`XCTest Bundle ID: ${xctestBundleId}`);

  // Locate prebuilt IPA
  const ipaPath = getPrebuiltIPAPath();
  if (!fs.existsSync(ipaPath)) {
    throw new Error(
      `Prebuilt driver IPA not found at ${ipaPath}\n`
      + 'Build it first: ./scripts/build_host_app.sh',
    );
  }
  logger.info(`Using prebuilt driver: ${ipaPath}`);

  // Rewrite bundle IDs in the IPA before signing
  logger.info('Rewriting IPA bundle IDs...');
  const rewrittenIpa = rewriteIpaBundleIds(ipaPath, bundleId, xctestBundleId);
  logger.info(`Rewritten IPA: ${rewrittenIpa}`);

  // Sign with altsign-cli (reads bundle IDs from the IPA, no --bundle-id needed)
  const signedIpa = path.join(IOS_USE_HOME, `driver-signed-${device.udid}.ipa`);
  logger.info('Signing driver via altsign-cli...');

  const signArgs = [
    'sign',
    '--udid', device.udid,
    '--ipa', rewrittenIpa,
    '--output', signedIpa,
  ];
  if (opts.appleId) signArgs.push('--apple-id', opts.appleId);
  if (opts.password) signArgs.push('--password', opts.password);
  if (verbose) signArgs.push('--verbose');

  const beforeSign = fs.existsSync(signedIpa) ? fs.statSync(signedIpa).mtimeMs : 0;
  await runCommand(cli, signArgs, 'altsign-cli sign', { capture: false });

  if (!fs.existsSync(signedIpa) || fs.statSync(signedIpa).mtimeMs <= beforeSign) {
    throw new Error(
      'altsign-cli sign did not produce a signed IPA. Common causes:\n'
      + '  - Network error (502/503): Apple server is temporarily unavailable, try again later\n'
      + '  - Auth error: invalid Apple ID or password, or account not enrolled in Apple Developer\n'
      + '  - 2FA timeout: verification code was not entered in time\n'
      + 'Run with --verbose for full altsign output.',
    );
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

  saveDeviceSigningConfig(device.udid, {
    bundleId,
  });

  // Cleanup
  fs.rmSync(extractDir, { recursive: true, force: true });
  if (rewrittenIpa !== ipaPath) fs.rmSync(rewrittenIpa, { force: true });

  logger.success('Device config complete! Run `ios-use activateApp <bundleId>` to start, or just use any action command.');
}

// ── Simulator configuration (no signing required) ──

const SIMULATOR_BUNDLE_ID = 'com.iosuse.xcuidriver';

interface ConfigureSimulatorOpts {
  verbose?: boolean;
}

function waitForSimulatorBoot(udid: string, verbose = false): void {
  execFileSync('xcrun', ['simctl', 'bootstatus', udid, '-b'], { stdio: verbose ? 'inherit' : 'pipe', timeout: 120000 });
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
      waitForSimulatorBoot(udid, verbose);
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
    port: String(DEFAULT_PORT),
  });

  logger.success('Simulator config complete! Run `ios-use activateApp <bundleId>` to start, or just use any action command.');
}

export {
  CONFIG_FILE,
  DEFAULT_DRIVER_BUNDLE_PREFIX,
  DEFAULT_PORT,
  IOS_USE_HOME as IOS_USE_DIR,
};
