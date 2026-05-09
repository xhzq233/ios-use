import { afterEach, describe, test, expect, mock } from 'bun:test';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { executeStep, resetAbort, setAbort, waitForNslogMatch } from '../src/commands/actions.ts';
import { runFlowFile } from '../src/commands/flow.ts';

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

function createDriver(overrides = {}) {
  return {
    dom: async () => ({ app: 'Demo', window: [390, 844], elements: [] }),
    find: async ({ label }) => ({ ok: true, matches: [makeMatch(label)] }),
    tap: async (target) => ({ type: Array.isArray(target) ? 'Coordinate' : 'Button', label: Array.isArray(target) ? '' : target, rect: [0, 0, 0, 0] }),
    longPress: async () => ({ type: 'Button', label: '', rect: [0, 0, 0, 0] }),
    input: async () => undefined,
    swipe: async () => ({ ancestors: [], type: 'ScrollView', label: '', rect: [0, 0, 0, 0], scrolls: 1 }),
    waitFor: async ({ label }) => ({ type: 'StaticText', label, rect: [0, 0, 0, 0], waited: 0.1 }),
    activateApp: async () => undefined,
    terminateApp: async () => undefined,
    screenshot: async () => Buffer.alloc(0),
    saveScreenshot: async () => undefined,
    oslog: async () => ({ matched: 0, total: 0, content: '' }),
    deleteSession: async () => undefined,
    disconnect: () => undefined,
    ...overrides,
  };
}

describe('flow commands', () => {
  afterEach(() => {
    resetAbort();
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
      tap: async (target) => {
        taps.push(target);
        return { type: 'Button', label: String(target), rect: [0, 0, 0, 0] };
      },
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
      tap: async (target) => {
        taps.push(target);
        return { type: 'Button', label: String(target), rect: [0, 0, 0, 0] };
      },
    });

    await runFlowFile(driver, parentPath, {});

    expect(taps).toEqual(['调用方覆盖值']);
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
      dom: async () => ({
        app: 'Demo',
        window: [390, 844],
        elements: [
          { tr: ['Window'], c: [
            { tr: ['Button'], l: '取消', r: [10, 10, 50, 20] },
            { tr: ['Button'], l: '关闭', r: [70, 10, 50, 20] },
          ] },
        ],
      }),
      tap: async (target) => {
        taps.push(target);
        return { type: 'Button', label: String(target), rect: [0, 0, 0, 0] };
      },
    });

    await runFlowFile(driver, flowPath, {});

    expect(taps).toEqual(['关闭']);
  });

  test('sets dom firstMatch to null when candidates miss', async () => {
    const output = await executeStep(createDriver({
      dom: async () => ({
        app: 'Demo',
        window: [390, 844],
        elements: [
          { tr: ['Window'], c: [
            { tr: ['Button'], l: '保存', r: [10, 10, 50, 20] },
          ] },
        ],
      }),
    }), {
      action: 'dom',
      candidates: ['关闭', '取消'],
    }, {});

    expect(output).toMatchObject({
      matches: [],
      firstMatch: null,
    });
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
      tap: async (target) => {
        taps.push(target);
        return { type: 'Button', label: String(target), rect: [0, 0, 0, 0] };
      },
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
      tap: async (target) => {
        taps.push(target);
        return { type: 'Button', label: String(target), rect: [0, 0, 0, 0] };
      },
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
      tap: async (target) => {
        taps.push(target);
        return { type: 'Button', label: String(target), rect: [0, 0, 0, 0] };
      },
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
      dom: async (opts) => {
        domCalls.push(opts);
        return { app: 'Demo', window: [390, 844], elements: [] };
      },
    });

    await executeStep(driver, { action: 'dom', fresh: true }, {});

    expect(domCalls).toHaveLength(1);
    expect(domCalls[0]).toMatchObject({ fresh: true });
  });

  test('dom defaults fresh to false when not specified', async () => {
    const domCalls = [];
    const driver = createDriver({
      dom: async (opts) => {
        domCalls.push(opts);
        return { app: 'Demo', window: [390, 844], elements: [] };
      },
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
      dom: async (opts) => {
        domCalls.push(opts);
        return { app: 'Demo', window: [390, 844], elements: [
          { tr: ['Window'], c: [
            { tr: ['Button'], l: '取消', r: [10, 10, 50, 20] },
          ] },
        ] };
      },
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
      tap: async (target, _context, offset) => {
        taps.push({ target, offset });
        return { type: 'Button', label: String(target), rect: [10, 20, 100, 40] };
      },
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
      tap: async (target, _context, offset) => {
        taps.push({ target, offset });
        return { type: 'Button', label: String(target), rect: [10, 20, 100, 40] };
      },
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
      tap: async (target, _context, offset) => {
        taps.push({ target, offset });
        return { type: 'Button', label: String(target), rect: [10, 20, 100, 40] };
      },
    });

    mock.module('../src/session.js', () => ({
      withAutoSession: async (_opts, run) => await run(driver),
    }));

    const { runCommandStep: mockedRunCommandStep } = await import(`../src/commands/actions.ts?test=${Date.now()}`);
    await mockedRunCommandStep({ action: 'tap', label: 'effect-slider', offset: { x: 12, y: 5 } });

    expect(taps).toEqual([{ target: 'effect-slider', offset: { x: 12, y: 5 } }]);
  });

  test('passes oslog timeout through to driver', async () => {
    await withTempHome(async () => {
      const calls = [];
      const driver = createDriver({
        oslog: async (args) => {
          calls.push(args);
          return { matched: 1, total: 3, content: 'ready\n' };
        },
      });

      await executeStep(driver, {
        action: 'oslog',
        pattern: 'ready',
        timeout: 1,
        name: 'oslog-poll-test',
      }, {});

      expect(calls).toEqual([{
        pattern: 'ready',
        flags: undefined,
        name: 'oslog-poll-test',
        clear: undefined,
        bundleId: undefined,
        timeout: 1,
      }]);
    });
  });

  test('passes oslog timeout through command wrapper', async () => {
    const calls = [];
    const driver = createDriver({
      oslog: async (args) => {
        calls.push(args);
        return { matched: 1, total: 1, content: 'ready\n' };
      },
    });

    mock.module('../src/session.js', () => ({
      withAutoSession: async (_opts, run) => await run(driver),
    }));

    await withTempHome(async () => {
      const { runCommandStep: mockedRunCommandStep } = await import(`../src/commands/actions.ts?test=${Date.now()}`);
      await mockedRunCommandStep({ action: 'oslog', pattern: 'ready', timeout: 2, name: 'cli-oslog-timeout' });
    });

    expect(calls).toEqual([{
      pattern: 'ready',
      flags: undefined,
      name: 'cli-oslog-timeout',
      clear: undefined,
      bundleId: undefined,
      timeout: 2,
    }]);
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
      tap: async (target) => {
        taps.push(target);
        if (target === 'first') {
          setAbort();
        }
        return { type: 'Button', label: String(target), rect: [0, 0, 0, 0] };
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
