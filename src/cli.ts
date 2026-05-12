#!/usr/bin/env bun

import { Command } from 'commander';
import { logger } from './utils/logger';
import { DEFAULT_PORT } from './constants.js';
import { configureDeviceSigning, readProjectConfig } from './config';
import { detectRealDevices, detectBootedSimulators, formatDeviceLabel } from './device';
import { runCommandStep } from './commands/actions';
import { flowAction } from './commands/flow';
import { nslogStreamAction } from './commands/nslog';
import { proxyConfigCA, proxyStart, proxyStop, proxyRead } from './commands/proxy';
import { getCliActions, mapCliToStep, parseIntStrict } from './commands/registry';
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

program
  .command('devices')
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
    const reals = await detectRealDevices();
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
  .option('--port <port>', `Driver local port (default: ${DEFAULT_PORT})`, parseIntStrict)
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
      const devices = await detectRealDevices();
      if (devices.length === 0) throw new Error('No --udid and no devices detected.');
      opts.udid = devices[0].udid;
      logger.info(`Using default device: ${formatDeviceLabel(devices[0])}`);
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
  .option('--udid <udid>', 'Device UDID')
  .option('--verbose', 'Verbose output')
  .action(handleAction(async (file: string, opts: { udid?: string; verbose?: boolean }) => {
    await flowAction(file, opts);
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
    const info = readSessionInfo();
    if (!info?.sessionId) throw new Error('No active session. Run any action command to auto-create one.');
    const udid = opts.udid || info.udid;
    const { createClientFromSession } = await import('./session.js');
    const client = await createClientFromSession(info, { ownsSession: false });
    try {
      await proxyConfigCA(client, { udid });
    } finally {
      client.disconnect();
    }
  }));

proxyCmd.command('start')
  .description('Start proxy: mitmdump + configure device Wi-Fi proxy')
  .option('--stream', 'Stream captured requests to stdout as jsonl')
  .option('--udid <udid>', 'Device UDID')
  .option('--no-body', 'Omit request/response body from output')
  .option('--body-limit <bytes>', 'Max body size in bytes (default 102400)', parseIntStrict)
  .action(handleAction(async (opts: { stream?: boolean; udid?: string; noBody?: boolean; bodyLimit?: number }) => {
    const info = readSessionInfo();
    if (!info?.sessionId) throw new Error('No active session. Run any action command to auto-create one.');
    const udid = opts.udid || info.udid;
    if (!udid) throw new Error('No device UDID. Pass --udid or start session first.');
    const { createClientFromSession } = await import('./session.js');
    const client = await createClientFromSession(info, { ownsSession: false });
    try {
      await proxyStart(client, { udid, stream: opts.stream, noBody: opts.noBody, bodyLimit: opts.bodyLimit });
      if (opts.stream) process.stderr.write('Proxy running. Press Ctrl+C to stop.\n');
      else logger.info('Proxy running. Press Ctrl+C to stop.');
      await new Promise<void>((resolve) => {
        process.on('SIGINT', () => { resolve(); });
        process.on('SIGTERM', () => { resolve(); });
      });
    } finally {
      await proxyStop(client).catch(() => {});
      client.disconnect();
    }
  }));

proxyCmd.command('stop')
  .description('Clear device Wi-Fi proxy and stop mitmdump')
  .option('--udid <udid>', 'Device UDID')
  .action(handleAction(async (opts: { udid?: string }) => {
    const { withAutoSession } = await import('./session.js');
    await withAutoSession({}, async (client) => {
      await proxyStop(client, opts);
    });
  }));

proxyCmd.command('read')
  .description('Read recent proxy captured requests')
  .option('--count <n>', 'Number of requests', parseIntStrict, 10)
  .option('--duration <duration>', 'Time window (e.g. 5s, 1m)')
  .option('--save [name]', 'Save to jsonl file')
  .action(handleAction(async (opts: { count?: number; duration?: string; save?: string }) => {
    proxyRead(opts);
  }));

proxyCmd.command('doctor')
  .description('Diagnose proxy environment')
  .action(handleAction(async () => {
    const { proxyDoctor } = await import('./commands/proxy.js');
    proxyDoctor();
  }));

program.parse();
