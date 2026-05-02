import fs from 'fs';
import path from 'path';
import { logger } from '../utils/logger.js';
import { withAutoSession } from '../session.js';
import { NSLoggerServer, formatBonjourStatusMessages } from '../nslogger.js';
import { ARTIFACT_DIR, ensureArtifactDir } from '../utils/paths.js';
import type { Driver, FlowStep, FlowContext, NSLoggerServerLike } from './types.js';
import type {
  LabelContext,
  LabelOrPoint,
  Point,
  SwipeDir,
  DomNode,
} from '../driver-protocol/index.js';

// ── Utilities ──

function outputPath(filename: string) {
  ensureArtifactDir();
  if (!/^[a-zA-Z0-9_-]+(\.[a-zA-Z0-9]+)?$/.test(filename)) {
    throw new Error(`Invalid filename: "${filename}"`);
  }
  return path.join(ARTIFACT_DIR, filename);
}

const TIMESTAMP_RE = /[:.]/g;
function timestamp() {
  return new Date().toISOString().replace(TIMESTAMP_RE, '-');
}

function requireDriver(driver: Driver | null, action: string) {
  if (!driver) throw new Error(`${action} requires an active session`);
}

let _verbose = false;
export function setVerbose(v: boolean) { _verbose = v; }

/**
 * Parse a label input: if it looks like `"x,y"` return a Point tuple,
 * otherwise return the string as-is. Accepts existing Point/string values.
 */
export function parseLabelOrPoint(v: LabelOrPoint | undefined): LabelOrPoint | undefined {
  if (v === undefined) return undefined;
  if (typeof v !== 'string') return v;
  const m = v.match(/^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$/);
  if (m) return [Number(m[1]), Number(m[2])] as Point;
  return v;
}

function formatLabel(v: LabelOrPoint): string {
  return Array.isArray(v) ? `(${v[0]},${v[1]})` : `"${v}"`;
}

// ── Abort / Sleep ──

let _aborted = false;
export function isAborted() { return _aborted; }
export function resetAbort() { _aborted = false; }
export function setAbort() { _aborted = true; }

export function sleep(ms: number) {
  ms = Math.max(0, Number.isFinite(ms) ? ms : 0);
  return new Promise<void>((resolve, reject) => {
    if (_aborted) return reject(new Error('Flow interrupted'));
    if (ms <= 200) {
      setTimeout(() => {
        if (_aborted) reject(new Error('Flow interrupted')); else resolve();
      }, ms);
      return;
    }
    const timer = setTimeout(() => { clearInterval(check); resolve(); }, ms);
    const check = setInterval(() => {
      if (_aborted) { clearTimeout(timer); clearInterval(check); reject(new Error('Flow interrupted')); }
    }, 500);
  });
}

// ── NSLogger ──

export async function startNSLoggerServer(step: FlowStep | Record<string, unknown> = {}, reason = 'nslog_start') {
  const s = step as FlowStep;
  const rawPort = s.port || 0;
  const port = Number.isFinite(rawPort) && rawPort >= 0 && rawPort <= 65535 ? Math.floor(rawPort) : 0;
  const useSSL = s.ssl ?? true;
  const server = new NSLoggerServer({
    port,
    useSSL,
    bonjourName: s.name || '',
    publishBonjour: s.publishBonjour !== false,
    maxBufferSize: s.maxBufferSize,
  });
  await server.start();
  const actualPort = server.getPort();
  logger.info(`  → ${reason}: listening on port ${actualPort} (${useSSL ? 'SSL' : 'plain'})`);
  const bonjourMessages = formatBonjourStatusMessages(server.getBonjourStatus(), { prefix: '  → ' });
  for (const entry of bonjourMessages) {
    logger[entry.level as 'info' | 'warn'](entry.message);
  }
  return server;
}

export function waitForNslogMatch(server: NSLoggerServerLike, pattern: string, flags = '', timeoutSeconds = 0, intervalMs = 200) {
  const timeoutMs = Math.max(0, (Number.isFinite(timeoutSeconds) ? timeoutSeconds : 0) * 1000);
  const startedAt = Date.now();

  return new Promise<string[]>((resolve) => {
    if (timeoutMs === 0) {
      try { resolve(server.grep(pattern, flags)); } catch { resolve([]); }
      return;
    }
    const interval = setInterval(() => {
      try {
        const matched = server.grep(pattern, flags);
        if (matched.length > 0 || Date.now() - startedAt >= timeoutMs) {
          clearInterval(interval);
          resolve(matched);
        }
      } catch {
        clearInterval(interval);
        resolve([]);
      }
    }, intervalMs);
  });
}

export function normalizeNeedLogConfig(needLog: boolean | Record<string, unknown> | null | undefined) {
  if (!needLog) return null;
  if (needLog === true) return {};
  if (typeof needLog === 'object') return needLog;
  throw new Error('needLog must be true or an object');
}

// ── Action execution (maps 1:1 to host API commands) ──

const VALID_ACTIONS = new Set([
  'tap', 'input', 'swipe', 'longpress', 'dom', 'find', 'screenshot',
  'waitFor',
  'activateApp', 'terminateApp', 'oslog',
  'nslog_start', 'nslog', 'nslog_clear',
]);

export async function executeStep(driver: Driver | null, step: FlowStep, context: FlowContext = {}, stepIndex?: number) {
  const flowApp = context.flowApp;

  switch (step.action) {
    case 'dom': {
      requireDriver(driver, 'dom');
      const result = await driver!.dom({ raw: !!step.raw });
      if (step.save) {
        const domName = step.name || `dom-step-${timestamp()}`;
        const filepath = outputPath(`${domName}.json`);
        fs.writeFileSync(filepath, JSON.stringify(result, null, 2));
        logger.success(`DOM saved: ${filepath}`);
      }
      if (step.print ?? true) {
        console.log(`\n  App: ${result.app}, Window: ${result.window.join('x')}`);
        console.log('  Elements:\n');
        printDomElements(result.elements, '  ');
        console.log('');
      }
      break;
    }

    case 'find': {
      requireDriver(driver, 'find');
      const label = step.label;
      if (typeof label !== 'string') throw new Error('find requires string "label"');
      const result = await driver!.find({ label, context: step.context });
      if (!result.ok) {
        const parts: string[] = [result.error];
        if (result.matches && result.matches.length > 0) {
          parts.push('matches:');
          for (const m of result.matches) {
            const flags = m.traits?.slice(1).join(',') || '';
            const title = m.value ? `${m.label}=${m.value}` : m.label;
            const ancestors = Array.isArray(m.ancestors) ? m.ancestors.join(' > ') : '';
            const rect = Array.isArray(m.rect) ? m.rect.join(',') : '';
            parts.push(`  [${ancestors}] ${m.type}${flags ? ` [${flags}]` : ''} "${title}" (${rect})`);
          }
        }
        if (result.suggestions && result.suggestions.length > 0) {
          parts.push(`suggestions: ${result.suggestions.join(', ')}`);
        }
        if (result.hint) parts.push(`hint: ${result.hint}`);
        throw new Error(`find "${label}" failed: ${parts.join('\n  ')}`);
      }
      if (step.print ?? true) {
        const m = result.match;
        const title = m.value ? `${m.label}=${m.value}` : m.label;
        const ancestors = Array.isArray(m.ancestors) ? m.ancestors.join(' > ') : '';
        const rect = Array.isArray(m.rect) ? m.rect.join(',') : '';
        console.log(`\n  Find "${label}":`);
        console.log(`    [${ancestors}] ${m.type} "${title}" (${rect})`);
        console.log('');
      }
      break;
    }

    case 'tap': {
      requireDriver(driver, 'tap');
      const target = parseLabelOrPoint(step.label);
      if (target === undefined) throw new Error('tap requires "label" (string or "x,y" coordinate)');
      logger.info(`  → Tap ${formatLabel(target)}`);
      const result = await driver!.tap(target, step.context);
      logger.info(`    ${result.type}${result.label ? ` "${result.label}"` : ''} (${result.rect.join(',')})`);
      break;
    }

    case 'longpress': {
      requireDriver(driver, 'longpress');
      const target = parseLabelOrPoint(step.label);
      if (target === undefined) throw new Error('longpress requires "label" (string or "x,y" coordinate)');
      // step.duration is in milliseconds (user-facing); host expects seconds
      const durationSec = step.duration !== undefined ? step.duration / 1000 : undefined;
      logger.info(`  → Longpress ${formatLabel(target)}${step.duration ? ` (${step.duration}ms)` : ''}`);
      const result = await driver!.longPress(target, durationSec, step.context);
      logger.info(`    ${result.type}${result.label ? ` "${result.label}"` : ''} (${result.rect.join(',')})`);
      break;
    }

    case 'input': {
      requireDriver(driver, 'input');
      const text = step.content;
      if (typeof text !== 'string') throw new Error('input requires "content"');
      const label = step.label;
      if (typeof label !== 'string') throw new Error('input requires string "label"');
      logger.info(`  → Input "${text}" into "${label}"`);
      await driver!.input(label, text, step.context);
      break;
    }

    case 'swipe': {
      requireDriver(driver, 'swipe');
      const to = parseLabelOrPoint(step.to);
      const from = parseLabelOrPoint(step.from);
      logger.info(`  → Swipe${to ? ` to ${formatLabel(to)}` : ''}${from ? ` from ${formatLabel(from)}` : ''}${step.dir ? ` dir=${step.dir}` : ''}${step.distance ? ` dist=${step.distance}` : ''}`);
      const result = await driver!.swipe({
        to,
        from,
        dir: step.dir as SwipeDir | undefined,
        distance: step.distance,
        context: step.context,
      });
      logger.info(`    ${result.type}${result.label ? ` "${result.label}"` : ''} scrolls=${result.scrolls}`);
      break;
    }

    case 'waitFor': {
      requireDriver(driver, 'waitFor');
      const label = step.label;
      if (typeof label !== 'string') throw new Error('waitFor requires string "label"');
      logger.info(`  → WaitFor "${label}"${step.timeout ? ` timeout=${step.timeout}s` : ''}`);
      const result = await driver!.waitFor({
        label,
        timeout: step.timeout,
        interval: step.interval,
        context: step.context,
      });
      logger.info(`    ${result.type} "${result.label}" (${result.rect.join(',')}) waited=${result.waited.toFixed(2)}s`);
      break;
    }

    case 'screenshot': {
      requireDriver(driver, 'screenshot');
      const name = step.name || `flow-step-${timestamp()}`;
      const filepath = outputPath(`${name}.jpg`);
      await driver!.saveScreenshot(filepath);
      logger.success(`Screenshot saved: ${filepath}`);
      break;
    }

    case 'activateApp': {
      requireDriver(driver, 'activateApp');
      const bundleId = step.bundleId || flowApp;
      if (!bundleId) throw new Error('activateApp requires bundleId');
      await driver!.activateApp(bundleId);
      logger.success(`App ${bundleId} activated`);
      break;
    }

    case 'terminateApp': {
      requireDriver(driver, 'terminateApp');
      const bundleId = step.bundleId || flowApp;
      if (!bundleId) throw new Error('terminateApp requires bundleId');
      await driver!.terminateApp(bundleId);
      logger.success(`App ${bundleId} terminated`);
      break;
    }

    case 'oslog': {
      requireDriver(driver, 'oslog');
      const name = step.name || `oslog-${timestamp()}`;
      const result = await driver!.oslog({
        pattern: step.pattern,
        flags: step.flags,
        name,
        clear: step.clear,
        bundleId: step.bundleId,
      });
      if ('cleared' in result) {
        logger.info(`  → oslog: cleared=${result.cleared}`);
      } else {
        const outputFile = outputPath(`${name}.log`);
        fs.writeFileSync(outputFile, result.content);
        logger.info(`  → oslog: matched=${result.matched} total=${result.total} → ${outputFile}`);
      }
      break;
    }

    case 'nslog_start': {
      if (context.nsloggerServer) {
        throw new Error(`nslog_start: server already running on port ${context.nsloggerServer.getPort()}. Use nslog_clear to reset.`);
      }
      context.nsloggerServer = await startNSLoggerServer(step, 'nslog_start');
      break;
    }

    case 'nslog': {
      if (!context.nsloggerServer) throw new Error('nslog requires nslog_start first');
      const pattern = step.pattern;
      if (!pattern) throw new Error('nslog requires "pattern"');
      const timeoutSec = step.timeout ?? 0;
      const intervalMs = step.intervalMs ?? 200;
      const matched = await waitForNslogMatch(context.nsloggerServer, pattern, step.flags || '', timeoutSec, intervalMs);
      const logName = step.name || `nslog-${timestamp()}`;
      const outputFile = outputPath(`${logName}.log`);
      fs.writeFileSync(outputFile, matched.join('\n'));
      logger.info(`  → nslog: ${matched.length} matched /${pattern}/ → ${outputFile}`);
      if (step.clearAfterRead) {
        context.nsloggerServer.clear();
        logger.info('  → nslog: buffer cleared');
      }
      break;
    }

    case 'nslog_clear': {
      if (!context.nsloggerServer) throw new Error('nslog_clear requires nslog_start first');
      context.nsloggerServer.clear();
      logger.info('  → nslog_clear: buffer cleared');
      break;
    }

    default: {
      const prefix = stepIndex !== undefined ? `Step ${stepIndex}: ` : '';
      throw new Error(`${prefix}Unknown action: "${(step as FlowStep).action}". Valid: ${[...VALID_ACTIONS].join(', ')}`);
    }
  }
}

// ── DOM tree display ──

function printDomElements(elements: DomNode[], indent: string) {
  for (const el of elements) {
    const type = el.tr[0] || '?';
    const flags = el.tr.slice(1).join(',');
    const flagStr = flags ? ` [${flags}]` : '';
    const baseTitle = el.l?.trim() || type;
    const title = el.v?.trim() ? `${baseTitle}=${el.v}` : baseTitle;

    if (Array.isArray(el.c)) {
      console.log(`${indent}${title}${flagStr}:`);
      printDomElements(el.c, indent + '  ');
      continue;
    }

    const rect = Array.isArray(el.r) ? ` (${el.r.join(',')})` : '';
    console.log(`${indent}- ${title}${flagStr}${rect}`);
  }
}

// ── runCommandStep: wraps executeStep with auto-session ──

interface CommandOpts {
  verbose?: boolean;
  bundleId?: string;
  udid?: string;
  [key: string]: unknown;
}

export async function runCommandStep(step: FlowStep, opts: CommandOpts = {}, context: FlowContext = {}) {
  const verbose = !!opts.verbose;
  if (verbose !== _verbose) setVerbose(verbose);

  const sessionOpts: CommandOpts = { ...opts };
  if (step.action === 'activateApp' || step.action === 'terminateApp') {
    sessionOpts.bundleId = step.bundleId || opts.bundleId;
  }

  await withAutoSession(sessionOpts, async (driver: Driver) => {
    const localContext: FlowContext = {
      ...context,
      flowApp: context.flowApp ?? sessionOpts.bundleId,
    };
    await executeStep(driver, step, localContext);
  });
}

// ── CLI convenience wrappers ──

type ActionOpts = { udid?: string; bundleId?: string; verbose?: boolean };

export async function tapAction(opts: ActionOpts & { label?: string; context?: LabelContext }) {
  if (opts.label === undefined) throw new Error('tap requires --label');
  await runCommandStep({ action: 'tap', label: opts.label, context: opts.context }, opts);
}

export async function swipeAction(opts: ActionOpts & { to?: string; from?: string; dir?: SwipeDir; distance?: number; context?: LabelContext }) {
  await runCommandStep({
    action: 'swipe',
    to: opts.to,
    from: opts.from,
    dir: opts.dir,
    distance: opts.distance,
    context: opts.context,
  }, opts);
}

export async function inputAction(opts: ActionOpts & { content: string; label?: string; context?: LabelContext }) {
  if (opts.label === undefined) throw new Error('input requires --label');
  await runCommandStep({ action: 'input', content: opts.content, label: opts.label, context: opts.context }, opts);
}

export async function longpressAction(opts: ActionOpts & { label?: string; duration?: number; context?: LabelContext }) {
  if (opts.label === undefined) throw new Error('longpress requires --label');
  await runCommandStep({ action: 'longpress', label: opts.label, duration: opts.duration, context: opts.context }, opts);
}

export async function domAction(opts: ActionOpts & { raw?: boolean; save?: boolean; name?: string }) {
  await runCommandStep({ action: 'dom', raw: opts.raw, save: opts.save, name: opts.name, print: true }, opts);
}

export async function findAction(opts: ActionOpts & { label: string; context?: LabelContext }) {
  await runCommandStep({ action: 'find', label: opts.label, context: opts.context, print: true }, opts);
}

export async function screenshotAction(opts: ActionOpts & { name?: string }) {
  await runCommandStep({ action: 'screenshot', name: opts.name }, opts);
}

export async function waitForAction(opts: ActionOpts & { label: string; timeout?: number; interval?: number; context?: LabelContext }) {
  await runCommandStep({
    action: 'waitFor',
    label: opts.label,
    timeout: opts.timeout,
    interval: opts.interval,
    context: opts.context,
  }, opts);
}

export async function oslogAction(opts: ActionOpts & { pattern?: string; flags?: string; name?: string; clear?: boolean; bundleId?: string }) {
  await runCommandStep({
    action: 'oslog',
    pattern: opts.pattern,
    flags: opts.flags,
    name: opts.name,
    clear: opts.clear,
    bundleId: opts.bundleId,
  }, opts);
}
