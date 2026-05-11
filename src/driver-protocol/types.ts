/** Wire-protocol types matching host API design (docs/api/api_des.md). */

export type Point = [number, number];
export type Rect = [number, number, number, number];
export type LabelOrPoint = string | Point;
export type SwipeDir = 'forth' | 'back';

export interface CreateSessionResponse {
  bundleId?: string;
}

// DOM nodes in cleaned mode arrive as a flat preorder array; each node carries
// `cc` (childCount) encoding tree structure. Raw mode sends a formatted string.
export interface DomNode {
  tr: string[];
  l?: string;
  v?: string;
  r?: Rect;
  cc?: number; // childCount (flat preorder mode)
}

export interface DomResponse {
  app: string;
  window: [number, number];
  elements: DomNode[];
  raw?: string;  // indented tree text (--raw mode)
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
  | { ok: true; matches: FindMatch[]; suggestions?: string[]; hint?: string }
  | { ok: false; error: string; hint?: string };

export interface FindArgs {
  label: string;
  traits?: string;
}

export interface TapArgs {
  label: LabelOrPoint;
  traits?: string;
  offset?: {
    x?: number;
    y?: number;
    xRatio?: number;
    yRatio?: number;
  };
}

export interface TapResult {
  type: string;
  label?: string;
  rect: Rect;
}

export interface LongPressArgs {
  label: LabelOrPoint;
  duration?: number;
  traits?: string;
}

export interface InputArgs {
  label: string;
  content: string;
  traits?: string;
}

export interface SwipeArgs {
  to?: LabelOrPoint;
  from?: LabelOrPoint;
  distance?: number;
  dir?: SwipeDir;
  traits?: string;
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
  traits?: string;
}

export interface WaitForResult {
  type: string;
  label: string;
  rect: Rect;
  waited: number;
}

export interface ProbeFetchArgs {
  url: string;
  timeout?: number;
}

export interface OpenURLArgs {
  url: string;
}

export interface ProbeFetchResult {
  statusCode: number;
  bodyBytes: number;
  contentType?: string;
}

export interface ProxyCAPushArgs {
  caBase64: string;
}

export interface ProxyCAPushResult {
  status: string;
}
