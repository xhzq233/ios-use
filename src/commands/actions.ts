import fs from 'fs';
import path from 'path';
import { logger } from '../utils/logger.js';
import { withAutoSession } from '../session.js';
import { NSLoggerServer, formatBonjourStatusMessages } from '../nslogger.js';
import { ARTIFACT_DIR, ensureArtifactDir } from '../utils/paths.js';
import type { Driver, FlowStep, FlowContext, NSLoggerServerLike } from './types.js';
import type {
  LabelOrPoint,
  Point,
  SwipeDir,
  DomNode,
  DomResponse,
  FindResult,
  Rect,
} from '../driver-protocol/index.js';
import { ACTIONS, getActionDef, getCliActions } from './registry.js';

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

export const LOG_POLL_INTERVAL_MS = 300;

function requireDriver(driver: Driver | null, action: string) {
  if (!driver) throw new Error(`${action} requires an active session`);
}

let _verbose = false;
export function setVerbose(v: boolean) { _verbose = v; }
export function isVerbose() { return _verbose; }

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
  logger.debug(`  → ${reason}: nslogger config ssl=${useSSL} publishBonjour=${s.publishBonjour !== false} requestedPort=${port} name=${JSON.stringify(s.name || '')}`, _verbose);
  const server = new NSLoggerServer({
    port,
    useSSL,
    bonjourName: s.name || '',
    publishBonjour: s.publishBonjour !== false,
    maxBufferSize: s.maxBufferSize,
    verbose: _verbose,
  });
  await server.start();
  const actualPort = server.getPort();
  if (_verbose) {
    logger.info(`  → ${reason}: listening on port ${actualPort} (${useSSL ? 'SSL' : 'plain'})`);
    const bonjourMessages = formatBonjourStatusMessages(server.getBonjourStatus(), { prefix: '  → ' });
    for (const entry of bonjourMessages) {
      logger[entry.level as 'info' | 'warn'](entry.message);
    }
  }
  return server;
}

export function waitForNslogMatch(server: NSLoggerServerLike, pattern: string, flags = '', timeoutSeconds = 0) {
  const timeoutMs = Math.max(0, (Number.isFinite(timeoutSeconds) ? timeoutSeconds : 0) * 1000);
  const startedAt = Date.now();

  return new Promise<string[]>((resolve, reject) => {
    if (timeoutMs === 0) {
      try { resolve(server.grep(pattern, flags)); } catch { resolve([]); }
      return;
    }
    const interval = setInterval(() => {
      if (_aborted) {
        clearInterval(interval);
        reject(new Error('Flow interrupted'));
        return;
      }
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
    }, LOG_POLL_INTERVAL_MS);
  });
}

export function normalizeSearchText(text: string): string {
  const trimmed = text.trim();
  if (!trimmed) return '';
  return trimmed
    .replace(/[\s\-_:\/()\[\]{}.,'"]/g, '')
    .toLowerCase();
}

function domNodeLabel(node: DomNode): string {
  return typeof node.l === 'string' && node.l.trim() ? node.l : typeof node.v === 'string' ? node.v : '';
}

export function domNodeOutput(node: DomNode): { type: string; label: string; rect?: Rect; value?: string } {
  const out: { type: string; label: string; rect?: Rect; value?: string } = {
    type: node.tr[0] || 'Unknown',
    label: domNodeLabel(node),
  };
  if (Array.isArray(node.r)) out.rect = node.r;
  if (typeof node.v === 'string' && node.v.trim()) out.value = node.v;
  return out;
}

function deriveDomOutput(result: DomResponse, candidates?: string[]) {
  const elements = result.elements;
  const matches: Array<{ type: string; label: string; rect?: Rect; value?: string }> = [];
  const matchedIndices = new Set<number>();

  for (const candidate of candidates ?? []) {
    const normalizedCandidate = normalizeSearchText(candidate);
    if (!normalizedCandidate) continue;
    for (let i = 0; i < elements.length; i++) {
      if (matchedIndices.has(i)) continue;
      const node = elements[i];
      const normalizedTexts = [node.l, node.v]
        .filter((value): value is string => typeof value === 'string' && value.trim().length > 0)
        .map((value) => normalizeSearchText(value));
      if (normalizedTexts.some((value) => value.includes(normalizedCandidate))) {
        matchedIndices.add(i);
        matches.push(domNodeOutput(node));
      }
    }
  }

  return {
    dom: result,
    matches,
    firstMatch: matches[0] ?? null,
  };
}


export function normalizeNeedLogConfig(needLog: boolean | Record<string, unknown> | null | undefined) {
  if (!needLog) return null;
  if (needLog === true) return {};
  if (typeof needLog === 'object') return needLog;
  throw new Error('needLog must be true or an object');
}

// ── DOM tree display ──

function printDomElements(elements: DomNode[], indent: string) {
  let idx = 0;
  while (idx < elements.length) {
    idx = printDomFlatSubtree(elements, idx, indent, 0);
  }
}

// Print one subtree from a flat preorder array. Returns index after the subtree.
function printDomFlatSubtree(elements: DomNode[], index: number, baseIndent: string, depth: number): number {
  const el = elements[index];
  const { line, isContainer } = formatDomLine(el);
  const padding = baseIndent + '  '.repeat(depth);

  if (isContainer) {
    console.log(`${padding}${line}:`);
    let childIdx = index + 1;
    for (let i = 0; i < (el.cc ?? 0); i++) {
      if (childIdx >= elements.length) break;
      childIdx = printDomFlatSubtree(elements, childIdx, baseIndent, depth + 1);
    }
    return childIdx;
  }

  const rect = Array.isArray(el.r) ? ` (${el.r.join(',')})` : '';
  console.log(`${padding}- ${line}${rect}`);
  return index + 1;
}

function formatDomLine(el: DomNode): { line: string; isContainer: boolean } {
  const type = el.tr[0] || '?';
  const flags = el.tr.slice(1).join(',');
  const allTraits = flags ? `${type},${flags}` : type;
  const flagStr = ` [${allTraits}]`;

  const label = el.l?.trim();
  const value = el.v?.trim();
  let title: string;
  if (label) {
    title = value ? `${label}=${value}` : label;
  } else if (value) {
    title = `=${value}`;
  } else {
    title = type;
  }

  const isContainer = (el.cc ?? 0) > 0;
  return { line: `${title}${flagStr}`, isContainer };
}

// ── Action handlers (registered into ACTIONS) ──

function registerHandlers() {
  const handlerMap: Record<string, (driver: Driver, step: FlowStep, ctx: FlowContext) => Promise<unknown>> = {

    async dom(driver, step) {
      requireDriver(driver, 'dom');
      const result = await driver.dom({ raw: !!step.raw, fresh: !!step.fresh });
      if (step.print ?? true) {
        if (result.raw) {
          console.log(`\n  App: ${result.app}, Window: ${result.window.join('x')}`);
          console.log(result.raw);
          console.log('');
        } else {
          console.log(`\n  App: ${result.app}, Window: ${result.window.join('x')}`);
          console.log('  Elements:\n');
          printDomElements(result.elements, '  ');
          console.log('');
        }
      }
      return deriveDomOutput(result, step.candidates);
    },

    async find(driver, step) {
      requireDriver(driver, 'find');
      const label = step.label;
      if (typeof label !== 'string') throw new Error('find requires string "label"');
      const result = await driver.find({ label, traits: step.traits });
      if (!result.ok) {
        throw new Error(`label '${label}' not found`);
      }
      if (step.print ?? true) {
        const { matches, suggestions, hint } = result;
        if (matches.length === 0) {
          console.log(`\n  Find "${label}" (0 matches, did you mean?):`);
          if (suggestions && suggestions.length > 0) {
            console.log(`    suggestions: ${suggestions.join(', ')}`);
          }
        } else if (matches.length === 1) {
          const m = matches[0];
          const title = m.value ? `${m.label}=${m.value}` : m.label;
          const ancestors = Array.isArray(m.ancestors) ? m.ancestors.join(' > ') : '';
          const rect = Array.isArray(m.rect) ? m.rect.join(',') : '';
          console.log(`\n  Find "${label}":`);
          console.log(`    [${ancestors}] ${m.type} "${title}" (${rect})`);
        } else {
          console.log(`\n  Find "${label}" (${matches.length} matches):`);
          for (let i = 0; i < matches.length; i++) {
            const m = matches[i];
            const title = m.value ? `${m.label}=${m.value}` : m.label;
            const ancestors = Array.isArray(m.ancestors) ? m.ancestors.join(' > ') : '';
            const rect = Array.isArray(m.rect) ? m.rect.join(',') : '';
            console.log(`    ${i + 1}. [${ancestors}] ${m.type} "${title}" (${rect})`);
          }
        }
        if (hint) console.log(`  hint: ${hint}`);
        console.log('');
      }
      return { matches: result.matches, firstMatch: result.matches[0] ?? null };
    },

    async tap(driver, step) {
      requireDriver(driver, 'tap');
      const target = parseLabelOrPoint(step.label);
      if (target === undefined) throw new Error('tap requires "label" (string or "x,y" coordinate)');
      logger.info(`  → Tap ${formatLabel(target)}`);
      const result = await driver.tap(target, step.traits, step.offset);
      logger.info(`    ${result.type}${result.label ? ` "${result.label}"` : ''} (${result.rect.join(',')})`);
    },

    async longpress(driver, step) {
      requireDriver(driver, 'longpress');
      const target = parseLabelOrPoint(step.label);
      if (target === undefined) throw new Error('longpress requires "label" (string or "x,y" coordinate)');
      const durationSec = step.duration !== undefined ? step.duration / 1000 : undefined;
      logger.info(`  → Longpress ${formatLabel(target)}${step.duration ? ` (${step.duration}ms)` : ''}`);
      const result = await driver.longPress(target, durationSec, step.traits);
      logger.info(`    ${result.type}${result.label ? ` "${result.label}"` : ''} (${result.rect.join(',')})`);
    },

    async input(driver, step) {
      requireDriver(driver, 'input');
      const text = step.content;
      if (typeof text !== 'string') throw new Error('input requires "content"');
      const label = step.label;
      if (typeof label !== 'string') throw new Error('input requires string "label"');
      logger.info(`  → Input "${text}" into "${label}"`);
      await driver.input(label, text, step.traits);
    },

    async swipe(driver, step) {
      requireDriver(driver, 'swipe');
      const to = parseLabelOrPoint(step.to);
      const from = parseLabelOrPoint(step.from);
      logger.info(`  → Swipe${to ? ` to ${formatLabel(to)}` : ''}${from ? ` from ${formatLabel(from)}` : ''}${step.dir ? ` dir=${step.dir}` : ''}${step.distance ? ` dist=${step.distance}` : ''}`);
      const result = await driver.swipe({
        to,
        from,
        dir: step.dir as SwipeDir | undefined,
        distance: step.distance,
        traits: step.traits,
      });
      logger.info(`    ${result.type}${result.label ? ` "${result.label}"` : ''} scrolls=${result.scrolls}`);
    },

    async waitFor(driver, step) {
      requireDriver(driver, 'waitFor');
      const label = step.label;
      if (typeof label !== 'string') throw new Error('waitFor requires string "label"');
      logger.info(`  → WaitFor "${label}"${step.timeout ? ` timeout=${step.timeout}s` : ''}`);
      const result = await driver.waitFor({
        label,
        timeout: step.timeout,
        traits: step.traits,
      });
      logger.info(`    ${result.type} "${result.label}" (${result.rect.join(',')}) waited=${result.waited.toFixed(2)}s`);
    },

    async screenshot(driver, step) {
      requireDriver(driver, 'screenshot');
      const name = step.name || `flow-step-${timestamp()}`;
      const filepath = outputPath(`${name}.jpg`);
      await driver.saveScreenshot(filepath);
      logger.success(`Screenshot saved: ${filepath}`);
    },

    async openURL(driver, step) {
      requireDriver(driver, 'openURL');
      const url = step.url || step.content;
      if (!url) throw new Error('openURL requires url');
      await driver.openURL(url);
      logger.success(`Opened URL: ${url}`);
    },

    async dismissAlert(driver, step) {
      requireDriver(driver, 'dismissAlert');
      const opts: { index?: number } = {};
      if ((step as any).index !== undefined) opts.index = (step as any).index;
      const res = await driver.dismissAlert(Object.keys(opts).length ? opts : undefined);
      if (res.dismissed) {
        logger.success(`Alert dismissed: tapped "${res.button}" (text: ${res.text})`);
      } else {
        logger.info(`No alert found: ${res.reason}`);
      }
    },

    async activateApp(driver, step, ctx) {
      requireDriver(driver, 'activateApp');
      const bundleId = step.bundleId || ctx.flowApp;
      if (!bundleId) throw new Error('activateApp requires bundleId');
      await driver.activateApp(bundleId);
      logger.success(`App ${bundleId} activated`);
    },

    async terminateApp(driver, step, ctx) {
      requireDriver(driver, 'terminateApp');
      const bundleId = step.bundleId || ctx.flowApp;
      if (!bundleId) throw new Error('terminateApp requires bundleId');
      try {
        await driver.terminateApp(bundleId);
        logger.success(`App ${bundleId} terminated`);
      } catch {
        logger.info(`App ${bundleId} not running, skipped terminate`);
      }
    },

    async oslog(driver, step) {
      requireDriver(driver, 'oslog');
      const name = step.name || `oslog-${timestamp()}`;
      const result = await driver.oslog({
        pattern: step.pattern,
        flags: step.flags,
        name,
        clear: step.clear,
        bundleId: step.bundleId,
        timeout: step.timeout,
      });
      if ('cleared' in result) {
        logger.info(`  → oslog: cleared=${result.cleared}`);
      } else {
        const outputFile = outputPath(`${name}.log`);
        fs.writeFileSync(outputFile, result.content);
        logger.info(`  → oslog: matched=${result.matched} total=${result.total} → ${outputFile}`);
      }
    },

    async nslog_start(_driver, step, ctx) {
      if (ctx.nsloggerServer) {
        throw new Error(`nslog_start: server already running on port ${ctx.nsloggerServer.getPort()}. Use nslog_clear to reset.`);
      }
      ctx.nsloggerServer = await startNSLoggerServer(step, 'nslog_start');
    },

    async nslog(_driver, step, ctx) {
      if (!ctx.nsloggerServer) throw new Error('nslog requires nslog_start first');
      const pattern = step.pattern;
      if (!pattern) throw new Error('nslog requires "pattern"');
      const timeoutSec = step.timeout ?? 0;
      const matched = await waitForNslogMatch(ctx.nsloggerServer, pattern, step.flags || '', timeoutSec);
      const logName = step.name || `nslog-${timestamp()}`;
      const outputFile = outputPath(`${logName}.log`);
      fs.writeFileSync(outputFile, matched.join('\n'));
      logger.info(`  → nslog: ${matched.length} matched /${pattern}/ → ${outputFile}`);
      if (step.clearAfterRead) {
        ctx.nsloggerServer!.clear();
        logger.info('  → nslog: buffer cleared');
      }
    },

    nslog_clear(_driver, _step, ctx) {
      if (!ctx.nsloggerServer) throw new Error('nslog_clear requires nslog_start first');
      ctx.nsloggerServer.clear();
      logger.info('  → nslog_clear: buffer cleared');
    },
  };

  for (const def of ACTIONS) {
    const handler = handlerMap[def.name];
    if (handler) def.execute = handler;
  }
}

registerHandlers();

// ── executeStep: dispatches via registry ──

export async function executeStep(driver: Driver | null, step: FlowStep, context: FlowContext = {}, stepIndex?: number): Promise<unknown> {
  const def = getActionDef(step.action);
  if (!def) {
    const prefix = stepIndex !== undefined ? `Step ${stepIndex}: ` : '';
    const valid = getCliActions().map(a => a.name);
    throw new Error(`${prefix}Unknown action: "${step.action}". Valid: ${valid.join(', ')}`);
  }
  return def.execute(driver!, step, context);
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
