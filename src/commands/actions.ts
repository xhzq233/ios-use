import fs from 'fs';
import path from 'path';
import { logger } from '../utils/logger.js';
import { withAutoSession, readSessionInfo } from '../session.js';
import { NSLoggerServer, formatBonjourStatusMessages } from '../nslogger.js';
import { ARTIFACT_DIR, ensureArtifactDir } from '../utils/paths.js';
import { DriverClient, DriverError } from '../driver-client/client.js';
import { DRIVER_COMMANDS } from '../driver-protocol/index.js';
import type { RawResponse } from '../driver-client/client.js';
import {
  tapArgsSer, longPressArgsSer, swipeArgsSer, inputArgsSer,
  waitForArgsSer, findArgsSer, domArgsSer,
  dismissAlertArgsSer,
  terminateAppArgsSer, activateAppArgsSer, openURLArgsSer,
  toForyTarget,
  deserializeElementPayload, deserializeDomPayload, deserializeFindPayload,
  deserializeSwipePayload, deserializeWaitForPayload,
  deserializeAlertPayload, deserializeSimpleStringPayload,
} from '../driver-protocol/fory.js';
import { clearBuffer, fetchOslog, configureOslog } from '../device-log/oslog.js';
import type { FlowStep, FlowContext, NSLoggerServerLike } from './types.js';
import type {
  DomNode,
  DomResponse,
  Rect,
} from '../driver-protocol/index.js';
import { getCliActions } from './registry.js';

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

function requireClient(client: DriverClient | null, action: string) {
  if (!client) throw new Error(`${action} requires an active session`);
}

let _verbose = false;
export function setVerbose(v: boolean) { _verbose = v; }
export function isVerbose() { return _verbose; }

function formatLabel(v: string | [number, number]): string {
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

  if (!Array.isArray(candidates)) {
    return { dom: result, matches, firstMatch: null };
  }

  for (const candidate of candidates) {
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

  return { dom: result, matches, firstMatch: matches[0] ?? null };
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

// ── send → driver, check ok ──

async function send(client: DriverClient, command: string, payload: Uint8Array): Promise<RawResponse> {
  const resp = await client.sendRaw(command, payload);
  if (!resp.ok) throw new DriverError(resp.error ?? `${command} failed`, resp.errorData);
  return resp;
}

// ── Action handler map ──

type ActionHandler = (client: DriverClient, step: FlowStep, ctx: FlowContext) => Promise<unknown>;

const { TAP, LONG_PRESS, INPUT, SWIPE, DOM, FIND, WAIT_FOR, SCREENSHOT,
  ACTIVATE_APP, TERMINATE_APP, OPEN_URL, DISMISS_ALERT } = DRIVER_COMMANDS;

const HANDLERS: Record<string, ActionHandler> = {

  async dom(client, step) {
    requireClient(client, 'dom');
    const payload = domArgsSer.serialize({ raw: !!step.raw, fresh: !!step.fresh });
    const resp = await send(client, DOM, payload);
    const result = deserializeDomPayload(resp.payloadBytes!);
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

  async find(client, step) {
    requireClient(client, 'find');
    const label = step.label;
    if (typeof label !== 'string') throw new Error('find requires string "label"');
    const payload = findArgsSer.serialize({ label, traits: step.traits ?? '' });
    // Use sendRaw (not send) to build a user-friendly error with hint from errorData
    const resp = await client.sendRaw(FIND, payload);
    if (!resp.ok) {
      const ed = resp.errorData as Record<string, unknown> | undefined;
      throw new Error(`label '${label}' not found${ed?.hint ? `. Hint: ${ed.hint}` : ''}`);
    }
    const data = deserializeFindPayload(resp.payloadBytes!);
    if (step.print ?? true) {
      const matches = data.matches ?? [];
      const { suggestions, hint } = data;
      if (matches.length === 0) {
        console.log(`\n  Find "${label}" (0 matches, did you mean?):`);
        if (suggestions && suggestions.length > 0) console.log(`    suggestions: ${suggestions.join(', ')}`);
      } else if (matches.length === 1) {
        const m = matches[0];
        const title = m.value ? `${m.label}=${m.value}` : m.label;
        const ancestors = m.ancestors?.join(' > ') ?? '';
        const rect = m.rect?.join(',') ?? '';
        console.log(`\n  Find "${label}":`);
        console.log(`    [${ancestors}] ${m.type} "${title}" (${rect})`);
      } else {
        console.log(`\n  Find "${label}" (${matches.length} matches):`);
        for (let i = 0; i < matches.length; i++) {
          const m = matches[i];
          const title = m.value ? `${m.label}=${m.value}` : m.label;
          const ancestors = m.ancestors?.join(' > ') ?? '';
          const rect = m.rect?.join(',') ?? '';
          console.log(`    ${i + 1}. [${ancestors}] ${m.type} "${title}" (${rect})`);
        }
      }
      if (hint) console.log(`  hint: ${hint}`);
      console.log('');
    }
    return { matches: data.matches, firstMatch: data.matches?.[0] ?? null };
  },

  async tap(client, step) {
    requireClient(client, 'tap');
    const target = step.label;
    if (target === undefined) throw new Error('tap requires "label" (string or "x,y" coordinate)');
    if (Array.isArray(target) && step.offset) throw new Error('offset requires element label, not absolute point');
    logger.info(`  → Tap ${formatLabel(target)}`);
    const offset = step.offset;
    const hasAbsolute = offset && (offset.x != null || offset.y != null);
    const payload = tapArgsSer.serialize({
      target: toForyTarget(target),
      traits: step.traits ?? '',
      offset: hasAbsolute ? { x: offset.x ?? 0, y: offset.y ?? 0 } : null,
      ratio: !hasAbsolute && (offset?.xRatio != null || offset?.yRatio != null)
        ? { x: offset.xRatio ?? 0.5, y: offset.yRatio ?? 0.5 }
        : { x: 0.5, y: 0.5 },
    });
    const resp = await send(client, TAP, payload);
    const result = deserializeElementPayload(resp.payloadBytes!);
    logger.info(`    ${result.type}${result.label ? ` "${result.label}"` : ''} (${result.rect?.join(',') ?? ''})`);
  },

  async longpress(client, step) {
    requireClient(client, 'longpress');
    const target = step.label;
    if (target === undefined) throw new Error('longpress requires "label" (string or "x,y" coordinate)');
    const durationSec = step.duration !== undefined ? step.duration / 1000 : 0;
    logger.info(`  → Longpress ${formatLabel(target)}${step.duration ? ` (${step.duration}ms)` : ''}`);
    const payload = longPressArgsSer.serialize({
      target: toForyTarget(target),
      duration: durationSec,
      traits: step.traits ?? '',
    });
    const resp = await send(client, LONG_PRESS, payload);
    const result = deserializeElementPayload(resp.payloadBytes!);
    logger.info(`    ${result.type}${result.label ? ` "${result.label}"` : ''} (${result.rect?.join(',') ?? ''})`);
  },

  async input(client, step) {
    requireClient(client, 'input');
    const text = step.content;
    if (typeof text !== 'string') throw new Error('input requires "content"');
    const label = step.label;
    if (typeof label !== 'string') throw new Error('input requires string "label"');
    logger.info(`  → Input "${text}" into "${label}"`);
    const payload = inputArgsSer.serialize({ label, content: text, traits: step.traits ?? '' });
    await send(client, INPUT, payload);
  },

  async swipe(client, step) {
    requireClient(client, 'swipe');
    const toTarget = toForyTarget(step.to);
    const fromTarget = toForyTarget(step.from);
    logger.info(`  → Swipe${step.to ? ` to ${formatLabel(step.to)}` : ''}${step.from ? ` from ${formatLabel(step.from)}` : ''}${step.dir ? ` dir=${step.dir}` : ''}${step.distance ? ` dist=${step.distance}` : ''}`);
    const payload = swipeArgsSer.serialize({
      toTarget,
      fromTarget,
      distance: step.distance ?? 0,
      dir: step.dir === 'back' ? 1 : 0,
      traits: step.traits ?? '',
    });
    const resp = await send(client, SWIPE, payload);
    const result = deserializeSwipePayload(resp.payloadBytes!);
    logger.info(`    ${result.type}${result.label ? ` "${result.label}"` : ''} scrolls=${result.scrolls}`);
  },

  async waitFor(client, step) {
    requireClient(client, 'waitFor');
    const label = step.label;
    if (typeof label !== 'string') throw new Error('waitFor requires string "label"');
    logger.info(`  → WaitFor "${label}"${step.timeout ? ` timeout=${step.timeout}s` : ''}`);
    const payload = waitForArgsSer.serialize({ label, timeout: step.timeout ?? 0, traits: step.traits ?? '' });
    const resp = await send(client, WAIT_FOR, payload);
    const result = deserializeWaitForPayload(resp.payloadBytes!);
    logger.info(`    ${result.type} "${result.label}" (${result.rect?.join(',') ?? ''}) waited=${result.waited.toFixed(2)}s`);
  },

  async screenshot(client, step) {
    requireClient(client, 'screenshot');
    const name = step.name || `flow-step-${timestamp()}`;
    const filepath = outputPath(`${name}.jpg`);
    await client.saveScreenshot(filepath);
    logger.success(`Screenshot saved: ${filepath}`);
  },

  async openURL(client, step) {
    requireClient(client, 'openURL');
    const url = step.url || step.content;
    if (!url) throw new Error('openURL requires url');
    const payload = openURLArgsSer.serialize({ url });
    const resp = await send(client, OPEN_URL, payload);
    deserializeSimpleStringPayload(resp.payloadBytes!);
    logger.success(`Opened URL: ${url}`);
  },

  async dismissAlert(client, step) {
    requireClient(client, 'dismissAlert');
    const index = (step as any).index;
    const payload = dismissAlertArgsSer.serialize({ index: index != null ? index : -1 });
    const resp = await send(client, DISMISS_ALERT, payload);
    const result = deserializeAlertPayload(resp.payloadBytes!);
    if (result.dismissed) {
      logger.success(`Alert dismissed: tapped "${result.button}" (text: ${result.text})`);
    } else {
      logger.info(`No alert found: ${result.reason}`);
    }
  },

  async activateApp(client, step, ctx) {
    requireClient(client, 'activateApp');
    const bundleId = step.bundleId || ctx.flowApp;
    if (!bundleId) throw new Error('activateApp requires bundleId');
    const payload = activateAppArgsSer.serialize({ bundleId });
    await send(client, ACTIVATE_APP, payload);
    logger.success(`App ${bundleId} activated`);
  },

  async terminateApp(client, step, ctx) {
    requireClient(client, 'terminateApp');
    const bundleId = step.bundleId || ctx.flowApp;
    if (!bundleId) throw new Error('terminateApp requires bundleId');
    try {
      const payload = terminateAppArgsSer.serialize({ bundleId });
      await send(client, TERMINATE_APP, payload);
      logger.success(`App ${bundleId} terminated`);
    } catch {
      logger.info(`App ${bundleId} not running, skipped terminate`);
    }
  },

  async oslog(_client, step, ctx) {
    if (step.clear) {
      const n = clearBuffer();
      logger.info(`  → oslog: cleared=${n}`);
      return;
    }
    const udid = ctx.udid;
    if (!udid) throw new Error('oslog requires --udid or an active session');
    configureOslog({ simulator: ctx.deviceType === 'simulator', udid });
    const result = await fetchOslog({
      udid,
      pattern: step.pattern,
      flags: step.flags,
      bundleId: step.bundleId,
      timeout: step.timeout,
    });
    const name = step.name || `oslog-${timestamp()}`;
    const outputFile = outputPath(`${name}.log`);
    fs.writeFileSync(outputFile, result.content);
    logger.info(`  → oslog: matched=${result.matched} total=${result.total} → ${outputFile}`);
  },

  async nslog(_client, step, ctx) {
    if (!ctx.nsloggerServer) throw new Error('nslog requires needNSLog in flow config');
    const pattern = step.pattern;
    if (!pattern) throw new Error('nslog requires "pattern"');
    const timeoutSec = step.timeout ?? 0;
    const t0 = Date.now();
    const matched = await waitForNslogMatch(ctx.nsloggerServer, pattern, step.flags || '', timeoutSec);
    const elapsed = Date.now() - t0;
    const logName = step.name || `nslog-${timestamp()}`;
    const outputFile = outputPath(`${logName}.log`);
    fs.writeFileSync(outputFile, matched.join('\n'));
    logger.info(`  → nslog: ${matched.length} matched /${pattern}/ in ${elapsed}ms → ${outputFile}`);
    if (step.clearAfterRead) {
      ctx.nsloggerServer!.clear();
      logger.info('  → nslog: buffer cleared');
    }
  },
};

// ── executeStep ──

export async function executeStep(client: DriverClient | null, step: FlowStep, context: FlowContext = {}, stepIndex?: number): Promise<unknown> {
  const handler = HANDLERS[step.action];
  if (!handler) {
    const prefix = stepIndex !== undefined ? `Step ${stepIndex}: ` : '';
    const valid = getCliActions().map(a => a.name);
    throw new Error(`${prefix}Unknown action: "${step.action}". Valid: ${valid.join(', ')}`);
  }
  return handler(client!, step, context);
}

// ── runCommandStep ──

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

  await withAutoSession(sessionOpts, async (client: DriverClient) => {
    const sessionInfo = readSessionInfo();
    const localContext: FlowContext = {
      ...context,
      flowApp: context.flowApp ?? sessionOpts.bundleId,
      udid: (opts.udid as string | undefined) ?? sessionInfo?.udid,
      deviceType: sessionInfo?.deviceType as 'real' | 'simulator' | undefined,
    };
    await executeStep(client, step, localContext);
  });
}
