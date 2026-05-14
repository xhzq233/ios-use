import { afterEach, describe, test, expect, mock } from 'bun:test';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { executeStep, resetAbort, setAbort, waitForNslogMatch } from '../src/commands/actions.ts';
import { parseFlowCliVars, runFlowFile } from '../src/commands/flow.ts';
import {
  tapArgsSer, longPressArgsSer, swipeArgsSer, inputArgsSer,
  waitForArgsSer, findArgsSer, domArgsSer,
  dismissAlertArgsSer,
  terminateAppArgsSer, activateAppArgsSer, openURLArgsSer,
  elementPayloadSer, domPayloadSer, screenshotPayloadSer,
  findPayloadSer, swipePayloadSer, waitForPayloadSer,
  alertPayloadSer, simpleStringPayloadSer,
} from '../src/driver-protocol/fory.ts';

const { TAP, LONG_PRESS, INPUT, SWIPE, DOM, FIND, WAIT_FOR, SCREENSHOT,
  ACTIVATE_APP, TERMINATE_APP, OPEN_URL, DISMISS_ALERT } = {
  TAP: 'tap', LONG_PRESS: 'longPress', INPUT: 'input', SWIPE: 'swipe',
  DOM: 'dom', FIND: 'find', WAIT_FOR: 'waitFor', SCREENSHOT: 'screenshot',
  ACTIVATE_APP: 'activateApp', TERMINATE_APP: 'terminateApp', OPEN_URL: 'openURL',
  DISMISS_ALERT: 'dismissAlert',
};

function makeTempDir(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

async function withTempHome(run) {
  const prevHome = process.env.HOME;
  const home = makeTempDir('ios-use-flow-home-');
  process.env.HOME = home;
  try {
    return await run(home);
  } finally {
    process.env.HOME = prevHome;
  }
}

function makeMatch(label, rect = [10, 20, 100, 40]) {
  return {
    ancestors: ['App', 'Window'],
    type: 'Button',
    label,
    rect,
    traits: ['Button'],
  };
}

function defaultSendRaw(command, payload) {
  switch (command) {
    case TAP:
    case LONG_PRESS: {
      const args = command === TAP ? tapArgsSer.deserialize(payload) : longPressArgsSer.deserialize(payload);
      return { ok: true, payloadBytes: elementPayloadSer.serialize({ elemType: 7, label: args.target?.label ?? '', rect: {x:0, y:0, w:0, h:0} }) };
    }
    case FIND: {
      const args = findArgsSer.deserialize(payload);
      const label = args.label || 'test';
      return { ok: true, payloadBytes: findPayloadSer.serialize({ matches: [{ elemType: 7, label, rect: {x:10, y:20, w:100, h:40}, traits: ['Button'], value: '', ancestors: ['App', 'Window'] }], hint: '', suggestions: [] }) };
    }
    case DOM: {
      const args = domArgsSer.deserialize(payload);
      return { ok: true, payloadBytes: domPayloadSer.serialize({ app: 'Demo', windowSize: {x:390, y:844}, raw: args.raw ? 'raw' : '', elements: [] }) };
    }
    case SWIPE:
      return { ok: true, payloadBytes: swipePayloadSer.serialize({ ancestors: [], elemType: 27, label: '', rect: {x:0, y:0, w:0, h:0}, scrolls: 1 }) };
    case WAIT_FOR: {
      const args = waitForArgsSer.deserialize(payload);
      return { ok: true, payloadBytes: waitForPayloadSer.serialize({ elemType: 9, label: args.label || '', rect: {x:0, y:0, w:0, h:0}, waited: 0.1 }) };
    }
    case INPUT:
      return { ok: true, payloadBytes: elementPayloadSer.serialize({ elemType: 7, label: '', rect: {x:0, y:0, w:0, h:0} }) };
    case SCREENSHOT:
      return { ok: true, payloadBytes: screenshotPayloadSer.serialize({ jpeg: Buffer.alloc(0) }) };
    case ACTIVATE_APP:
    case TERMINATE_APP:
    case OPEN_URL:
      return { ok: true, payloadBytes: simpleStringPayloadSer.serialize({ value: '' }) };
    case DISMISS_ALERT:
      return { ok: true, payloadBytes: alertPayloadSer.serialize({ dismissed: true, text: '', button: 'OK', reason: '' }) };
    default:
      return { ok: true, payloadBytes: new Uint8Array(0) };
  }
}

function composeSendRaw(...handlers) {
  return async (command, payload) => {
    for (const h of handlers) {
      const result = await h(command, payload);
      if (result !== undefined) return result;
    }
    return defaultSendRaw(command, payload);
  };
}

function tapSpy(callback) {
  return async (command, payload) => {
    if (command === TAP) {
      const args = tapArgsSer.deserialize(payload);
      callback(args);
    }
  };
}

function domSpy(callback) {
  return async (command, payload) => {
    if (command === DOM) {
      const args = domArgsSer.deserialize(payload);
      callback(args);
    }
  };
}

function inputSpy(callback) {
  return async (command, payload) => {
    if (command === INPUT) {
      const args = inputArgsSer.deserialize(payload);
      callback(args);
    }
  };
}

function customDom(jsElements) {
  return async (command, _payload) => {
    if (command === DOM) {
      const els = (jsElements || []).map(el => ({
        traits: el.tr || [],
        childCount: el.cc ?? 0,
        label: el.l || '',
        value: el.v || '',
        rect: el.r ? {x: el.r[0], y: el.r[1], w: el.r[2], h: el.r[3]} : null,
      }));
      return { ok: true, payloadBytes: domPayloadSer.serialize({
        app: 'Demo', windowSize: {x:390, y:844}, raw: '', elements: els,
      })};
    }
  };
}

function createDriver(overrides = {}) {
  const sendRaw = overrides.sendRaw;
  delete overrides.sendRaw;
  return {
    sendRaw: sendRaw || defaultSendRaw,
    async screenshot() { return Buffer.alloc(0); },
    async saveScreenshot() {},
    disconnect() {},
    ...overrides,
  };
}

describe('flow commands', () => {
  afterEach(() => {
    resetAbort();
    mock.restore();
  });

  test('passes vars into subflow and binds declared outputs by name', async () => {
    const dir = makeTempDir('ios-use-flow-runflow-');
    const childPath = path.join(dir, 'child.yaml');
    const parentPath = path.join(dir, 'parent.yaml');
    const taps = [];

    fs.writeFileSync(childPath, `
name: child
outputs: childValue
steps:
  - action: find
    label: \${vars.toolLabel}
    outputs: childValue
`);

    fs.writeFileSync(parentPath, `
name: parent
vars:
  tool: AI 光影
steps:
  - action: runFlow
    file: ./child.yaml
    vars:
      toolLabel: \${vars.tool}
    outputs: childValue
  - action: tap
    label: \${childValue.firstMatch.label}
`);

    const driver = createDriver({
      sendRaw: composeSendRaw(tapSpy(args => taps.push(args.target.label))),
    });

    await runFlowFile(driver, parentPath, {});

    expect(taps).toEqual(['AI 光影']);
  });

  test('runFlow caller vars override child default vars', async () => {
    const dir = makeTempDir('ios-use-flow-runflow-override-');
    const childPath = path.join(dir, 'child.yaml');
    const parentPath = path.join(dir, 'parent.yaml');
    const taps = [];

    fs.writeFileSync(childPath, `
name: child
vars:
  targetLabel: 默认值
steps:
  - action: tap
    label: \${vars.targetLabel}
`);

    fs.writeFileSync(parentPath, `
name: parent
steps:
  - action: runFlow
    file: ./child.yaml
    vars:
      targetLabel: 调用方覆盖值
`);

    const driver = createDriver({
      sendRaw: composeSendRaw(tapSpy(args => taps.push(args.target.label))),
    });

    await runFlowFile(driver, parentPath, {});

    expect(taps).toEqual(['调用方覆盖值']);
  });

  test('top-level external vars override flow defaults without rewriting yaml', async () => {
    const dir = makeTempDir('ios-use-flow-external-vars-');
    const flowPath = path.join(dir, 'flow.yaml');
    const inputs = [];

    fs.writeFileSync(flowPath, `
name: external-vars
vars:
  server: 192.168.1.1
  port: "8080"
steps:
  - action: input
    label: 服务器
    content: \${vars.server}
  - action: input
    label: 端口
    content: \${vars.port}
`);

    const driver = createDriver({
      sendRaw: composeSendRaw(inputSpy(args => inputs.push({ label: args.label, content: args.content }))),
    });

    await runFlowFile(driver, flowPath, {}, { server: '192.168.1.10', port: '9080' });

    expect(inputs).toEqual([
      { label: '服务器', content: '192.168.1.10' },
      { label: '端口', content: '9080' },
    ]);
  });

  test('parseFlowCliVars parses external vars and rejects reserved options', () => {
    expect(parseFlowCliVars(['--server', '192.168.1.10', '--port=9080'])).toEqual({
      server: '192.168.1.10',
      port: '9080',
    });
    expect(() => parseFlowCliVars(['--verbose', 'true'])).toThrow('Reserved flow option');
    expect(() => parseFlowCliVars(['--server'])).toThrow('Missing value');
  });

  test('derives dom candidates at flow layer and respects candidate priority', async () => {
    const dir = makeTempDir('ios-use-flow-dom-');
    const flowPath = path.join(dir, 'flow.yaml');
    const taps = [];

    fs.writeFileSync(flowPath, `
name: popup
steps:
  - action: dom
    candidates:
      - 关闭
      - 取消
    outputs: popupDom
  - action: tap
    label: \${popupDom.firstMatch.label}
`);

    const driver = createDriver({
      sendRaw: composeSendRaw(
        tapSpy(args => taps.push(args.target.label)),
        customDom([
          { tr: ['Window'], cc: 2 },
          { tr: ['Button'], l: '取消', r: [10, 10, 50, 20], cc: 0 },
          { tr: ['Button'], l: '关闭', r: [70, 10, 50, 20], cc: 0 },
        ]),
      ),
    });

    await runFlowFile(driver, flowPath, {});

    expect(taps).toEqual(['关闭']);
  });

  test('sets dom firstMatch to null when candidates miss', async () => {
    const output = await executeStep(createDriver({
      sendRaw: customDom([
        { tr: ['Window'], cc: 1 },
        { tr: ['Button'], l: '保存', r: [10, 10, 50, 20], cc: 0 },
      ]),
    }), {
      action: 'dom',
      candidates: ['关闭', '取消'],
    }, {});

    expect(output).toMatchObject({
      matches: [],
      firstMatch: null,
    });
  });

  test('dom save writes derived output with dom matches and firstMatch', async () => {
    const name = `dom-save-test-${Date.now()}`;
    const originalMkdirSync = fs.mkdirSync;
    const originalWriteFileSync = fs.writeFileSync;
    let savedPath = '';
    let savedContent = '';

    try {
      fs.mkdirSync = ((target, opts) => {
        if (String(target).endsWith(path.join('.ios-use', 'artifacts'))) return undefined;
        return originalMkdirSync(target, opts);
      });
      fs.writeFileSync = ((target, data, opts) => {
        if (String(target).endsWith(`${name}.json`)) {
          savedPath = String(target);
          savedContent = String(data);
          return undefined;
        }
        return originalWriteFileSync(target, data, opts);
      });

      await executeStep(createDriver({
        sendRaw: customDom([
          { tr: ['Window'], cc: 1 },
          { tr: ['Button'], l: '关闭', r: [10, 10, 50, 20], cc: 0 },
        ]),
      }), {
        action: 'dom',
        candidates: ['关闭'],
        save: true,
        name,
        print: false,
      }, {});

      expect(savedPath.endsWith(`${name}.json`)).toBe(true);
      const saved = JSON.parse(savedContent);
      expect(saved.dom.app).toBe('Demo');
      expect(saved.matches).toHaveLength(1);
      expect(saved.firstMatch).toMatchObject({ label: '关闭', type: 'Button' });
    } finally {
      fs.mkdirSync = originalMkdirSync;
      fs.writeFileSync = originalWriteFileSync;
    }
  });

  test('errors when runFlow requests an undeclared output', async () => {
    const dir = makeTempDir('ios-use-flow-missing-output-');
    const childPath = path.join(dir, 'child.yaml');
    const parentPath = path.join(dir, 'parent.yaml');

    fs.writeFileSync(childPath, `
name: child
steps:
  - action: waitFor
    label: Ready
`);

    fs.writeFileSync(parentPath, `
name: parent
steps:
  - action: runFlow
    file: ./child.yaml
    outputs: missingValue
`);

    await expect(runFlowFile(createDriver(), parentPath, {})).rejects.toThrow('runFlow requested undeclared output "missingValue"');
  });

  test('rejects invalid output variable names early', async () => {
    const dir = makeTempDir('ios-use-flow-invalid-output-');
    const flowPath = path.join(dir, 'flow.yaml');

    fs.writeFileSync(flowPath, `
name: invalid-output
steps:
  - action: dom
    outputs: foo.bar
`);

    await expect(runFlowFile(createDriver(), flowPath, {})).rejects.toThrow('invalid variable name: foo.bar');
  });

  test('returnIf can no-op return current flow when value matches null', async () => {
    const dir = makeTempDir('ios-use-flow-returnif-null-');
    const flowPath = path.join(dir, 'flow.yaml');
    const taps = [];

    fs.writeFileSync(flowPath, `
name: dismiss-popup
steps:
  - action: dom
    candidates:
      - 关闭
      - 取消
    outputs: popupDom
  - action: returnIf
    value: \${popupDom.firstMatch}
    is: null
  - action: tap
    label: \${popupDom.firstMatch.label}
`);

    const driver = createDriver({
      sendRaw: composeSendRaw(tapSpy(args => taps.push(args.target.label))),
    });

    await runFlowFile(driver, flowPath, {});

    expect(taps).toEqual([]);
  });

  test('returnIf rejects unsupported matcher values', async () => {
    const dir = makeTempDir('ios-use-flow-returnif-invalid-');
    const flowPath = path.join(dir, 'flow.yaml');

    fs.writeFileSync(flowPath, `
name: invalid-return-if
steps:
  - action: returnIf
    value: false
    is: maybe
`);

    await expect(runFlowFile(createDriver(), flowPath, {})).rejects.toThrow('returnIf requires "is" to be true, false, or null');
  });

  // ── sleep ──

  test('sleep waits for the specified duration in a flow', async () => {
    const dir = makeTempDir('ios-use-flow-sleep-');
    const flowPath = path.join(dir, 'flow.yaml');
    const taps = [];

    fs.writeFileSync(flowPath, `
name: sleep-test
steps:
  - action: sleep
    ms: 50
  - action: tap
    label: after-sleep
`);

    const driver = createDriver({
      sendRaw: composeSendRaw(tapSpy(args => taps.push(args.target.label))),
    });

    const t0 = Date.now();
    await runFlowFile(driver, flowPath, {});
    const elapsed = Date.now() - t0;

    expect(taps).toEqual(['after-sleep']);
    expect(elapsed).toBeGreaterThanOrEqual(40);
  });

  test('sleep defaults to 1000ms when ms is omitted', async () => {
    const dir = makeTempDir('ios-use-flow-sleep-default-');
    const flowPath = path.join(dir, 'flow.yaml');

    fs.writeFileSync(flowPath, `
name: sleep-default
steps:
  - action: sleep
  - action: tap
    label: after-sleep
`);

    const taps = [];
    const driver = createDriver({
      sendRaw: composeSendRaw(tapSpy(args => taps.push(args.target.label))),
    });

    const t0 = Date.now();
    await runFlowFile(driver, flowPath, {});
    const elapsed = Date.now() - t0;

    expect(taps).toEqual(['after-sleep']);
    expect(elapsed).toBeGreaterThanOrEqual(900);
  });

  // ── dom fresh ──

  test('dom passes fresh flag to driver', async () => {
    const domCalls = [];
    const driver = createDriver({
      sendRaw: composeSendRaw(domSpy(args => domCalls.push(args))),
    });

    await executeStep(driver, { action: 'dom', fresh: true }, {});

    expect(domCalls).toHaveLength(1);
    expect(domCalls[0]).toMatchObject({ fresh: true });
  });

  test('dom defaults fresh to false when not specified', async () => {
    const domCalls = [];
    const driver = createDriver({
      sendRaw: composeSendRaw(domSpy(args => domCalls.push(args))),
    });

    await executeStep(driver, { action: 'dom' }, {});

    expect(domCalls).toHaveLength(1);
    expect(domCalls[0]).toMatchObject({ fresh: false });
  });

  test('dom fresh in flow passes fresh=true to driver', async () => {
    const dir = makeTempDir('ios-use-flow-dom-fresh-');
    const flowPath = path.join(dir, 'flow.yaml');
    const domCalls = [];

    const driver = createDriver({
      sendRaw: composeSendRaw(
        domSpy(args => domCalls.push(args)),
        customDom([
          { tr: ['Window'], cc: 1 },
          { tr: ['Button'], l: '取消', r: [10, 10, 50, 20], cc: 0 },
        ]),
      ),
    });

    fs.writeFileSync(flowPath, `
name: fresh-test
steps:
  - action: dom
    outputs: dom1
  - action: sleep
    ms: 10
  - action: dom
    fresh: true
    outputs: dom2
`);

    await runFlowFile(driver, flowPath, {});

    expect(domCalls).toHaveLength(2);
    expect(domCalls[0]).toMatchObject({ fresh: false });
    expect(domCalls[1]).toMatchObject({ fresh: true });
  });

  test('passes tap offset x/y through to driver', async () => {
    const taps = [];
    const driver = createDriver({
      sendRaw: composeSendRaw(async (command, payload) => {
        if (command === TAP) {
          const args = tapArgsSer.deserialize(payload);
          taps.push({ target: args.target.label, offset: { x: args.offset.x, y: args.offset.y } });
        }
      }),
    });

    await executeStep(driver, {
      action: 'tap',
      label: 'effect-slider',
      offset: { x: 12, y: 5 },
    }, {});

    expect(taps).toEqual([{ target: 'effect-slider', offset: { x: 12, y: 5 } }]);
  });

  test('passes tap offset xRatio/yRatio through to driver', async () => {
    const taps = [];
    const driver = createDriver({
      sendRaw: composeSendRaw(async (command, payload) => {
        if (command === TAP) {
          const args = tapArgsSer.deserialize(payload);
          taps.push({ target: args.target.label, offset: { xRatio: args.ratio.x, yRatio: args.ratio.y } });
        }
      }),
    });

    await executeStep(driver, {
      action: 'tap',
      label: 'effect-slider',
      offset: { xRatio: 0.8, yRatio: 0.5 },
    }, {});

    expect(taps).toEqual([{ target: 'effect-slider', offset: { xRatio: 0.8, yRatio: 0.5 } }]);
  });

  test('passes tap offset through command wrapper', async () => {
    const taps = [];
    const driver = createDriver({
      sendRaw: composeSendRaw(async (command, payload) => {
        if (command === TAP) {
          const args = tapArgsSer.deserialize(payload);
          taps.push({ target: args.target.label, offset: { x: args.offset.x, y: args.offset.y } });
        }
      }),
    });

    mock.module('../src/session.js', () => ({
      withAutoSession: async (_opts, run) => await run(driver),
      readSessionInfo: () => null,
      updateSessionBundleId: () => undefined,
    }));

    const { runCommandStep: mockedRunCommandStep } = await import(`../src/commands/actions.ts?test=${Date.now()}`);
    await mockedRunCommandStep({ action: 'tap', label: 'effect-slider', offset: { x: 12, y: 5 } });

    expect(taps).toEqual([{ target: 'effect-slider', offset: { x: 12, y: 5 } }]);
  });

  test('nslog polling stops promptly after abort', async () => {
    const server = {
      grep: () => [],
      getLogCount: () => 0,
      clear: () => undefined,
      getPort: () => 0,
    };

    setAbort();
    await expect(waitForNslogMatch(server, 'ready', '', 5)).rejects.toThrow('Flow interrupted');
  });

  test('stops before running the next step after abort is requested', async () => {
    const taps = [];
    const dir = makeTempDir('ios-use-flow-abort-');
    const flowPath = path.join(dir, 'flow.yaml');

    fs.writeFileSync(flowPath, `
name: abort
steps:
  - action: tap
    label: first
  - action: tap
    label: second
`);

    const driver = createDriver({
      sendRaw: async (command, payload) => {
        if (command === TAP) {
          const args = tapArgsSer.deserialize(payload);
          taps.push(args.target.label);
          if (args.target.label === 'first') setAbort();
        }
        return defaultSendRaw(command, payload);
      },
    });

    await expect(runFlowFile(driver, flowPath, {})).rejects.toThrow('Flow interrupted by Ctrl+C');
    expect(taps).toEqual(['first']);
  });

  test('rejects cyclic runFlow references', async () => {
    const dir = makeTempDir('ios-use-flow-cycle-');
    const flowAPath = path.join(dir, 'a.yaml');
    const flowBPath = path.join(dir, 'b.yaml');

    fs.writeFileSync(flowAPath, `
name: flow-a
steps:
  - action: runFlow
    file: ./b.yaml
`);

    fs.writeFileSync(flowBPath, `
name: flow-b
steps:
  - action: runFlow
    file: ./a.yaml
`);

    await expect(runFlowFile(createDriver(), flowAPath, {})).rejects.toThrow('runFlow cycle detected');
  });
});
