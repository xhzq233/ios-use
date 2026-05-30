export const flowCaseMetadata = [
  { id: 'FLOW-1', group: 'flow', kind: 'flow-basic', setup: 'flow fixtures and settings home', assertion: 'stdout contains Running flow', coverage: 'simulator' },
  { id: 'FLOW-2', group: 'flow', kind: 'flow-error', setup: 'flow fixtures', assertion: 'missing file fails before actions', coverage: 'simulator' },
  { id: 'FLOW-3', group: 'flow', kind: 'flow-basic-retryable', setup: 'flow fixtures and settings home', assertion: 'stdout contains Running flow with transient retry tracking', coverage: 'simulator' },
  { id: 'FLOW-4', group: 'flow', kind: 'flow-basic', setup: 'flow fixtures and settings home', assertion: 'stdout contains Running flow', coverage: 'simulator' },
  { id: 'FLOW-6', group: 'flow', kind: 'flow-vars', setup: 'flow fixtures and settings home', assertion: 'stdout contains Running flow', coverage: 'simulator' },
  { id: 'FLOW-7', group: 'flow', kind: 'flow-vars', setup: 'flow fixtures and settings home', assertion: 'stdout contains Running flow', coverage: 'simulator' },
  { id: 'FLOW-8', group: 'flow', kind: 'subflow', setup: 'flow fixtures and settings home', assertion: 'stdout contains Running flow', coverage: 'simulator' },
  { id: 'FLOW-9', group: 'flow', kind: 'subflow-error', setup: 'flow fixtures', assertion: 'undeclared output fails', coverage: 'simulator' },
  { id: 'FLOW-10', group: 'flow', kind: 'subflow-error', setup: 'flow fixtures', assertion: 'cycle fails', coverage: 'simulator' },
  { id: 'FLOW-11', group: 'flow', kind: 'flow-basic', setup: 'flow fixtures and settings home', assertion: 'stdout contains Running flow', coverage: 'simulator' },
  { id: 'FLOW-12', group: 'flow', kind: 'return-if', setup: 'flow fixtures', assertion: 'returnIf matched', coverage: 'simulator' },
  { id: 'FLOW-13', group: 'flow', kind: 'return-if-error', setup: 'flow fixtures', assertion: 'invalid returnIf fails', coverage: 'simulator' },
  { id: 'FLOW-14', group: 'flow', kind: 'tap-offset', setup: 'flow fixtures and settings home', assertion: 'stdout plus About DOM postcondition', coverage: 'simulator' },
  { id: 'FLOW-15', group: 'flow', kind: 'oslog-timeout', setup: 'flow fixtures', assertion: 'oslog reports matched count', coverage: 'simulator' },
  { id: 'FLOW-16', group: 'flow', kind: 'unsupported', setup: 'nslog flow environment', assertion: 'unsupported by simulator runner', coverage: 'unsupported', requiresPrerequisite: false },
  { id: 'FLOW-5', group: 'flow', kind: 'standard-smoke', setup: 'flow fixtures and settings home', assertion: 'screenshot artifact exists', coverage: 'simulator' },
  { id: 'FLOW-17', group: 'flow', kind: 'flow-basic', setup: 'flow fixtures and settings home', assertion: 'stdout contains Running flow', coverage: 'simulator' },
  { id: 'FLOW-18', group: 'flow', kind: 'sleep-default', setup: 'flow fixtures and settings home', assertion: 'stdout contains Running flow', coverage: 'simulator' },
  { id: 'FLOW-19', group: 'flow', kind: 'flow-reconfig', setup: 'reconfigures simulator driver then settings home', assertion: 'stdout contains Running flow', coverage: 'simulator' },
  { id: 'FLOW-20', group: 'flow', kind: 'flow-basic', setup: 'flow fixtures and settings home', assertion: 'stdout contains Running flow', coverage: 'simulator' },
  { id: 'FLOW-21', group: 'flow', kind: 'flow-target-label', setup: 'flow fixtures and settings home', assertion: 'stdout contains Running flow', coverage: 'simulator' },
  { id: 'FLOW-22', group: 'flow', kind: 'flow-verbose', setup: 'flow fixtures and settings home', assertion: 'stdout contains Running flow', coverage: 'simulator' },
  { id: 'FLOW-23', group: 'flow', kind: 'flow-basic', setup: 'flow fixtures and settings home', assertion: 'stdout contains Running flow', coverage: 'simulator' },
  { id: 'FLOW-24', group: 'flow', kind: 'bridge', setup: 'none', assertion: 'bridged to Swift CLI unit tests', coverage: 'swift-cli-unit', requiresPrerequisite: false },
  { id: 'FLOW-25', group: 'flow', kind: 'bridge', setup: 'none', assertion: 'bridged to Swift CLI unit tests', coverage: 'swift-cli-unit', requiresPrerequisite: false },
  { id: 'FLOW-26', group: 'flow', kind: 'bridge', setup: 'none', assertion: 'bridged to Swift CLI unit tests', coverage: 'swift-cli-unit', requiresPrerequisite: false },
  { id: 'FLOW-27', group: 'flow', kind: 'bridge', setup: 'none', assertion: 'bridged to Swift CLI unit tests', coverage: 'swift-cli-unit', requiresPrerequisite: false },
  { id: 'DOM-4', group: 'flow', kind: 'dom-payload-shape', setup: 'settings home', assertion: 'dom payload/output shape has expected fields', coverage: 'simulator' },
];

export function buildFlowCases(ctx) {
  const {
    ensureDriverReady,
    flowDir,
    iosHome,
    path,
    runCaseContains,
    runCaseContainsAndDomContains,
    runCaseContainsRetryTransient,
    runCaseFailsContains,
    runCaseFileExists,
    runCli,
    runDomPayloadShapeCase,
    runSwiftBridgeCase,
    settingsHome,
    unsupportedCase,
    waitForDriver,
    sim,
  } = ctx;

  const flow = (name) => path.join(flowDir, name);
  const flowArgs = (name, ...args) => ['flow', flow(name), ...args];
  const flowSetup = (setup) => async () => {
    await ensureDriverReady();
    await setup?.();
  };

  return [
    { id: 'FLOW-1', run: () => runCaseContains('FLOW-1', 'Running flow', flowArgs('basic.yaml'), flowSetup(settingsHome)) },
    { id: 'FLOW-2', run: () => runCaseFailsContains('FLOW-2', 'Flow file not found', flowArgs('missing-file.yaml'), flowSetup()) },
    { id: 'FLOW-3', run: () => runCaseContainsRetryTransient('FLOW-3', 'Running flow', flowArgs('basic.yaml'), flowSetup(settingsHome)) },
    { id: 'FLOW-4', run: () => runCaseContains('FLOW-4', 'Running flow', flowArgs('basic.yaml'), flowSetup(settingsHome)) },
    { id: 'FLOW-6', run: () => runCaseContains('FLOW-6', 'Running flow', flowArgs('basic.yaml', '--targetLabel', 'com.apple.settings.general'), flowSetup(settingsHome)) },
    { id: 'FLOW-7', run: () => runCaseContains('FLOW-7', 'Running flow', flowArgs('basic.yaml', '--targetLabel', 'com.apple.settings.general'), flowSetup(settingsHome)) },
    { id: 'FLOW-8', run: () => runCaseContains('FLOW-8', 'Running flow', flowArgs('parent.yaml'), flowSetup(settingsHome)) },
    { id: 'FLOW-9', run: () => runCaseFailsContains('FLOW-9', 'requested undeclared output', flowArgs('missing-output.yaml'), flowSetup()) },
    { id: 'FLOW-10', run: () => runCaseFailsContains('FLOW-10', 'cycle detected', flowArgs('cycle-a.yaml'), flowSetup()) },
    { id: 'FLOW-11', run: () => runCaseContains('FLOW-11', 'Running flow', flowArgs('basic.yaml', '--targetLabel', 'com.apple.settings.general'), flowSetup(settingsHome)) },
    { id: 'FLOW-12', run: () => runCaseContains('FLOW-12', 'returnIf matched', flowArgs('return-null.yaml'), flowSetup()) },
    { id: 'FLOW-13', run: () => runCaseFailsContains('FLOW-13', 'returnIf requires', flowArgs('invalid-return.yaml'), flowSetup()) },
    { id: 'FLOW-14', run: () => runCaseContainsAndDomContains('FLOW-14', 'Tap', flowArgs('tap-offset.yaml'), 'About', flowSetup(settingsHome)) },
    { id: 'FLOW-15', run: () => runCaseContains('FLOW-15', 'oslog: matched=', flowArgs('oslog-timeout.yaml'), flowSetup()) },
    { id: 'FLOW-16', run: () => unsupportedCase('FLOW-16') },
    { id: 'FLOW-5', run: () => runCaseFileExists('FLOW-5', path.join(iosHome, 'artifacts/simulator-flow-smoke-screenshot.jpg'), flowArgs('standard-smoke.yaml'), flowSetup(settingsHome)) },
    { id: 'FLOW-17', run: () => runCaseContains('FLOW-17', 'Running flow', flowArgs('basic.yaml', '--targetLabel', 'com.apple.settings.general'), flowSetup(settingsHome)) },
    { id: 'FLOW-18', run: () => runCaseContains('FLOW-18', 'Running flow', flowArgs('sleep-default.yaml'), flowSetup(settingsHome)) },
    { id: 'FLOW-19', run: () => runCaseContains('FLOW-19', 'Running flow', flowArgs('basic.yaml', '--targetLabel', 'com.apple.settings.general'), async () => { runCli(['config', '--simulator', '--udid', sim.udid]); await waitForDriver(); await settingsHome(); }) },
    { id: 'FLOW-20', run: () => runCaseContains('FLOW-20', 'Running flow', flowArgs('basic.yaml', '--targetLabel', 'com.apple.settings.general'), flowSetup(settingsHome)) },
    { id: 'FLOW-21', run: () => runCaseContains('FLOW-21', 'Running flow', flowArgs('basic.yaml', '--targetLabel', 'com.apple.settings.search'), flowSetup(settingsHome)) },
    { id: 'FLOW-22', run: () => runCaseContains('FLOW-22', 'Running flow', flowArgs('basic.yaml', '--targetLabel', 'com.apple.settings.general', '--verbose'), flowSetup(settingsHome)) },
    { id: 'FLOW-23', run: () => runCaseContains('FLOW-23', 'Running flow', flowArgs('basic.yaml', '--targetLabel', 'com.apple.settings.general'), flowSetup(settingsHome)) },
    ...['FLOW-24', 'FLOW-25', 'FLOW-26', 'FLOW-27'].map(id => ({ id, run: () => runSwiftBridgeCase(id) })),
    { id: 'DOM-4', run: runDomPayloadShapeCase },
  ];
}
