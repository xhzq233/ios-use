import { collectSyslog } from './syslog-relay.js';
import { collectSimulatorLog } from './simulator-log.js';

const MAX_BUFFER_SIZE = 5000;

const buffers = new Map<string, string[]>();
let isSimulator = false;
let simulatorUdid = '';
let currentKey = 'real:';

function makeBufferKey(simulator: boolean, udid?: string): string {
  return `${simulator ? 'simulator' : 'real'}:${udid ?? ''}`;
}

function activeBuffer(): string[] {
  const existing = buffers.get(currentKey);
  if (existing) return existing;
  const created: string[] = [];
  buffers.set(currentKey, created);
  return created;
}

function setActiveBuffer(next: string[]): void {
  buffers.set(currentKey, next);
}

export function configureOslog(opts: { simulator: boolean; udid?: string }) {
  isSimulator = opts.simulator;
  if (opts.udid) simulatorUdid = opts.udid;
  currentKey = makeBufferKey(opts.simulator, opts.udid);
}

export function clearBuffer(): number {
  const n = activeBuffer().length;
  setActiveBuffer([]);
  return n;
}

function filterByBundleId(lines: string[], bundleId: string): string[] {
  if (!bundleId) return lines;
  // Syslog format: "May 11 15:30:45 iPhone Preferences(Preferences)[123] <Notice>: ..."
  // The process name is in parentheses: Preferences
  // Also try matching bundleId directly
  return lines.filter(line => {
    const procMatch = line.match(/^\w+\s+\d+\s+\d+:\d+:\d+\s+\S+\s+([\w-]+)/);
    if (procMatch) {
      const proc = procMatch[1];
      if (proc === bundleId || bundleId.includes(proc) || proc.includes(bundleId)) return true;
    }
    return line.includes(bundleId);
  });
}

function filterByPattern(lines: string[], pattern: string, flags: string): string[] {
  if (!pattern) return lines;
  const re = new RegExp(pattern, flags);
  return lines.filter(line => re.test(line));
}

export async function fetchOslog(opts: {
  udid: string;
  pattern?: string;
  flags?: string;
  bundleId?: string;
  timeout?: number;
  signal?: AbortSignal;
}): Promise<{ matched: number; total: number; content: string }> {
  const timeoutMs = (opts.timeout && opts.timeout > 0) ? opts.timeout * 1000 : 5000;

  // Collect new log lines from the device
  let newLines: string[];
  if (isSimulator) {
    newLines = await collectSimulatorLog(simulatorUdid || opts.udid, {
      lastSec: opts.timeout && opts.timeout > 0 ? opts.timeout : 10,
      bundleId: opts.bundleId,
    });
  } else {
    newLines = await collectSyslog(opts.udid, timeoutMs, opts.signal);
  }

  // Deduplicate against existing buffer
  let buffer = activeBuffer();
  const existing = new Set(buffer.map(l => l.trim()));
  const uniqueNew = newLines.filter(l => !existing.has(l.trim()));

  // Append to buffer
  buffer.push(...uniqueNew);
  if (buffer.length > MAX_BUFFER_SIZE) {
    buffer = buffer.slice(buffer.length - MAX_BUFFER_SIZE);
    setActiveBuffer(buffer);
  }

  // Filter by bundleId
  let filtered = opts.bundleId ? filterByBundleId(buffer, opts.bundleId) : buffer;

  // Filter by pattern
  if (opts.pattern) {
    filtered = filterByPattern(filtered, opts.pattern, opts.flags ?? '');
  }

  return {
    matched: filtered.length,
    total: buffer.length,
    content: filtered.join('\n') + '\n',
  };
}
