import fs from 'fs';
import path from 'path';
import yaml from 'js-yaml';
import { logger } from '../utils/logger';
import { startSession, readSessionInfo } from '../session';
import { executeStep, sleep, setVerbose, isVerbose, resetAbort, setAbort, isAborted, normalizeNeedLogConfig, startNSLoggerServer } from './actions';
import { LOCK_FILE } from './nslog';
import { isProcessAlive } from '../utils/process.js';
import type { FlowContext, FlowStep, NSLoggerServerLike } from './types';
import type { DriverClient } from '../driver-client/client.js';

async function waitForNslogConnection(server: NSLoggerServerLike & { clients: Map<string, unknown> }, timeoutMs: number): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (server.clients.size > 0) {
      logger.info(`App connected to NSLogger (${Date.now() - start}ms)`);
      return;
    }
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  logger.warn(`Timeout waiting for app to connect to NSLogger after ${Date.now() - start}ms, continuing...`);
}

interface FlowFile {
  name?: string;
  app?: string;
  needNSLog?: boolean | Record<string, unknown>;
  vars?: Record<string, unknown>;
  outputs?: string | string[];
  steps: Array<Record<string, unknown>>;
}

function loadFlowFile(resolvedPath: string): FlowFile {
  if (!fs.existsSync(resolvedPath)) {
    throw new Error(`Flow file not found: ${resolvedPath}`);
  }

  const flow = yaml.load(fs.readFileSync(resolvedPath, 'utf-8'), { schema: yaml.JSON_SCHEMA }) as {
    name?: string;
    app?: string;
    needNSLog?: boolean | Record<string, unknown>;
    vars?: Record<string, unknown>;
    outputs?: string | string[];
    steps?: Array<Record<string, unknown>>;
  };
  if (!flow || typeof flow !== 'object') {
    throw new Error(`Invalid flow file: ${resolvedPath} — must be a YAML object`);
  }
  if (!Array.isArray(flow.steps)) {
    throw new Error(`Invalid flow file: ${resolvedPath} — missing required "steps" array field`);
  }

  return {
    name: flow.name,
    app: flow.app,
    needNSLog: flow.needNSLog,
    vars: flow.vars,
    outputs: flow.outputs,
    steps: flow.steps,
  };
}

function templateScope(vars: Record<string, unknown>): Record<string, unknown> {
  return { vars, ...vars };
}

function readTemplateValue(expr: string, vars: Record<string, unknown>): unknown {
  const pathSegments = expr.trim().split('.').filter(Boolean);
  if (pathSegments.length === 0) {
    throw new Error(`Invalid template expression: "\${${expr}}"`);
  }

  let current: unknown = templateScope(vars);
  for (const segment of pathSegments) {
    if (current === null || current === undefined || typeof current !== 'object') {
      throw new Error(`Missing template value: "\${${expr}}"`);
    }
    current = (current as Record<string, unknown>)[segment];
  }
  if (current === undefined) {
    throw new Error(`Missing template value: "\${${expr}}"`);
  }
  return current;
}

function resolveTemplates<T>(value: T, vars: Record<string, unknown>): T {
  if (typeof value === 'string') {
    const wholeExpr = value.match(/^\$\{([^}]+)\}$/);
    if (wholeExpr) {
      return readTemplateValue(wholeExpr[1], vars) as T;
    }
    return value.replace(/\$\{([^}]+)\}/g, (_, expr: string) => {
      const resolved = readTemplateValue(expr, vars);
      return String(resolved);
    }) as T;
  }
  if (Array.isArray(value)) {
    return value.map((item) => resolveTemplates(item, vars)) as T;
  }
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [key, nested] of Object.entries(value as Record<string, unknown>)) {
      out[key] = resolveTemplates(nested, vars);
    }
    return out as T;
  }
  return value;
}

function resolveVars(rawVars: Record<string, unknown> | undefined, inheritedVars: Record<string, unknown>): Record<string, unknown> {
  const resolvedVars: Record<string, unknown> = { ...inheritedVars };
  if (!rawVars) return resolvedVars;

  for (const [key, rawValue] of Object.entries(rawVars)) {
    if (Object.prototype.hasOwnProperty.call(inheritedVars, key)) {
      continue;
    }
    resolvedVars[key] = resolveTemplates(rawValue, resolvedVars);
  }
  return resolvedVars;
}

function normalizeOutputNames(raw: string | string[] | undefined, fieldName: string, allowMultiple: boolean): string[] {
  if (raw === undefined) return [];
  const names = Array.isArray(raw) ? raw : [raw];
  if (!allowMultiple && names.length > 1) {
    throw new Error(`${fieldName} must be a single variable name`);
  }
  if (names.some((name) => typeof name !== 'string' || !name.trim())) {
    throw new Error(`${fieldName} must contain non-empty variable names`);
  }
  return names.map((name) => name.trim());
}

function collectFlowOutputs(flow: FlowFile, vars: Record<string, unknown>): Record<string, unknown> {
  const outputNames = normalizeOutputNames(flow.outputs, 'flow outputs', true);
  const out: Record<string, unknown> = {};
  for (const name of outputNames) {
    out[name] = Object.prototype.hasOwnProperty.call(vars, name) ? vars[name] ?? null : null;
  }
  return out;
}

function ensureNotAborted(): void {
  if (isAborted()) {
    throw new Error('Flow interrupted by Ctrl+C');
  }
}

function assertNoRunFlowCycle(flowStack: string[], childPath: string): void {
  const cycleStart = flowStack.indexOf(childPath);
  if (cycleStart === -1) return;
  const cycleChain = [...flowStack.slice(cycleStart), childPath];
  throw new Error(`runFlow cycle detected: ${cycleChain.join(' -> ')}`);
}

function formatReturnIfTarget(target: boolean | null): string {
  return target === null ? 'null' : String(target);
}

function syncSharedFlowState(target: FlowContext, source: FlowContext): void {
  target.nsloggerServer = source.nsloggerServer ?? null;
}

async function executeFlowSteps(
  driver: DriverClient,
  flow: FlowFile,
  resolvedPath: string,
  context: FlowContext,
  inheritedVars: Record<string, unknown> = {},
  flowStack: string[] = [],
): Promise<Record<string, unknown>> {
  const currentPath = path.resolve(resolvedPath);
  const flowVars = resolveVars(flow.vars, inheritedVars);
  const flowApp = flow.app ? resolveTemplates(flow.app, flowVars) : context.flowApp;
  const flowContext: FlowContext = { ...context, flowApp, vars: flowVars };
  const nextFlowStack = [...flowStack, currentPath];

  const visibleSteps = flow.steps.filter(s => (s as Record<string, unknown>).action !== 'sleep').length;
  logger.info(`Running flow: ${flow.name || 'unnamed'} (${visibleSteps} steps)`);
  let stepNum = 0;

  for (let i = 0; i < flow.steps.length; i++) {
    ensureNotAborted();
    const stepRaw = flow.steps[i];
    const step = resolveTemplates(stepRaw, flowVars) as unknown as FlowStep;

    if (step.action === 'sleep') {
      const ms = step.ms ?? 1000;
      if (isVerbose()) logger.info(`  → Sleep ${ms}ms`);
      await sleep(ms);
      continue;
    }

    stepNum++;
    const label = (step.comment || stepRaw.text || step.label || step.action) as string;
    logger.info(`Step ${stepNum}/${visibleSteps}: ${label}`);

    try {
      if (step.action === 'returnIf') {
        if (!Object.prototype.hasOwnProperty.call(stepRaw, 'value')) {
          throw new Error('returnIf requires "value"');
        }
        if (step.is !== true && step.is !== false && step.is !== null) {
          throw new Error('returnIf requires "is" to be true, false, or null');
        }
        if (step.value === step.is) {
          logger.info(`returnIf matched is=${formatReturnIfTarget(step.is)}, returning current flow`);
          ensureNotAborted();
          return collectFlowOutputs(flow, flowVars);
        }
        continue;
      }

      if (step.action === 'runFlow') {
        const file = step.file;
        if (typeof file !== 'string' || !file.trim()) {
          throw new Error('runFlow requires "file"');
        }
        const childPath = path.isAbsolute(file) ? file : path.resolve(path.dirname(resolvedPath), file);
        assertNoRunFlowCycle(nextFlowStack, childPath);
        const childFlow = loadFlowFile(childPath);
        const childVars = step.vars && typeof step.vars === 'object'
          ? (step.vars as Record<string, unknown>)
          : {};
        const childOutputs = await executeFlowSteps(driver, childFlow, childPath, flowContext, {
          ...flowVars,
          ...resolveTemplates(childVars, flowVars),
        }, nextFlowStack);
        syncSharedFlowState(context, flowContext);
        ensureNotAborted();
        for (const outputName of normalizeOutputNames(step.outputs, 'runFlow outputs', true)) {
          if (!Object.prototype.hasOwnProperty.call(childOutputs, outputName)) {
            throw new Error(`runFlow requested undeclared output "${outputName}" from ${childPath}`);
          }
          flowVars[outputName] = childOutputs[outputName];
        }
        continue;
      }

      const actionOutput = await executeStep(driver, step, flowContext, i + 1);
      syncSharedFlowState(context, flowContext);
      const outputNames = normalizeOutputNames(step.outputs, `${step.action} outputs`, false);
      if (outputNames.length === 0) {
        continue;
      }
      if (actionOutput === undefined) {
        throw new Error(`${step.action} does not support outputs`);
      }
      flowVars[outputNames[0]] = actionOutput;
    } catch (err: unknown) {
      const error = err as Error;
      logger.error(`Step ${stepNum} [action: ${step.action}] failed: ${error.message}`);
      throw err;
    }
  }

  syncSharedFlowState(context, flowContext);
  ensureNotAborted();
  return collectFlowOutputs(flow, flowVars);
}

export async function runFlowFile(
  driver: DriverClient,
  filePath: string,
  context: FlowContext = {},
  inheritedVars: Record<string, unknown> = {},
): Promise<Record<string, unknown>> {
  const resolvedPath = path.resolve(filePath);
  const flow = loadFlowFile(resolvedPath);
  return await executeFlowSteps(driver, flow, resolvedPath, context, inheritedVars);
}

export async function flowAction(filePath: string, opts: { udid?: string; bundleId?: string; verbose?: boolean }): Promise<void> {
  const resolvedPath = path.resolve(filePath);
  const flow = loadFlowFile(resolvedPath);
  const resolvedVars = resolveVars(flow.vars, {});
  const resolvedNeedNSLog = resolveTemplates(flow.needNSLog, resolvedVars);
  const resolvedApp = flow.app ? resolveTemplates(flow.app, resolvedVars) : undefined;
  const needNSLogConfig = normalizeNeedLogConfig(resolvedNeedNSLog);
  logger.debug(`flowAction: needNSLog=${JSON.stringify(resolvedNeedNSLog ?? null)} app=${JSON.stringify(resolvedApp ?? flow.app ?? null)}`, !!opts.verbose);

  if (typeof resolvedApp === 'string') opts.bundleId = resolvedApp;

  // Start NSLogger server BEFORE session so Bonjour is published when app cold-starts
  setVerbose(!!opts.verbose);
  const sessionInfo = readSessionInfo();
  const context: FlowContext = { flowApp: typeof resolvedApp === 'string' ? resolvedApp : flow.app, nsloggerServer: null, udid: opts.udid ?? sessionInfo?.udid, deviceType: sessionInfo?.deviceType };

  let sigintHandler: (() => void) | undefined;
  let driver: DriverClient | undefined;
  try {
    if (resolvedApp || flow.app) {
      if (needNSLogConfig) {
        try {
          const pid = parseInt(fs.readFileSync(LOCK_FILE, 'utf8').trim(), 10);
          if (pid && isProcessAlive(pid)) {
            logger.warn(`Killing stale nslog process (PID ${pid})`);
            process.kill(pid, 'SIGTERM');
          }
          fs.unlinkSync(LOCK_FILE);
        } catch {}
        context.nsloggerServer = await startNSLoggerServer(needNSLogConfig, 'needNSLog');
      }
      logger.info(`Target app: ${resolvedApp || flow.app}`);
    }

    driver = await startSession({ ...opts, terminate: true });
    // Refresh context from session info populated by startSession
    const freshInfo = readSessionInfo();
    if (!context.udid) context.udid = freshInfo?.udid;
    if (!context.deviceType) context.deviceType = freshInfo?.deviceType;

    if (context.nsloggerServer) {
      logger.info('Waiting for app to connect to NSLogger...');
      await waitForNslogConnection(context.nsloggerServer, 15000);
    }

    logger.info('Executing flow...');

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

    await executeFlowSteps(driver, flow, resolvedPath, context);

    if (aborted) {
      throw new Error('Flow interrupted by Ctrl+C');
    } else {
      const visibleSteps = flow.steps.filter(s => (s as Record<string, unknown>).action !== 'sleep').length;
      logger.success(`Flow completed: ${visibleSteps} steps executed`);
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
    if (context.nsloggerServer) {
      try {
        await context.nsloggerServer.stop();
      } catch (e: unknown) {
        logger.warn(`NSLogger stop failed: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    driver?.disconnect();
  }
}
