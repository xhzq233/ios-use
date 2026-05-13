import Fury from '@apache-fory/core/lib/fory';
import { Type } from '@apache-fory/core';
import type { ResponseFrame } from './frames.js';
import { DRIVER_COMMANDS } from './commands.js';
import { elementTypeName, SWIPE_DIR_FORTH, SWIPE_DIR_BACK } from './fory-constants.js';
import type { Rect, DomNode } from './types.js';

// ── Fory instance + type registration ──

const fory = new Fury();

const ForyRect = Type.struct('ForyRect', {
  x: Type.int32(), y: Type.int32(), w: Type.int32(), h: Type.int32(),
});
const ForyPoint = Type.struct('ForyPoint', {
  x: Type.float64(), y: Type.float64(),
});
const ForyTarget = Type.struct('ForyTarget', {
  label: Type.string(),
  point: ForyPoint.setNullable(true),
});

// Frames
const ForyRequestFrame = Type.struct('ForyRequestFrame', {
  command: Type.string(),
  payload: Type.binary(),
});
const ForyResponseFrame = Type.struct('ForyResponseFrame', {
  ok: Type.bool(),
  error: Type.string(),
  payload: Type.binary(),
});

// Error
const ForyFindMatch = Type.struct('ForyFindMatch', {
  elemType: Type.int32(),
  label: Type.string(),
  rect: ForyRect.setNullable(true),
  traits: Type.list(Type.string()),
  value: Type.string(),
  ancestors: Type.list(Type.string()),
});
const ForyErrorPayload = Type.struct('ForyErrorPayload', {
  hint: Type.string(),
  suggestions: Type.list(Type.string()),
  matches: Type.list(ForyFindMatch),
  atBoundary: Type.bool(),
  tooSmallToScroll: Type.bool(),
  direction: Type.int32(),
  minDragDistance: Type.float64(),
});

// Payloads
const ForyDomElement = Type.struct('ForyDomElement', {
  traits: Type.list(Type.string()),
  childCount: Type.int32(),
  label: Type.string(),
  value: Type.string(),
  rect: ForyRect.setNullable(true),
});
const ForyDomPayload = Type.struct('ForyDomPayload', {
  app: Type.string(),
  windowSize: ForyPoint,
  raw: Type.string(),
  elements: Type.list(ForyDomElement),
});
const ForyScreenshotPayload = Type.struct('ForyScreenshotPayload', {
  jpeg: Type.binary(),
});
const ForyFindPayload = Type.struct('ForyFindPayload', {
  matches: Type.list(ForyFindMatch),
  hint: Type.string(),
  suggestions: Type.list(Type.string()),
});
const ForyElementPayload = Type.struct('ForyElementPayload', {
  elemType: Type.int32(),
  label: Type.string(),
  rect: ForyRect.setNullable(true),
});
const ForySwipePayload = Type.struct('ForySwipePayload', {
  ancestors: Type.list(Type.string()),
  elemType: Type.int32(),
  label: Type.string(),
  rect: ForyRect.setNullable(true),
  scrolls: Type.int32(),
});
const ForyWaitForPayload = Type.struct('ForyWaitForPayload', {
  elemType: Type.int32(),
  label: Type.string(),
  rect: ForyRect.setNullable(true),
  waited: Type.float64(),
});
const ForyAlertPayload = Type.struct('ForyAlertPayload', {
  dismissed: Type.bool(),
  text: Type.string(),
  button: Type.string(),
  reason: Type.string(),
});
const ForyProxyPayload = Type.struct('ForyProxyPayload', {
  status: Type.string(),
});
const ForySimpleStringPayload = Type.struct('ForySimpleStringPayload', {
  value: Type.string(),
});

// Request Args
const ForyCreateSessionArgs = Type.struct('ForyCreateSessionArgs', {
  bundleId: Type.string(),
  terminate: Type.bool(),
});
const ForyActivateAppArgs = Type.struct('ForyActivateAppArgs', {
  bundleId: Type.string(),
});
const ForyTerminateAppArgs = Type.struct('ForyTerminateAppArgs', {
  bundleId: Type.string(),
});
const ForyOpenURLArgs = Type.struct('ForyOpenURLArgs', {
  url: Type.string(),
});
const ForyDomArgs = Type.struct('ForyDomArgs', {
  raw: Type.bool(),
  fresh: Type.bool(),
});
const ForyFindArgs = Type.struct('ForyFindArgs', {
  label: Type.string(),
  traits: Type.string(),
});
const ForyInputArgs = Type.struct('ForyInputArgs', {
  label: Type.string(),
  content: Type.string(),
  traits: Type.string(),
});
const ForyWaitForArgs = Type.struct('ForyWaitForArgs', {
  label: Type.string(),
  timeout: Type.float64(),
  traits: Type.string(),
});
const ForyTapArgs = Type.struct('ForyTapArgs', {
  target: ForyTarget,
  traits: Type.string(),
  offset: ForyPoint.setNullable(true),
  ratio: ForyPoint,
});
const ForyLongPressArgs = Type.struct('ForyLongPressArgs', {
  target: ForyTarget,
  duration: Type.float64(),
  traits: Type.string(),
});
const ForySwipeArgs = Type.struct('ForySwipeArgs', {
  toTarget: ForyTarget,
  fromTarget: ForyTarget,
  distance: Type.float64(),
  dir: Type.int32(),
  traits: Type.string(),
});
const ForyDismissAlertArgs = Type.struct('ForyDismissAlertArgs', {
  index: Type.int32(),
});
const ForyProxyCAPushArgs = Type.struct('ForyProxyCAPushArgs', {
  caBase64: Type.string(),
});

// ── Serializer instances ──
// Nested types must be registered before types that reference them as fields.
fory.register(ForyRect);
fory.register(ForyPoint);
fory.register(ForyTarget);
fory.register(ForyFindMatch);
fory.register(ForyDomElement);

const reqFrameSer = fory.register(ForyRequestFrame);
const respFrameSer = fory.register(ForyResponseFrame);
const errorPayloadSer = fory.register(ForyErrorPayload);

export const createSessionArgsSer = fory.register(ForyCreateSessionArgs);
export const activateAppArgsSer = fory.register(ForyActivateAppArgs);
export const terminateAppArgsSer = fory.register(ForyTerminateAppArgs);
export const openURLArgsSer = fory.register(ForyOpenURLArgs);
export const domArgsSer = fory.register(ForyDomArgs);
export const findArgsSer = fory.register(ForyFindArgs);
export const inputArgsSer = fory.register(ForyInputArgs);
export const waitForArgsSer = fory.register(ForyWaitForArgs);
export const tapArgsSer = fory.register(ForyTapArgs);
export const longPressArgsSer = fory.register(ForyLongPressArgs);
export const swipeArgsSer = fory.register(ForySwipeArgs);
export const dismissAlertArgsSer = fory.register(ForyDismissAlertArgs);
export const proxyCAPushArgsSer = fory.register(ForyProxyCAPushArgs);
export const elementPayloadSer = fory.register(ForyElementPayload);
export const domPayloadSer = fory.register(ForyDomPayload);
export const screenshotPayloadSer = fory.register(ForyScreenshotPayload);
export const findPayloadSer = fory.register(ForyFindPayload);
export const swipePayloadSer = fory.register(ForySwipePayload);
export const waitForPayloadSer = fory.register(ForyWaitForPayload);
export const alertPayloadSer = fory.register(ForyAlertPayload);
export const proxyPayloadSer = fory.register(ForyProxyPayload);
export const simpleStringPayloadSer = fory.register(ForySimpleStringPayload);

// ── Request frame ──

export function serializeRequestFrame(command: string, argsPayload: Uint8Array): Uint8Array {
  return reqFrameSer.serialize({ command, payload: argsPayload });
}

// ── Response frame ──

export interface RawResponse {
  ok: boolean;
  error?: string;
  payloadBytes?: Uint8Array;
  errorData?: Record<string, unknown>;
}

export function deserializeResponse(data: Uint8Array): RawResponse {
  const outer = respFrameSer.deserialize(data);

  if (!outer.ok) {
    const errorData = outer.payload.length > 0
      ? parseError(outer.payload)
      : undefined;
    return { ok: false, error: outer.error, errorData };
  }

  if (outer.payload.length === 0) return { ok: true };

  return { ok: true, payloadBytes: outer.payload };
}

// ── Label/Point conversion ──

const COORD_RE = /^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$/;

export function toForyTarget(label: unknown): { label: string; point: { x: number; y: number } | null } {
  if (typeof label === 'string') {
    const m = label.match(COORD_RE);
    if (m) return { label: '', point: { x: Number(m[1]), y: Number(m[2]) } };
    return { label, point: null };
  }
  if (Array.isArray(label) && label.length === 2) {
    const [x, y] = label;
    if (typeof x !== 'number' || typeof y !== 'number' || !Number.isFinite(x) || !Number.isFinite(y)) {
      throw new Error('Invalid coordinate point: expected [number, number]');
    }
    return { label: '', point: { x, y } };
  }
  return { label: '', point: null };
}

// ── Deserialized payload types ──

export interface FindMatchDict {
  type: string;
  label: string;
  traits: string[];
  value?: string;
  rect?: Rect;
  ancestors?: string[];
}

// ── Deserializer helpers ──

function foryRectToArray(rect: { x: number; y: number; w: number; h: number } | null): Rect | undefined {
  if (!rect) return undefined;
  return [rect.x, rect.y, rect.w, rect.h];
}

function foryDomElementToDict(el: any): DomNode {
  const result: DomNode = {
    tr: el.traits ?? [],
    cc: el.childCount,
  };
  if (el.label) result.l = el.label;
  if (el.value) result.v = el.value;
  if (el.rect) result.r = [el.rect.x, el.rect.y, el.rect.w, el.rect.h];
  return result;
}

function foryFindMatchToDict(m: any): FindMatchDict {
  const result: FindMatchDict = {
    type: elementTypeName(m.elemType),
    label: m.label ?? '',
    traits: m.traits ?? [],
  };
  if (m.value) result.value = m.value;
  if (m.rect) result.rect = [m.rect.x, m.rect.y, m.rect.w, m.rect.h];
  if (m.ancestors?.length) result.ancestors = m.ancestors;
  return result;
}

function parseError(data: Uint8Array): Record<string, unknown> {
  const p = errorPayloadSer.deserialize(data);
  const result: Record<string, unknown> = {};
  if (p.hint) result.hint = p.hint;
  if (p.suggestions?.length) result.suggestions = p.suggestions;
  if (p.matches?.length) result.matches = p.matches.map(foryFindMatchToDict);
  if (p.atBoundary) result.atBoundary = true;
  if (p.tooSmallToScroll) result.tooSmallToScroll = true;
  if (p.direction === 0 || p.direction === 1) result.direction = p.direction === 1 ? 'back' : 'forth';
  if (p.minDragDistance) result.minDragDistance = p.minDragDistance;
  return result;
}

export function deserializeDomPayload(data: Uint8Array): { app: string; window: [number, number]; elements: DomNode[]; raw?: string } {
  const p = domPayloadSer.deserialize(data);
  const result: { app: string; window: [number, number]; elements: DomNode[]; raw?: string } = {
    app: p.app,
    window: [p.windowSize.x, p.windowSize.y],
    elements: (p.elements ?? []).map(foryDomElementToDict),
  };
  if (p.raw) result.raw = p.raw;
  return result;
}

export function deserializeScreenshotPayload(data: Uint8Array): { jpeg: Buffer } {
  const p = screenshotPayloadSer.deserialize(data);
  return { jpeg: Buffer.from(p.jpeg) };
}

export function deserializeElementPayload(data: Uint8Array): { type: string; label: string; rect?: Rect } {
  const p = elementPayloadSer.deserialize(data);
  return {
    type: elementTypeName(p.elemType),
    label: p.label,
    rect: foryRectToArray(p.rect),
  };
}

export function deserializeFindPayload(data: Uint8Array): { matches: FindMatchDict[]; hint?: string; suggestions?: string[] } {
  const p = findPayloadSer.deserialize(data);
  return {
    matches: (p.matches ?? []).map(foryFindMatchToDict),
    hint: p.hint || undefined,
    suggestions: p.suggestions?.length ? p.suggestions : undefined,
  };
}

export function deserializeSwipePayload(data: Uint8Array): { ancestors: string[]; type: string; label: string; rect?: Rect; scrolls: number } {
  const p = swipePayloadSer.deserialize(data);
  return {
    ancestors: p.ancestors ?? [],
    type: elementTypeName(p.elemType),
    label: p.label,
    rect: foryRectToArray(p.rect),
    scrolls: p.scrolls,
  };
}

export function deserializeWaitForPayload(data: Uint8Array): { type: string; label: string; rect?: Rect; waited: number } {
  const p = waitForPayloadSer.deserialize(data);
  return {
    type: elementTypeName(p.elemType),
    label: p.label,
    rect: foryRectToArray(p.rect),
    waited: p.waited,
  };
}

export function deserializeAlertPayload(data: Uint8Array): { dismissed: boolean; text: string; button: string; reason: string } {
  return alertPayloadSer.deserialize(data);
}

export function deserializeProxyPayload(data: Uint8Array): { status: string } {
  return proxyPayloadSer.deserialize(data);
}

export function deserializeSimpleStringPayload(data: Uint8Array): { value: string } {
  return simpleStringPayloadSer.deserialize(data);
}
