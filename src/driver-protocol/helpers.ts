import { DRIVER_COMMANDS } from './commands.js';
import type { DriverCommand } from './commands.js';
import type { RequestFrame } from './frames.js';

export function omitUndefined<T extends Record<string, unknown>>(obj: T): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(obj)) {
    if (value !== undefined) out[key] = value;
  }
  return out;
}

export function createRequestFrame(command: DriverCommand, args?: Record<string, unknown>): RequestFrame {
  return { c: command, args: args ?? undefined };
}

export function isBinaryResponseCommand(command: DriverCommand): boolean {
  return command === DRIVER_COMMANDS.SCREENSHOT;
}
