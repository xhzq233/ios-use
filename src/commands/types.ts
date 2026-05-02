import type { NSLoggerServer } from '../nslogger.js';
import type {
  DomResponse,
  LabelContext,
  FindResult,
  FindArgs,
  SwipeArgs,
  SwipeResult,
  TapResult,
  LabelOrPoint,
  WaitForArgs,
  WaitForResult,
  OslogArgs,
  OslogResult,
  SwipeDir,
} from '../driver-protocol/index.js';

/**
 * Driver interface consumed by actions.ts and flow.ts.
 * Maps 1:1 to host API commands (docs/api/api_des.md §1.2).
 */
export interface Driver {
  // DOM / find
  dom(opts?: { raw?: boolean }): Promise<DomResponse>;
  find(args: FindArgs): Promise<FindResult>;

  // Interaction
  tap(target: LabelOrPoint, context?: LabelContext): Promise<TapResult>;
  longPress(target: LabelOrPoint, duration?: number, context?: LabelContext): Promise<TapResult>;
  input(label: string, content: string, context?: LabelContext): Promise<void>;
  swipe(args: SwipeArgs): Promise<SwipeResult>;
  waitFor(args: WaitForArgs): Promise<WaitForResult>;

  // App
  activateApp(bundleId: string): Promise<void>;
  terminateApp(bundleId: string): Promise<void>;

  // Screenshot / logs
  screenshot(): Promise<Buffer>;
  saveScreenshot(filepath: string): Promise<void>;
  oslog(args: OslogArgs): Promise<OslogResult>;

  // Lifecycle
  deleteSession(): Promise<void>;
  disconnect(): void;
}

/** FlowStep actions map 1:1 to host API commands (plus nslog_* as a separate client system). */
export interface FlowStep {
  action:
    | 'tap'
    | 'input'
    | 'swipe'
    | 'longpress'
    | 'dom'
    | 'find'
    | 'screenshot'
    | 'waitFor'
    | 'activateApp'
    | 'terminateApp'
    | 'oslog'
    | 'nslog_start'
    | 'nslog'
    | 'nslog_clear';

  // Label / context (tap/longpress/input/find/swipe/waitFor)
  label?: LabelOrPoint;
  content?: string;
  context?: LabelContext;

  // Swipe
  to?: LabelOrPoint;
  from?: LabelOrPoint;
  dir?: SwipeDir;
  distance?: number;

  // longPress
  duration?: number;

  // DOM
  raw?: boolean;

  // Save / print / name (DOM / screenshot / oslog)
  save?: boolean;
  name?: string;
  print?: boolean;

  // App
  bundleId?: string;

  // oslog
  pattern?: string;
  flags?: string;
  clear?: boolean;

  // waitFor
  timeout?: number;
  interval?: number;

  // nslog (client-side only)
  port?: number;
  ssl?: boolean;
  publishBonjour?: boolean;
  maxBufferSize?: number;
  clearAfterRead?: boolean;
  intervalMs?: number;

  comment?: string;
}

export interface FlowContext {
  flowApp?: string;
  nsloggerServer?: NSLoggerServer | null;
}

export interface NSLoggerServerLike {
  grep(pattern: string, flags?: string): string[];
  getLogCount(): number;
  clear(): void;
  getPort(): number;
}
