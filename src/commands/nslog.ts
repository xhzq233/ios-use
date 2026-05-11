import fs from 'fs';
import path from 'path';
import { logger } from '../utils/logger';
import { NSLoggerServer, formatBonjourStatusMessages, regexTest } from '../nslogger';
import { NSLOG_LOCK_FILE } from '../utils/paths.js';
import { isProcessAlive } from '../utils/process.js';

export const LOCK_FILE = NSLOG_LOCK_FILE;

const LOCK_STALE_MS = 60 * 60 * 1000; // 1 hour

function acquireLock(): void {
  try {
    const raw = fs.readFileSync(LOCK_FILE, 'utf8').trim().split(' ');
    const pid = parseInt(raw[0], 10);
    const startedAt = parseInt(raw[1] || '0', 10);
    if (pid && isProcessAlive(pid) && Date.now() - startedAt < LOCK_STALE_MS) {
      throw new Error(`nslog already running (PID ${pid}). Only one nslog instance allowed at a time; cannot grep multiple patterns simultaneously.`);
    }
    fs.unlinkSync(LOCK_FILE);
  } catch (e: unknown) {
    const err = e as Error;
    if (err.message?.includes('nslog already running')) throw e;
  }
  fs.mkdirSync(path.dirname(LOCK_FILE), { recursive: true });
  fs.writeFileSync(LOCK_FILE, `${process.pid} ${Date.now()}`);
}

function releaseLock(): void {
  try {
    const raw = fs.readFileSync(LOCK_FILE, 'utf8').trim().split(' ');
    const pid = parseInt(raw[0], 10);
    if (pid === process.pid) fs.unlinkSync(LOCK_FILE);
  } catch {}
}

export async function nslogStreamAction(opts: {
  name?: string;
  grep?: string;
  flags?: string;
  setExitCode?: boolean;
  skipLock?: boolean;
}): Promise<void> {
  const ownsLock = opts.skipLock !== true;
  if (ownsLock) acquireLock();

  const server = new NSLoggerServer({
    port: 50000,
    useSSL: true,
    bonjourName: opts.name || '',
    publishBonjour: true,
  });
  const regex = opts.grep ? (() => { try { return new RegExp(opts.grep, opts.flags || ''); } catch (e) { throw new Error(`Invalid --grep regex: ${(e as Error).message}`); } })() : null;
  let stopped = false;

  const stop = async (): Promise<void> => {
    if (stopped) return;
    stopped = true;
    await server.stop();
    if (ownsLock) releaseLock();
  };

  server.onMessage((entry: string) => {
    if (!regex || regexTest(regex, entry)) {
      console.log(entry);
    }
  });

  await server.start();
  logger.info(`NSLogger listening on port ${server.getPort()} (SSL)`);
  const bonjourMessages = formatBonjourStatusMessages(server.getBonjourStatus());
  for (const entry of bonjourMessages) {
    logger[entry.level as 'info' | 'warn' | 'error'](entry.message);
  }
  logger.info('Streaming logs... Press Ctrl+C to stop.');

  let exitCode = 0;
  const shutdown = async (signal: string): Promise<void> => {
    if (signal === 'SIGINT') exitCode = 130;
    if (signal === 'SIGTERM') exitCode = 143;
    await stop();
  };

  const sigintHandler = (): Promise<void> => shutdown('SIGINT');
  const sigtermHandler = (): Promise<void> => shutdown('SIGTERM');

  process.once('SIGINT', sigintHandler as () => void);
  process.once('SIGTERM', sigtermHandler as () => void);

  await new Promise<void>((resolve, reject) => {
    if (!server.server) {
      resolve();
      return;
    }
    const onClose = () => { cleanup(); resolve(); };
    const onError = (err: Error) => { cleanup(); reject(err); };
    const cleanup = () => {
      server.server?.off('close', onClose);
      server.server?.off('error', onError);
    };
    server.server.once('close', onClose);
    server.server.once('error', onError);
  }).finally(() => {
    process.removeListener('SIGINT', sigintHandler as () => void);
    process.removeListener('SIGTERM', sigtermHandler as () => void);
  });

  if (opts.setExitCode !== false && exitCode !== 0) {
    process.exitCode = exitCode;
  }
}
