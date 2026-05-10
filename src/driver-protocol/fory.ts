import Fury, { Type } from '@apache-fory/core';
import type { ResponseFrame } from './frames.js';
import { elementTypeName } from './fory-constants.js';

// MARK: - Fory instance + registration

const fory = new Fury();

// Shared types
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
const ForyErrorPayload = Type.struct('ForyErrorPayload', {
  hint: Type.string(),
  suggestions: Type.list(Type.string()),
  matches: Type.list(Type.struct('ForyFindMatch', {
    elemType: Type.int32(),
    label: Type.string(),
    rect: ForyRect.setNullable(true),
    traits: Type.list(Type.string()),
    value: Type.string(),
    ancestors: Type.list(Type.string()),
  })),
  atBoundary: Type.bool(),
  tooSmallToScroll: Type.bool(),
  direction: Type.int32(),
  minDragDistance: Type.float64(),
});

// DOM
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

// Screenshot
const ForyScreenshotPayload = Type.struct('ForyScreenshotPayload', {
  jpeg: Type.binary(),
});

// Find
const ForyFindMatch = Type.struct('ForyFindMatch', {
  elemType: Type.int32(),
  label: Type.string(),
  rect: ForyRect.setNullable(true),
  traits: Type.list(Type.string()),
  value: Type.string(),
  ancestors: Type.list(Type.string()),
});
const ForyFindPayload = Type.struct('ForyFindPayload', {
  matches: Type.list(ForyFindMatch),
  hint: Type.string(),
  suggestions: Type.list(Type.string()),
});

// Element (tap/longPress/input)
const ForyElementPayload = Type.struct('ForyElementPayload', {
  elemType: Type.int32(),
  label: Type.string(),
  rect: ForyRect.setNullable(true),
});

// Swipe
const ForySwipePayload = Type.struct('ForySwipePayload', {
  ancestors: Type.list(Type.string()),
  elemType: Type.int32(),
  label: Type.string(),
  rect: ForyRect.setNullable(true),
  scrolls: Type.int32(),
});

// WaitFor
const ForyWaitForPayload = Type.struct('ForyWaitForPayload', {
  elemType: Type.int32(),
  label: Type.string(),
  rect: ForyRect.setNullable(true),
  waited: Type.float64(),
});

// Alert
const ForyAlertPayload = Type.struct('ForyAlertPayload', {
  dismissed: Type.bool(),
  text: Type.string(),
  button: Type.string(),
  reason: Type.string(),
});

// Oslog
const ForyOslogPayload = Type.struct('ForyOslogPayload', {
  matched: Type.int32(),
  total: Type.int32(),
  content: Type.string(),
  cleared: Type.int32(),
});

// Probe
const ForyProbePayload = Type.struct('ForyProbePayload', {
  statusCode: Type.int32(),
  bodyBytes: Type.int32(),
  contentType: Type.string(),
});

// Proxy
const ForyProxyPayload = Type.struct('ForyProxyPayload', {
  status: Type.string(),
});

// Simple String
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
const ForyOslogArgs = Type.struct('ForyOslogArgs', {
  pattern: Type.string(),
  flags: Type.string(),
  name: Type.string(),
  clear: Type.bool(),
  bundleId: Type.string(),
  timeout: Type.float64(),
});
const ForyProbeFetchArgs = Type.struct('ForyProbeFetchArgs', {
  url: Type.string(),
  timeout: Type.float64(),
});

const ForyProxyCAPushArgs = Type.struct('ForyProxyCAPushArgs', {
  caBase64: Type.string(),
});

// Register all types
fory.register(ForyRect);
fory.register(ForyPoint);
fory.register(ForyTarget);
fory.register(ForyRequestFrame);
fory.register(ForyResponseFrame);
fory.register(ForyErrorPayload);
fory.register(ForyDomElement);
fory.register(ForyDomPayload);
fory.register(ForyScreenshotPayload);
fory.register(ForyFindMatch);
fory.register(ForyFindPayload);
fory.register(ForyElementPayload);
fory.register(ForySwipePayload);
fory.register(ForyWaitForPayload);
fory.register(ForyAlertPayload);
fory.register(ForyOslogPayload);
fory.register(ForyProbePayload);
fory.register(ForyProxyPayload);
fory.register(ForySimpleStringPayload);
fory.register(ForyCreateSessionArgs);
fory.register(ForyActivateAppArgs);
fory.register(ForyTerminateAppArgs);
fory.register(ForyOpenURLArgs);
fory.register(ForyDomArgs);
fory.register(ForyFindArgs);
fory.register(ForyInputArgs);
fory.register(ForyWaitForArgs);
fory.register(ForyTapArgs);
fory.register(ForyLongPressArgs);
fory.register(ForySwipeArgs);
fory.register(ForyDismissAlertArgs);
fory.register(ForyOslogArgs);
fory.register(ForyProbeFetchArgs);
fory.register(ForyProxyCAPushArgs);

// MARK: - Serializers

const reqFrameSer = fory.register(ForyRequestFrame);
const respFrameSer = fory.register(ForyResponseFrame);

// MARK: - Request serialization

export function serializeRequestFrame(command: string, argsPayload: Uint8Array): Uint8Array {
  return reqFrameSer.serialize({ command, payload: argsPayload });
}

export function serializeArgs(command: string, args?: Record<string, unknown>): Uint8Array {
  switch (command) {
    case 'createSession':
      return fory.register(ForyCreateSessionArgs).serialize({
        bundleId: (args?.bundleId as string) ?? '',
        terminate: (args?.terminate as boolean) ?? false,
      });
    case 'activateApp':
      return fory.register(ForyActivateAppArgs).serialize({ bundleId: args?.bundleId as string });
    case 'terminateApp':
      return fory.register(ForyTerminateAppArgs).serialize({ bundleId: args?.bundleId as string });
    case 'openURL':
      return fory.register(ForyOpenURLArgs).serialize({ url: args?.url as string });
    case 'dom':
      return fory.register(ForyDomArgs).serialize({ raw: !!args?.raw, fresh: !!args?.fresh });
    case 'find':
      return fory.register(ForyFindArgs).serialize({
        label: (args?.label as string) ?? '',
        traits: (args?.traits as string) ?? '',
      });
    case 'input':
      return fory.register(ForyInputArgs).serialize({
        label: (args?.label as string) ?? '',
        content: (args?.content as string) ?? '',
        traits: (args?.traits as string) ?? '',
      });
    case 'waitFor':
      return fory.register(ForyWaitForArgs).serialize({
        label: (args?.label as string) ?? '',
        timeout: (args?.timeout as number) ?? 0,
        traits: (args?.traits as string) ?? '',
      });
    case 'tap': {
      const target = toForyTarget(args?.label);
      const offset = args?.offset as { x?: number; y?: number; xRatio?: number; yRatio?: number } | undefined;
      const hasAbsolute = offset && (offset.x != null || offset.y != null);
      return fory.register(ForyTapArgs).serialize({
        target,
        traits: (args?.traits as string) ?? '',
        offset: hasAbsolute ? { x: offset.x ?? 0, y: offset.y ?? 0 } : null,
        ratio: !hasAbsolute && (offset?.xRatio != null || offset?.yRatio != null)
          ? { x: offset.xRatio ?? 0.5, y: offset.yRatio ?? 0.5 }
          : { x: 0.5, y: 0.5 },
      });
    }
    case 'longPress': {
      const target = toForyTarget(args?.label);
      return fory.register(ForyLongPressArgs).serialize({
        target,
        duration: (args?.duration as number) ?? 0,
        traits: (args?.traits as string) ?? '',
      });
    }
    case 'swipe': {
      const toTarget = toForyTarget(args?.to);
      const fromTarget = toForyTarget(args?.from);
      const dirStr = args?.dir as string | undefined;
      return fory.register(ForySwipeArgs).serialize({
        toTarget,
        fromTarget,
        distance: (args?.distance as number) ?? 0,
        dir: dirStr === 'back' ? 1 : 0,
        traits: (args?.traits as string) ?? '',
      });
    }
    case 'dismissAlert':
      return fory.register(ForyDismissAlertArgs).serialize({
        index: (args?.index as number) ?? -1,
      });
    case 'oslog':
      return fory.register(ForyOslogArgs).serialize({
        pattern: (args?.pattern as string) ?? '',
        flags: (args?.flags as string) ?? '',
        name: (args?.name as string) ?? '',
        clear: !!args?.clear,
        bundleId: (args?.bundleId as string) ?? '',
        timeout: (args?.timeout as number) ?? 0,
      });
    case 'probeFetch':
      return fory.register(ForyProbeFetchArgs).serialize({
        url: (args?.url as string) ?? '',
        timeout: (args?.timeout as number) ?? 0,
      });
    case 'proxyCAPush':
      return fory.register(ForyProxyCAPushArgs).serialize({
        caBase64: (args?.caBase64 as string) ?? '',
      });
    default:
      return new Uint8Array(0);
  }
}

function toForyTarget(label: unknown): { label: string; point: { x: number; y: number } | null } {
  if (typeof label === 'string') {
    return { label, point: null };
  }
  if (Array.isArray(label) && label.length === 2) {
    return { label: '', point: { x: label[0] as number, y: label[1] as number } };
  }
  return { label: '', point: null };
}

// MARK: - Response deserialization

export function deserializeResponse(data: Uint8Array): { frame: ResponseFrame; command?: string } {
  const outer = respFrameSer.deserialize(data);

  if (!outer.ok) {
    const errorData = outer.payload.length > 0
      ? deserializeErrorPayload(outer.payload)
      : undefined;
    return { frame: { ok: false, error: outer.error, data: errorData } };
  }

  if (outer.payload.length === 0) {
    return { frame: { ok: true } };
  }

  // Payload is deserialized by the caller based on command
  return { frame: { ok: true }, payloadBytes: outer.payload };
}

export function deserializeResponsePayload(command: string, payload: Uint8Array): unknown {
  switch (command) {
    case 'dom':
      return deserializeDomPayload(payload);
    case 'screenshot':
      return deserializeScreenshotPayload(payload);
    case 'tap':
    case 'longPress':
    case 'input':
      return deserializeElementPayload(payload);
    case 'find':
      return deserializeFindPayload(payload);
    case 'swipe':
      return deserializeSwipePayload(payload);
    case 'waitFor':
      return deserializeWaitForPayload(payload);
    case 'dismissAlert':
      return deserializeAlertPayload(payload);
    case 'oslog':
      return deserializeOslogPayload(payload);
    case 'probeFetch':
      return deserializeProbePayload(payload);
    case 'proxyCAPush':
      return deserializeProxyPayload(payload);
    case 'createSession':
    case 'openURL':
      return deserializeSimpleStringPayload(payload);
    default:
      return undefined;
  }
}

function deserializeErrorPayload(data: Uint8Array): unknown {
  const p = fory.register(ForyErrorPayload).deserialize(data);
  const result: Record<string, unknown> = {};
  if (p.hint) result.hint = p.hint;
  if (p.suggestions?.length) result.suggestions = p.suggestions;
  if (p.matches?.length) result.matches = p.matches.map(foryFindMatchToDict);
  if (p.atBoundary) result.atBoundary = true;
  if (p.tooSmallToScroll) result.tooSmallToScroll = true;
  if (p.direction !== undefined) result.direction = p.direction === 1 ? 'back' : 'forth';
  if (p.minDragDistance) result.minDragDistance = p.minDragDistance;
  return result;
}

function deserializeDomPayload(data: Uint8Array): unknown {
  const p = fory.register(ForyDomPayload).deserialize(data);
  const result: Record<string, unknown> = {
    app: p.app,
    window: [p.windowSize.x, p.windowSize.y],
    elements: (p.elements ?? []).map(foryDomElementToDict),
  };
  if (p.raw) result.raw = p.raw;
  return result;
}

function deserializeScreenshotPayload(data: Uint8Array): unknown {
  const p = fory.register(ForyScreenshotPayload).deserialize(data);
  return { jpeg: Buffer.from(p.jpeg) };
}

function deserializeElementPayload(data: Uint8Array): unknown {
  const p = fory.register(ForyElementPayload).deserialize(data);
  return {
    type: elementTypeName(p.elemType),
    label: p.label,
    rect: foryRectToArray(p.rect),
  };
}

function deserializeFindPayload(data: Uint8Array): unknown {
  const p = fory.register(ForyFindPayload).deserialize(data);
  return {
    matches: (p.matches ?? []).map(foryFindMatchToDict),
    hint: p.hint || undefined,
    suggestions: p.suggestions?.length ? p.suggestions : undefined,
  };
}

function deserializeSwipePayload(data: Uint8Array): unknown {
  const p = fory.register(ForySwipePayload).deserialize(data);
  return {
    ancestors: p.ancestors ?? [],
    type: elementTypeName(p.elemType),
    label: p.label,
    rect: foryRectToArray(p.rect),
    scrolls: p.scrolls,
  };
}

function deserializeWaitForPayload(data: Uint8Array): unknown {
  const p = fory.register(ForyWaitForPayload).deserialize(data);
  return {
    type: elementTypeName(p.elemType),
    label: p.label,
    rect: foryRectToArray(p.rect),
    waited: p.waited,
  };
}

function deserializeAlertPayload(data: Uint8Array): unknown {
  return fory.register(ForyAlertPayload).deserialize(data);
}

function deserializeOslogPayload(data: Uint8Array): unknown {
  return fory.register(ForyOslogPayload).deserialize(data);
}

function deserializeProbePayload(data: Uint8Array): unknown {
  return fory.register(ForyProbePayload).deserialize(data);
}

function deserializeProxyPayload(data: Uint8Array): unknown {
  return fory.register(ForyProxyPayload).deserialize(data);
}

function deserializeSimpleStringPayload(data: Uint8Array): unknown {
  const p = fory.register(ForySimpleStringPayload).deserialize(data);
  return { value: p.value };
}

// MARK: - Conversion helpers

function foryRectToArray(rect: { x: number; y: number; w: number; h: number } | null): number[] | undefined {
  if (!rect) return undefined;
  return [rect.x, rect.y, rect.w, rect.h];
}

function foryDomElementToDict(el: any): Record<string, unknown> {
  const result: Record<string, unknown> = {
    tr: el.traits ?? [],
    cc: el.childCount,
  };
  if (el.label) result.l = el.label;
  if (el.value) result.v = el.value;
  if (el.rect) result.r = [el.rect.x, el.rect.y, el.rect.w, el.rect.h];
  return result;
}

function foryFindMatchToDict(m: any): Record<string, unknown> {
  const result: Record<string, unknown> = {
    type: elementTypeName(m.elemType),
    label: m.label ?? '',
    traits: m.traits ?? [],
  };
  if (m.value) result.value = m.value;
  if (m.rect) result.rect = [m.rect.x, m.rect.y, m.rect.w, m.rect.h];
  if (m.ancestors?.length) result.ancestors = m.ancestors;
  return result;
}

// Re-export for response frame type
export { respFrameSer };
