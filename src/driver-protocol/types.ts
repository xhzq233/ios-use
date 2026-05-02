/** Wire-protocol types matching host API design (docs/api/api_des.md). */

export type Point = [number, number];
export type Rect = [number, number, number, number];
export type LabelOrPoint = string | Point;
export type SwipeDir = 'forth' | 'back';

export interface LabelContext {
  ancestorType?: string;
  ancestorLabel?: string;
}

export interface CreateSessionResponse {
  bundleId?: string;
}

// DOM nodes may carry a label on containers as well, which is useful for
// SpringBoard-specific grouping like "Home screen icons".
export interface DomNode {
  tr: string[];
  l?: string;
  v?: string;
  r?: Rect;
  c?: DomNode[];
}

export interface DomResponse {
  app: string;
  window: [number, number];
  elements: DomNode[];
}

export interface FindMatch {
  ancestors: string[];
  type: string;
  label: string;
  value?: string;
  rect: Rect;
  traits?: string[];
}

export type FindResult =
  | { ok: true; match: FindMatch }
  | {
      ok: false;
      error: string;
      matches?: FindMatch[];
      suggestions?: string[];
      hint?: string;
    };

export interface FindArgs {
  label: string;
  context?: LabelContext;
}

export interface TapArgs {
  label: LabelOrPoint;
  context?: LabelContext;
}

export interface TapResult {
  type: string;
  label?: string;
  rect: Rect;
}

export interface LongPressArgs {
  label: LabelOrPoint;
  duration?: number;
  context?: LabelContext;
}

export interface InputArgs {
  label: string;
  content: string;
  context?: LabelContext;
}

export interface SwipeArgs {
  to?: LabelOrPoint;
  from?: LabelOrPoint;
  distance?: number;
  dir?: SwipeDir;
  context?: LabelContext;
}

export interface SwipeResult {
  ancestors: string[];
  type: string;
  label?: string;
  rect: Rect;
  scrolls: number;
}

export interface WaitForArgs {
  label: string;
  timeout?: number;
  interval?: number;
  context?: LabelContext;
}

export interface WaitForResult {
  type: string;
  label: string;
  rect: Rect;
  waited: number;
}

export interface OslogArgs {
  pattern?: string;
  flags?: string;
  name?: string;
  clear?: boolean;
  bundleId?: string;
}

export type OslogResult =
  | { cleared: number }
  | { matched: number; total: number; content: string };
