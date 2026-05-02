import fs from 'fs';
import path from 'path';
import yaml from 'js-yaml';
import { logger } from '../utils/logger';
import { startSession, createDriverFromSession } from '../session';
import { executeStep, setVerbose, resetAbort, setAbort, normalizeNeedLogConfig, startNSLoggerServer } from './actions';
import { LOCK_FILE, isProcessAlive } from './nslog';
import type { Driver, FlowContext, FlowStep } from './types';

export async function flowAction(filePath: string, opts: { udid?: string; bundleId?: string; verbose?: boolean }): Promise<void> {
  const resolvedPath = path.resolve(filePath);
  if (!fs.existsSync(resolvedPath)) {
    throw new Error(`Flow file not found: ${resolvedPath}`);
  }

  const flow = yaml.load(fs.readFileSync(resolvedPath, 'utf-8'), { schema: yaml.JSON_SCHEMA }) as {
    name?: string;
    app?: string;
    needLog?: boolean | Record<string, unknown>;
    steps?: Array<Record<string, unknown>>;
  };
  if (!flow || typeof flow !== 'object') {
    throw new Error(`Invalid flow file: ${resolvedPath} — must be a YAML object`);
  }
  if (!Array.isArray(flow.steps)) {
    throw new Error(`Invalid flow file: ${resolvedPath} — missing required "steps" array field`);
  }
  logger.info(`Running flow: ${flow.name || 'unnamed'} (${flow.steps.length} steps)`);

  const needLogConfig = normalizeNeedLogConfig(flow.needLog);

  if (flow.app) opts.bundleId = flow.app;
  await startSession(opts);

  const driver = await createDriverFromSession({ verbose: opts.verbose }) as Driver;

  logger.info('Executing flow...');
  setVerbose(!!opts.verbose);
  const context: FlowContext = { flowApp: flow.app, nsloggerServer: null };

  let sigintHandler: (() => void) | undefined;
  try {
    if (flow.app) {
      if (needLogConfig) {
        try {
          const pid = parseInt(fs.readFileSync(LOCK_FILE, 'utf8').trim(), 10);
          if (pid && isProcessAlive(pid)) {
            logger.warn(`Killing stale nslog process (PID ${pid})`);
            process.kill(pid, 'SIGTERM');
          }
          fs.unlinkSync(LOCK_FILE);
        } catch {}
        context.nsloggerServer = await startNSLoggerServer(needLogConfig, 'needLog');
      }
      await driver.terminateApp(flow.app);
      await driver.activateApp(flow.app);
      logger.info(`Auto terminate + activate: ${flow.app}`);
    }

    resetAbort();
    let aborted = false;
    let sigintCount = 0;
    sigintHandler = (): void => {
      sigintCount += 1;
      if (sigintCount >= 2) {
        logger.error('Forced exit on second interrupt');
        process.exit(130);
      }
      aborted = true;
      setAbort();
      logger.warn('Flow interrupted by Ctrl+C, cleaning up...');
    };
    process.on('SIGINT', sigintHandler);
    process.on('SIGTERM', sigintHandler);

    for (let i = 0; i < flow.steps.length && !aborted; i++) {
      const stepRaw = flow.steps[i];
      const step = stepRaw as unknown as FlowStep;
      const label = (step.comment || stepRaw.text || step.label || step.action) as string;
      logger.info(`Step ${i + 1}/${flow.steps.length}: ${label}`);
      try {
        await executeStep(driver, step, context, i + 1);
      } catch (err: unknown) {
        const error = err as Error;
        logger.error(`Step ${i + 1} [action: ${step.action}] failed: ${error.message}`);
        throw err;
      }
    }

    if (aborted) {
      throw new Error('Flow interrupted by Ctrl+C');
    } else {
      logger.success(`Flow completed: ${flow.steps.length} steps executed`);
    }
  } catch (err: unknown) {
    const error = err as Error;
    logger.error(`Flow failed: ${error.message}`);
    throw err;
  } finally {
    if (sigintHandler) {
      process.removeListener('SIGINT', sigintHandler);
      process.removeListener('SIGTERM', sigintHandler);
    }
    driver?.disconnect();
    if (context.nsloggerServer) {
      try {
        await context.nsloggerServer.stop();
        logger.info('NSLogger server stopped');
      } catch (e: unknown) {
        logger.warn(`NSLogger stop failed: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
  }
}
