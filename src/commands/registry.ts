import type { Command } from 'commander';
import type { Driver, FlowStep, FlowContext } from './types.js';
import type { LabelOrPoint, SwipeDir } from '../driver-protocol/index.js';

// ── Parse helpers (throw on invalid) ──

export function parseIntStrict(val: string): number {
  const n = parseInt(val, 10);
  if (!Number.isFinite(n)) throw new Error(`Invalid integer: "${val}"`);
  return n;
}

export function parseFloatStrict(val: string): number {
  const n = Number(val);
  if (!Number.isFinite(n)) throw new Error(`Invalid number: "${val}"`);
  return n;
}

// ── CLI option definition ──

export interface CliOpt {
  name: string;
  desc: string;
  parse?: (v: string) => unknown;
  default?: unknown;
  required?: boolean;
  flag?: boolean; // boolean flag like --raw, --save
}

// ── Action definition ──

export interface ActionDef {
  name: string;
  desc: string;
  execute: (driver: Driver, step: FlowStep, ctx: FlowContext) => Promise<unknown>;
  cli?: {
    args?: string[];
    opts?: CliOpt[];
    mapArgs?: (args: string[], opts: Record<string, unknown>) => Record<string, unknown>;
  };
  flowOnly?: boolean;
  invisible?: boolean;
}

// ── Offset parsing ──

function parseOffsetPair(v: string | undefined): { x?: number; y?: number } | undefined {
  if (!v) return undefined;
  const parts = v.split(',');
  const rawX = parts[0]?.trim();
  const rawY = parts[1]?.trim();
  const x = rawX ? parseFloatStrict(rawX) : undefined;
  const y = rawY ? parseFloatStrict(rawY) : undefined;
  if (x === undefined && y === undefined) return undefined;
  return { x, y };
}

function parseOffset(opts: Record<string, unknown>): FlowStep['offset'] | undefined {
  const px = parseOffsetPair(opts.offset as string | undefined);
  const ratio = parseOffsetPair(opts.offsetRatio as string | undefined);
  if (!px && !ratio) return undefined;
  return { ...px, xRatio: ratio?.x, yRatio: ratio?.y };
}

// ── Shared mapArgs helpers ──

function targetMapArgs(args: string[], opts: Record<string, unknown>): Record<string, unknown> {
  return { label: args[0], traits: opts.traits, offset: parseOffset(opts) };
}

// ── Action registry ──

export const ACTIONS = [
  {
    name: 'tap',
    desc: 'Tap on screen by label or coordinate ("x,y")',
    cli: {
      args: ['target'],
      opts: [
        { name: 'offset', desc: 'Pixel offset from target top-left as "x,y"' },
        { name: 'offset-ratio', desc: 'Ratio offset from target as "x,y" (0..1)' },
        { name: 'traits', desc: 'Filter by traits (comma-separated). AND semantics.' },
      ],
      mapArgs: targetMapArgs,
    },
    execute: () => { throw new Error('tap handler not registered'); },
  },
  {
    name: 'longpress',
    desc: 'Long press on screen by label or coordinate ("x,y")',
    cli: {
      args: ['target'],
      opts: [
        { name: 'duration', desc: 'Duration in ms', parse: parseIntStrict },
        { name: 'traits', desc: 'Filter by traits (comma-separated). AND semantics.' },
      ],
      mapArgs: targetMapArgs,
    },
    execute: () => { throw new Error('longpress handler not registered'); },
  },
  {
    name: 'input',
    desc: 'Type text into an element',
    cli: {
      opts: [
        { name: 'label', desc: 'Element label or "x,y" coordinate', required: true },
        { name: 'content', desc: 'Text to type', required: true },
        { name: 'traits', desc: 'Filter by traits (comma-separated). AND semantics.' },
      ],
    },
    execute: () => { throw new Error('input handler not registered'); },
  },
  {
    name: 'swipe',
    desc: 'Swipe on screen',
    cli: {
      opts: [
        { name: 'to', desc: 'Target label or "x,y" (scroll until visible)' },
        { name: 'from', desc: 'Anchor label or "x,y" to scroll from' },
        { name: 'dir', desc: 'Direction: forth (down/right) or back (up/left)' },
        { name: 'distance', desc: 'Swipe distance in pixels', parse: parseFloatStrict },
        { name: 'traits', desc: 'Filter by traits (comma-separated). AND semantics.' },
      ],
    },
    execute: () => { throw new Error('swipe handler not registered'); },
  },
  {
    name: 'dom',
    desc: 'Dump current UI DOM tree',
    cli: {
      opts: [
        { name: 'raw', desc: 'Output raw snapshot as indented text (skip clean tree)', flag: true },
        { name: 'fresh', desc: 'Invalidate cache and take a fresh snapshot', flag: true },
      ],
    },
    execute: () => { throw new Error('dom handler not registered'); },
  },
  {
    name: 'find',
    desc: 'Find UI element by label',
    cli: {
      args: ['label'],
      opts: [
        { name: 'traits', desc: 'Filter by traits (comma-separated). AND semantics.' },
      ],
    },
    execute: () => { throw new Error('find handler not registered'); },
  },
  {
    name: 'screenshot',
    desc: 'Take a screenshot (saved as .jpg)',
    cli: {
      opts: [
        { name: 'name', desc: 'Filename prefix', default: 'screenshot' },
      ],
    },
    execute: () => { throw new Error('screenshot handler not registered'); },
  },
  {
    name: 'waitFor',
    desc: 'Wait until an element becomes visible',
    cli: {
      opts: [
        { name: 'label', desc: 'Element label to wait for', required: true },
        { name: 'timeout', desc: 'Timeout in seconds', parse: parseFloatStrict },
        { name: 'traits', desc: 'Filter by traits (comma-separated). AND semantics.' },
      ],
    },
    execute: () => { throw new Error('waitFor handler not registered'); },
  },
  {
    name: 'activateApp',
    desc: 'Launch or foreground an app by bundle ID',
    cli: {
      args: ['bundleId'],
    },
    execute: () => { throw new Error('activateApp handler not registered'); },
  },
  {
    name: 'terminateApp',
    desc: 'Terminate an app by bundle ID',
    cli: {
      args: ['bundleId'],
    },
    execute: () => { throw new Error('terminateApp handler not registered'); },
  },
  {
    name: 'openURL',
    desc: 'Open a URL on the device',
    cli: {
      opts: [
        { name: 'url', desc: 'URL to open', required: true },
      ],
    },
    execute: () => { throw new Error('openURL handler not registered'); },
  },
  {
    name: 'dismissAlert',
    desc: 'Dismiss the current system alert',
    cli: {
      opts: [
        { name: 'index', desc: 'Button index to tap (0-based, default: last)', parse: parseIntStrict },
      ],
    },
    execute: () => { throw new Error('dismissAlert handler not registered'); },
  },
  {
    name: 'oslog',
    desc: 'Fetch iOS system logs from the device',
    cli: {
      opts: [
        { name: 'pattern', desc: 'Regex pattern to filter logs' },
        { name: 'flags', desc: 'Regex flags' },
        { name: 'timeout', desc: 'Timeout in seconds', parse: parseFloatStrict },
        { name: 'name', desc: 'Output filename prefix' },
        { name: 'clear', desc: 'Clear log buffer and return cleared count', flag: true },
        { name: 'bundle-id', desc: 'Filter logs by app bundle ID' },
      ],
    },
    execute: () => { throw new Error('oslog handler not registered'); },
  },
  // Flow-only actions (no CLI registration)
  {
    name: 'sleep',
    desc: 'Wait for a duration',
    flowOnly: true,
    invisible: true,
    execute: () => Promise.resolve(undefined),
  },
  {
    name: 'nslog',
    desc: 'Poll NSLogger for matching log',
    flowOnly: true,
    execute: () => Promise.resolve(undefined),
  },
] as const;

export type ActionName = typeof ACTIONS[number]['name'];

const ACTION_MAP = new Map(ACTIONS.map(a => [a.name, a]));

export function getActionDef(name: string): ActionDef | undefined {
  return ACTION_MAP.get(name);
}

export function getCliActions(): ActionDef[] {
  return ACTIONS.filter(a => !a.flowOnly);
}

/** Default CLI opts → FlowStep mapper for actions without custom mapArgs */
export function mapCliToStep(
  def: ActionDef,
  args: string[],
  opts: Record<string, unknown>,
): FlowStep {
  const step: Record<string, unknown> = { action: def.name };

  // Map positional args
  if (def.cli?.args) {
    for (let i = 0; i < def.cli.args.length; i++) {
      if (args[i] !== undefined) step[def.cli.args[i]] = args[i];
    }
  }

  // Custom mapping
  if (def.cli?.mapArgs) {
    Object.assign(step, def.cli.mapArgs(args, opts));
  }

  // Map opts → step fields (camelCase)
  for (const [key, val] of Object.entries(opts)) {
    if (key === 'udid' || key === 'verbose') continue;
    const camel = key.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    if (val !== undefined && step[camel] === undefined) step[camel] = val;
  }

  // CLI always prints
  if (!step.print) step.print = true;

  return step as unknown as FlowStep;
}
