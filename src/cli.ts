#!/usr/bin/env bun

import { Command } from 'commander';
import { logger } from './utils/logger';
import { configureDeviceSigning, readProjectConfig } from './config';
import { detectRealDevices, detectBootedSimulators, formatDeviceLabel } from './device';
import {
  tapAction,
  swipeAction,
  inputAction,
  longpressAction,
  domAction,
  findAction,
  screenshotAction,
  waitForAction,
  oslogAction,
  runCommandStep,
} from './commands/actions';
import { flowAction } from './commands/flow';
import { nslogStreamAction } from './commands/nslog';
import type { SwipeDir } from './driver-protocol/index.js';
import { startSession, stopSession, sessionStatus } from './session';
import { formatDriverError } from './utils/driverError';

const program = new Command();

function parseIntStrict(val: string): number {
  const n = parseInt(val, 10);
  if (!Number.isFinite(n)) throw new Error(`Invalid integer: "${val}"`);
  return n;
}

function parseFloatStrict(val: string): number {
  const n = Number(val);
  if (!Number.isFinite(n)) throw new Error(`Invalid number: "${val}"`);
  return n;
}

function handleAction<TArgs extends unknown[]>(action: (...args: TArgs) => Promise<unknown>) {
  return async (...args: TArgs) => {
    try {
      await action(...args);
    } catch (error: unknown) {
      const err = error as Error;
      logger.error(formatDriverError(error));
      if (err.cause instanceof Error && err.cause.message !== err.message) {
        logger.error(`Caused by: ${err.cause.message}`);
      }
      process.exitCode = 1;
    }
  };
}

type ActionOpts = { udid?: string; bundleId?: string; verbose?: boolean };
type LabelContext = { ancestorType?: string; ancestorLabel?: string };

function extractContext(opts: Record<string, unknown>): LabelContext | undefined {
  const nested = (opts.context && typeof opts.context === 'object') ? opts.context as Record<string, unknown> : undefined;
  const ancestorType =
    (nested?.ancestorType as string | undefined)
    ?? (opts['context.ancestorType'] as string | undefined)
    ?? (opts['context.ancestor-type'] as string | undefined);
  const ancestorLabel =
    (nested?.ancestorLabel as string | undefined)
    ?? (opts['context.ancestorLabel'] as string | undefined)
    ?? (opts['context.ancestor-label'] as string | undefined);
  if (!ancestorType && !ancestorLabel) return undefined;
  return { ancestorType, ancestorLabel };
}

function addSessionOptions(command: Command): Command {
  return command
    .option('--udid <udid>', 'Device UDID')
    .option('--bundle-id <id>', 'App bundle ID')
    .option('--verbose', 'Verbose output');
}

program
  .name('ios-use')
  .description('CLI tool to control iOS devices via custom TCP driver')
  .version('1.0.0');

// ── Device & Config (local operations) ──

program
  .command('device')
  .description('Show connected iOS device info')
  .option('-s, --simulator', 'Show only booted Simulators')
  .option('--verbose', 'Verbose output')
  .action(handleAction(async (opts: { simulator?: boolean; verbose?: boolean }) => {
    if (opts.simulator) {
      const sims = detectBootedSimulators();
      if (sims.length === 0) { logger.info('No booted Simulators found'); return; }
      for (const sim of sims) logger.info(formatDeviceLabel(sim));
      return;
    }
    const reals = detectRealDevices();
    if (reals.length === 0) { logger.info('No connected real devices found'); return; }
    for (const d of reals) logger.info(formatDeviceLabel(d));
  }));

program
  .command('config')
  .description('Configure driver for device or Simulator (sign + install for device; build + install + launch for Simulator)')
  .option('--udid <udid>', 'Device UDID to configure')
  .option('--list', 'List configured devices')
  .option('--simulator', 'Configure for iOS Simulator (skips signing, builds and installs driver directly)')
  .option('--apple-id <email>', 'Apple ID email (optional if session cached)')
  .option('--password <pwd>', 'Apple ID password (optional if session cached)')
  .option('--ipa <path>', 'Path to prebuilt driver IPA (default: assets/driver.ipa)')
  .option('--port <port>', 'Driver local port (default: 8100)', parseIntStrict)
  .option('--verbose', 'Show detailed output')
  .action(handleAction(async (opts: {
    udid?: string; list?: boolean; simulator?: boolean;
    appleId?: string; password?: string; ipa?: string; port?: number; verbose?: boolean;
  }) => {
    if (opts.list) {
      const config = readProjectConfig();
      const entries = Object.entries(config.devices);
      if (entries.length === 0) { logger.info('No configured devices.'); return; }
      logger.info('Configured devices:');
      for (const [udid, dc] of entries) {
        console.log(`  ${udid} → bundleId: ${dc?.bundleId || '(missing)'}, port: ${dc?.port || '(missing)'}`);
      }
      return;
    }
    if (!opts.udid) {
      const devices = detectRealDevices();
      if (devices.length === 0) throw new Error('No --udid and no devices detected.');
      opts.udid = devices[0].udid;
      logger.info(`Using default device: ${formatDeviceLabel(devices[0])}`);
    }
    await configureDeviceSigning(opts);
  }));

// ── Session ──

const sessionCmd = program.command('session').description('Session management (reuse driver across commands)');

sessionCmd.command('start')
  .description('Start a persistent session (keeps driver running)')
  .option('--bundle-id <id>', 'App bundle ID (optional; session controls the device regardless)')
  .option('--udid <udid>', 'Device UDID')
  .option('--verbose', 'Verbose output')
  .action(handleAction(async (opts: { bundleId?: string; udid?: string; verbose?: boolean }) => {
    await startSession(opts);
  }));

sessionCmd.command('stop')
  .description('Stop the current session and driver')
  .action(handleAction(async () => { await stopSession(); }));

sessionCmd.command('status')
  .description('Show current session info')
  .action(handleAction(async () => { await sessionStatus(); }));

// ── Host API commands (names match flow actions 1:1) ──

addSessionOptions(
  program.command('activateApp <bundleId>')
    .description('Launch or foreground an app by bundle ID'),
).action(handleAction(async (bundleId: string, opts: ActionOpts) => {
  await runCommandStep({ action: 'activateApp', bundleId }, opts);
}));

addSessionOptions(
  program.command('terminateApp <bundleId>')
    .description('Terminate an app by bundle ID'),
).action(handleAction(async (bundleId: string, opts: ActionOpts) => {
  await runCommandStep({ action: 'terminateApp', bundleId }, opts);
}));

addSessionOptions(
  program.command('dom')
    .description('Dump current UI DOM tree')
    .option('--raw', 'Return raw XCUI snapshot tree (default: cleaned)')
    .option('--save', 'Save DOM tree to output/ directory')
    .option('--name <name>', 'Filename prefix for saved DOM', 'dom'),
).action(handleAction(async (opts: ActionOpts & { raw?: boolean; save?: boolean; name?: string }) => {
  await domAction(opts);
}));

addSessionOptions(
  program.command('find <label>')
    .description('Find UI element by label')
    .option('--context.ancestor-type <type>', 'Disambiguate by ancestor type')
    .option('--context.ancestorType <type>', 'Disambiguate by ancestor type (doc spelling)')
    .option('--context.ancestor-label <label>', 'Disambiguate by ancestor label')
    .option('--context.ancestorLabel <label>', 'Disambiguate by ancestor label (doc spelling)'),
).action(handleAction(async (label: string, opts: ActionOpts & { context?: LabelContext }) => {
  await findAction({ label, ...opts, context: extractContext(opts as Record<string, unknown>) });
}));

addSessionOptions(
  program.command('tap')
    .description('Tap on screen by label or coordinate ("x,y")')
    .requiredOption('--label <target>', 'Element label or "x,y" coordinate')
    .option('--context.ancestor-type <type>', 'Disambiguate by ancestor type (e.g. Table, Cell)')
    .option('--context.ancestorType <type>', 'Disambiguate by ancestor type (doc spelling)')
    .option('--context.ancestor-label <label>', 'Disambiguate by ancestor label')
    .option('--context.ancestorLabel <label>', 'Disambiguate by ancestor label (doc spelling)'),
).action(handleAction(async (opts: ActionOpts & { label: string; context?: LabelContext }) => {
  await tapAction({ ...opts, context: extractContext(opts as Record<string, unknown>) });
}));

addSessionOptions(
  program.command('swipe')
    .description('Swipe on screen')
    .option('--to <target>', 'Target label (scroll until visible) or "x,y" coordinate')
    .option('--from <anchor>', 'Anchor label or "x,y" coordinate to scroll from')
    .option('--dir <direction>', 'Direction: forth (down/right) or back (up/left)')
    .option('--distance <px>', 'Swipe distance in pixels (for pure distance swipe)', parseFloatStrict)
    .option('--context.ancestor-type <type>', 'Disambiguate by ancestor type')
    .option('--context.ancestorType <type>', 'Disambiguate by ancestor type (doc spelling)')
    .option('--context.ancestor-label <label>', 'Disambiguate by ancestor label')
    .option('--context.ancestorLabel <label>', 'Disambiguate by ancestor label (doc spelling)'),
).action(handleAction(async (opts: ActionOpts & { to?: string; from?: string; dir?: string; distance?: number; context?: LabelContext }) => {
  await swipeAction({ ...opts, dir: opts.dir as SwipeDir | undefined, context: extractContext(opts as Record<string, unknown>) });
}));

addSessionOptions(
  program.command('input')
    .description('Type text into an element')
    .requiredOption('--content <text>', 'Text to type')
    .requiredOption('--label <text>', 'Focus element by label before typing')
    .option('--context.ancestor-type <type>', 'Disambiguate by ancestor type')
    .option('--context.ancestorType <type>', 'Disambiguate by ancestor type (doc spelling)')
    .option('--context.ancestor-label <label>', 'Disambiguate by ancestor label')
    .option('--context.ancestorLabel <label>', 'Disambiguate by ancestor label (doc spelling)'),
).action(handleAction(async (opts: ActionOpts & { content: string; label: string; context?: LabelContext }) => {
  await inputAction({ ...opts, context: extractContext(opts as Record<string, unknown>) });
}));

addSessionOptions(
  program.command('longpress')
    .description('Long press on screen by label or coordinate ("x,y")')
    .requiredOption('--label <target>', 'Element label or "x,y" coordinate')
    .option('--duration <ms>', 'Long press duration in ms', parseIntStrict)
    .option('--context.ancestor-type <type>', 'Disambiguate by ancestor type')
    .option('--context.ancestorType <type>', 'Disambiguate by ancestor type (doc spelling)')
    .option('--context.ancestor-label <label>', 'Disambiguate by ancestor label')
    .option('--context.ancestorLabel <label>', 'Disambiguate by ancestor label (doc spelling)'),
).action(handleAction(async (opts: ActionOpts & { label: string; duration?: number; context?: LabelContext }) => {
  await longpressAction({ ...opts, context: extractContext(opts as Record<string, unknown>) });
}));

addSessionOptions(
  program.command('screenshot')
    .description('Take a screenshot (saved as .jpg)')
    .option('--name <name>', 'Filename prefix', 'screenshot'),
).action(handleAction(async (opts: ActionOpts & { name?: string }) => {
  await screenshotAction(opts);
}));

addSessionOptions(
  program.command('waitFor')
    .description('Wait until an element becomes visible')
    .requiredOption('--label <text>', 'Element label to wait for')
    .option('--timeout <seconds>', 'Timeout in seconds', parseFloatStrict)
    .option('--interval <ms>', 'Poll interval in milliseconds', parseIntStrict)
    .option('--context.ancestor-type <type>', 'Disambiguate by ancestor type')
    .option('--context.ancestorType <type>', 'Disambiguate by ancestor type (doc spelling)')
    .option('--context.ancestor-label <label>', 'Disambiguate by ancestor label')
    .option('--context.ancestorLabel <label>', 'Disambiguate by ancestor label (doc spelling)'),
).action(handleAction(async (opts: ActionOpts & { label: string; timeout?: number; interval?: number; context?: LabelContext }) => {
  await waitForAction({ ...opts, context: extractContext(opts as Record<string, unknown>) });
}));

addSessionOptions(
  program.command('oslog')
    .description('Fetch iOS system logs from the device')
    .option('--pattern <pattern>', 'Regex pattern to filter logs')
    .option('--flags <flags>', 'Regex flags')
    .option('--name <name>', 'Output filename prefix')
    .option('--clear', 'Clear log buffer and return cleared count'),
).action(handleAction(async (opts: ActionOpts & { pattern?: string; flags?: string; name?: string; clear?: boolean; bundleId?: string }) => {
  await oslogAction(opts);
}));

// ── Flow ──

program.command('flow <file>')
  .description('Execute a flow file')
  .option('--udid <udid>', 'Device UDID')
  .option('--verbose', 'Verbose output')
  .action(handleAction(async (file: string, opts: { udid?: string; verbose?: boolean }) => {
    await flowAction(file, opts);
  }));

// ── NSLogger (separate client-side system) ──

program.command('nslog')
  .description('Start NSLogger server and stream logs')
  .option('--port <port>', 'Listen port', parseIntStrict, 0)
  .option('--ssl', 'Enable TLS', true)
  .option('--no-ssl', 'Disable TLS')
  .option('--name <name>', 'Bonjour name')
  .option('--grep <pattern>', 'Filter pattern')
  .option('--flags <flags>', 'Regex flags', '')
  .option('--publish-bonjour', 'Publish Bonjour', true)
  .option('--no-publish-bonjour', 'Disable Bonjour')
  .action(handleAction(async (opts: {
    port?: number; ssl?: boolean; name?: string;
    grep?: string; flags?: string; publishBonjour?: boolean;
  }) => {
    await nslogStreamAction(opts);
  }));

program.parse();
