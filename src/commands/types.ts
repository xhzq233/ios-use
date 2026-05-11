import type { NSLoggerServer } from '../nslogger.js';
import type {
  LabelOrPoint,
  SwipeDir,
} from '../driver-protocol/index.js';
import type { ActionName } from './registry.js';

export interface FlowStep {
  action: ActionName;

  // Label / traits (tap/longpress/input/find/swipe/waitFor)
  label?: LabelOrPoint;
  content?: string;
  traits?: string;
  outputs?: string | string[];

  // Swipe
  to?: LabelOrPoint;
  from?: LabelOrPoint;
  dir?: SwipeDir;
  distance?: number;

  // runFlow / vars
  file?: string;
  vars?: Record<string, unknown>;

  // returnIf
  value?: unknown;
  is?: boolean | null;

  // longPress
  duration?: number;

  // DOM
  raw?: boolean;
  fresh?: boolean;
  candidates?: string[];

  // sleep
  ms?: number;

  // tap
  offset?: {
    x?: number;
    y?: number;
    xRatio?: number;
    yRatio?: number;
  };

  // Save / print / name (DOM / screenshot / oslog)
  save?: boolean;
  name?: string;
  print?: boolean;

  // App
  bundleId?: string;
  url?: string;

  // oslog
  pattern?: string;
  flags?: string;
  clear?: boolean;

  // waitFor
  timeout?: number;

  // nslog (client-side only)
  port?: number;
  ssl?: boolean;
  publishBonjour?: boolean;
  maxBufferSize?: number;
  clearAfterRead?: boolean;

  comment?: string;
}

export interface FlowContext {
  flowApp?: string;
  nsloggerServer?: NSLoggerServer | null;
  vars?: Record<string, unknown>;
}

export interface NSLoggerServerLike {
  grep(pattern: string, flags?: string): string[];
  clear(): void;
  getPort(): number;
  clients: Map<string, unknown>;
}
