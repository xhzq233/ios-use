#!/usr/bin/env bun

import { Command } from 'commander';
import { logger } from './utils/logger';
import { configureDeviceSigning, readProjectConfig } from './config';
import { detectRealDevices, detectBootedSimulators, formatDeviceLabel, getConfiguredUdids } from './device';
import { runCommandStep } from './commands/actions';
import { flowAction, parseFlowCliVars } from './commands/flow';
import { nslogStreamAction } from './commands/nslog';
import { proxyConfigCA, proxyStart, proxyStop, readProxyState } from './commands/proxy';
import { getCliActions, mapCliToStep, parseNonNegativeIntStrict, parsePositiveIntStrict } from './commands/registry';
import type { SwipeDir } from './driver-protocol/index.js';
import { startSession, stopSession, readSessionInfo } from './session';
import { formatDriverError } from './utils/driverError';

const program = new Command();

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

function addSessionOptions(command: Command): Command {
  return command
    .option('--udid <udid>', 'Device UDID')
    .option('--verbose', 'Verbose output');
}

program
  .name('ios-use')
  .description('CLI tool to control iOS devices via custom TCP driver')
  .version('1.0.0');

// ── Device & Config (local operations) ──

interface DeviceListOpts { simulator?: boolean; verbose?: boolean }

async function listDevices(opts: DeviceListOpts): Promise<void> {
  const configured = getConfiguredUdids();
  if (opts.simulator) {
    const sims = detectBootedSimulators();
    if (sims.length === 0) { logger.info('No booted Simulators found'); return; }
    for (const sim of sims) logger.info(formatDeviceLabel(sim, configured));
    return;
  }
  const reals = await detectRealDevices();
  if (reals.length === 0) { logger.info('No connected real devices found'); return; }
  for (const d of reals) logger.info(formatDeviceLabel(d, configured));
}

program
  .command('devices')
  .description('Show connected iOS device info')
  .option('-s, --simulator', 'Show only booted Simulators')
  .option('--verbose', 'Verbose output')
  .action(handleAction(listDevices));

program
  .command('device', { hidden: true })
  .description('Alias for devices')
  .option('-s, --simulator', 'Show only booted Simulators')
  .option('--verbose', 'Verbose output')
  .action(handleAction(async (opts: DeviceListOpts) => {
    logger.warn('`ios-use device` is deprecated; use `ios-use devices`.');
    await listDevices(opts);
  }));

program
  .command('config')
  .description('Configure driver for device or Simulator (sign + install for device; build + install + launch for Simulator)')
  .option('--udid <udid>', 'Device UDID to configure')
  .option('--list', 'List configured devices')
  .option('--simulator', 'Configure for iOS Simulator (skips signing, builds and installs driver directly)')
  .option('--apple-id <email>', 'Apple ID email (optional if session cached)')
  .option('--password <pwd>', 'Apple ID password (optional if session cached)')
  .option('--verbose', 'Show detailed output')
  .action(handleAction(async (opts: {
    udid?: string; list?: boolean; simulator?: boolean;
    appleId?: string; password?: string; verbose?: boolean;
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
      const devices = opts.simulator ? detectBootedSimulators() : await detectRealDevices();
      if (devices.length === 0) {
        throw new Error(opts.simulator ? 'No --udid and no booted Simulators found.' : 'No --udid and no USB devices detected.');
      }
      opts.udid = devices[0].udid;
      logger.info(`Using default device: ${formatDeviceLabel(devices[0], getConfiguredUdids())}`);
    }
    await configureDeviceSigning(opts);
  }));

// ── Stop ──

program
  .command('stop')
  .description('Stop driver process and clear session')
  .action(handleAction(async () => { await stopSession(); }));

// ── Action commands (auto-registered from registry) ──

for (const def of getCliActions()) {
  let cmd = program.command(def.name).description(def.desc);

  // Positional args
  if (def.cli?.args) {
    for (const arg of def.cli.args) {
      cmd = cmd.argument(`<${arg}>`, arg);
    }
  }

  // Options
  if (def.cli?.opts) {
    for (const opt of def.cli.opts) {
      const flag = opt.flag ? `--${opt.name}` : `--${opt.name} <${opt.name}>`;
      if (opt.required) {
        if (opt.parse) cmd = cmd.requiredOption(flag, opt.desc, opt.parse, opt.default);
        else cmd = cmd.requiredOption(flag, opt.desc);
      } else if (opt.flag) {
        cmd = cmd.option(flag, opt.desc);
      } else if (opt.parse) {
        cmd = cmd.option(flag, opt.desc, opt.parse, opt.default);
      } else {
        cmd = cmd.option(flag, opt.desc);
      }
    }
  }

  addSessionOptions(cmd);

  cmd.action(handleAction(async (...rest: unknown[]) => {
    // Commander v14: (positionalArgs..., options, command)
    const options = rest[rest.length - 2] as Record<string, unknown>;
    const args = rest.slice(0, rest.length - 2) as string[];
    const step = mapCliToStep(def, args, options);
    await runCommandStep(step, options as ActionOpts);
  }));
}

// ── Flow ──

program.command('flow <file>')
  .description('Execute a flow file')
  .allowUnknownOption(true)
  .allowExcessArguments(true)
  .option('--udid <udid>', 'Device UDID')
  .option('--verbose', 'Verbose output')
  .action(handleAction(async (file: string, opts: { udid?: string; verbose?: boolean }, command: Command) => {
    const externalArgs = command.args.slice(1);
    await flowAction(file, { ...opts, vars: parseFlowCliVars(externalArgs) });
  }));

// ── NSLogger (separate client-side system) ──

program.command('nslog')
  .description('Start NSLogger server and stream logs')
  .option('--name <name>', 'Bonjour name')
  .option('--grep <pattern>', 'Filter pattern')
  .option('--flags <flags>', 'Regex flags', '')
  .action(handleAction(async (opts: {
    name?: string; grep?: string; flags?: string;
  }) => {
    await nslogStreamAction(opts);
  }));

// ── Proxy ──

const proxyCmd = program.command('proxy').description('HTTP/HTTPS proxy via mitmdump + Wi-Fi proxy');

proxyCmd.command('configca')
  .description('Install and trust mitmproxy CA on device (one-time)')
  .option('--udid <udid>', 'Device UDID')
  .action(handleAction(async (opts: { udid?: string }) => {
    const { withAutoSession } = await import('./session.js');
    await withAutoSession({ udid: opts.udid }, async (client) => {
      const info = readSessionInfo();
      await proxyConfigCA(client, { udid: opts.udid || info?.udid });
    });
  }));

proxyCmd.command('start')
  .description('Start proxy: mitmdump + configure device Wi-Fi proxy')
  .option('--udid <udid>', 'Device UDID')
  .option('-i, --interface <interface>', 'Mac network interface to advertise as proxy host (default: Wi-Fi)')
  .action(handleAction(async (opts: { udid?: string; interface?: string }) => {
    const { withAutoSession } = await import('./session.js');
    await withAutoSession({ udid: opts.udid }, async (client) => {
      const info = readSessionInfo();
      const udid = opts.udid || info?.udid;
      if (!udid) throw new Error('No device UDID. Pass --udid or run an action command first.');
      await proxyStart(client, { udid, interfaceName: opts.interface });
    });
  }));

proxyCmd.command('stop')
  .description('Clear device Wi-Fi proxy and stop mitmdump')
  .option('--udid <udid>', 'Device UDID')
  .action(handleAction(async (opts: { udid?: string }) => {
    const { withAutoSession } = await import('./session.js');
    const targetUdid = opts.udid || readProxyState()?.udid;
    if (!targetUdid) {
      throw new Error('No proxy session/device found. Pass --udid.');
    }
    await withAutoSession({ udid: targetUdid }, async (client) => {
      await proxyStop(client, { ...opts, udid: targetUdid });
    });
  }));

proxyCmd.command('doctor')
  .description('Diagnose proxy environment')
  .action(handleAction(async () => {
    const { proxyDoctor } = await import('./commands/proxy.js');
    proxyDoctor();
  }));

try {
  program.parse();
} catch (error: unknown) {
  logger.error(formatDriverError(error));
  process.exitCode = 1;
}
