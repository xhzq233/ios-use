export const deviceConfigCaseMetadata = [
  { id: 'DEV-2', group: 'device-config', kind: 'device-list', setup: 'none', assertion: 'stdout contains Simulator', coverage: 'simulator' },
  { id: 'DEV-3', group: 'device-config', kind: 'help', setup: 'none', assertion: 'stdout contains Usage', coverage: 'simulator' },
  { id: 'DEV-1', group: 'device-config', kind: 'device-list', setup: 'none', assertion: 'stdout matches real-device listing or empty state', coverage: 'simulator' },
  { id: 'DEV-5', group: 'device-config', kind: 'device-list', setup: 'empty IOS_USE_HOME', assertion: 'stdout does not mark simulator configured', coverage: 'simulator' },
  { id: 'CFG-4', group: 'device-config', kind: 'config', setup: 'self configures simulator driver', assertion: 'command succeeds and driver becomes ready', coverage: 'simulator', providesPrerequisite: true },
  { id: 'CFG-1', group: 'device-config', kind: 'config', setup: 'configured simulator', assertion: 'config list contains simulator udid', coverage: 'simulator', requiresPrerequisite: false },
  { id: 'CFG-7', group: 'device-config', kind: 'config-state', setup: 'configured simulator', assertion: 'config entry only stores bundleId and driverVersion', coverage: 'simulator', requiresPrerequisite: false },
  { id: 'CFG-5', group: 'device-config', kind: 'parser-error', setup: 'none', assertion: 'unknown option error', coverage: 'simulator', requiresPrerequisite: false },
  { id: 'CFG-6', group: 'device-config', kind: 'parser-error', setup: 'none', assertion: 'unknown option error', coverage: 'simulator', requiresPrerequisite: false },
  { id: 'CLI-1', group: 'host-bridge', kind: 'bridge', setup: 'none', assertion: 'bridged to Swift CLI unit tests', coverage: 'swift-cli-unit', requiresPrerequisite: false },
  { id: 'CLI-2', group: 'host-bridge', kind: 'bridge', setup: 'none', assertion: 'bridged to Swift CLI unit tests', coverage: 'swift-cli-unit', requiresPrerequisite: false },
  { id: 'CLI-3', group: 'host-bridge', kind: 'bridge', setup: 'none', assertion: 'bridged to Swift CLI unit tests', coverage: 'swift-cli-unit', requiresPrerequisite: false },
  { id: 'DEV-7', group: 'host-bridge', kind: 'bridge', setup: 'none', assertion: 'bridged to Swift CLI unit tests', coverage: 'swift-cli-unit', requiresPrerequisite: false },
  { id: 'CFG-8', group: 'host-bridge', kind: 'bridge', setup: 'none', assertion: 'bridged to Swift CLI unit tests', coverage: 'swift-cli-unit', requiresPrerequisite: false },
  { id: 'START-1R', group: 'device-config', kind: 'unsupported', setup: 'real device', assertion: 'unsupported by simulator runner', coverage: 'unsupported', requiresPrerequisite: false },
  { id: 'START-2', group: 'device-config', kind: 'lifecycle-error', setup: 'no active driver', assertion: 'start fails for unknown target', coverage: 'simulator', requiresPrerequisite: false },
  { id: 'START-1', group: 'device-config', kind: 'lifecycle', setup: 'configured simulator', assertion: 'driver.lock is written and dom is reachable', coverage: 'simulator' },
  { id: 'START-3', group: 'device-config', kind: 'lifecycle-error', setup: 'active driver', assertion: 'start rejects existing lock', coverage: 'simulator' },
  { id: 'DEV-4', group: 'device-config', kind: 'device-list', setup: 'configured simulator', assertion: 'devices marks configured', coverage: 'simulator' },
  { id: 'DEV-6', group: 'device-config', kind: 'device-list', setup: 'configured simulator', assertion: 'devices lists available targets', coverage: 'simulator' },
];

export function buildDeviceConfigCases(ctx) {
  const {
    artifactDir,
    caseFilterIds,
    emptyHomeName,
    iosUseCli,
    path,
    recordFail,
    recordPass,
    recordSkip,
    rootDir,
    runCase,
    runCaseContains,
    runCaseFailsContains,
    runCaseMatches,
    runConfigDriverVersionCase,
    runExternalToFiles,
    runStartCreatesDriverLockCase,
    runSwiftBridgeCase,
    selected,
    sim,
    stopDriverIfLocked,
    unsupportedCase,
    waitForDriver,
    ensureDriverStarted,
  } = ctx;

  return [
    { id: 'DEV-2', run: () => runCaseContains('DEV-2', 'Simulator', ['devices', '--simulator']) },
    { id: 'DEV-3', run: () => runCaseContains('DEV-3', 'Usage:', ['devices', '--help']) },
    { id: 'DEV-1', run: () => runCaseMatches('DEV-1', /Device|No connected real devices/, ['devices']) },
    { id: 'DEV-5', run: async () => {
      if (!selected('DEV-5')) return recordSkip('DEV-5');
      const out = path.join(artifactDir, 'DEV-5.out');
      const err = path.join(artifactDir, 'DEV-5.err');
      console.log('[sim-test] RUN DEV-5: ios-use devices --simulator (empty IOS_USE_HOME)');
      const res = runExternalToFiles([iosUseCli, 'devices', '--simulator'], out, err, { IOS_USE_HOME: path.join(artifactDir, emptyHomeName) });
      if (res.code === 0 && !res.stdout.includes('configured')) recordPass('DEV-5');
      else recordFail('DEV-5', res.stdout + res.stderr, res.code === 0 ? 'assertion' : 'command');
    } },
    { id: 'CFG-4', run: async () => {
      await runCase('CFG-4', ['config', '--simulator', '--udid', sim.udid]);
      if (selected('CFG-4') || !caseFilterIds) await waitForDriver();
    } },
    { id: 'CFG-1', run: () => runCaseContains('CFG-1', sim.udid, ['config', '--list']) },
    { id: 'CFG-7', run: runConfigDriverVersionCase },
    { id: 'CFG-5', run: () => runCaseFailsContains('CFG-5', 'unknown option', ['config', '--ipa', path.join(rootDir, '.ios-use/driver-sim.ipa')]) },
    { id: 'CFG-6', run: () => runCaseFailsContains('CFG-6', 'unknown option', ['config', '--port', '8100']) },
    ...['CLI-1', 'CLI-2', 'CLI-3', 'DEV-7', 'CFG-8'].map(id => ({ id, run: () => runSwiftBridgeCase(id) })),
    { id: 'START-1R', run: () => unsupportedCase('START-1R') },
    { id: 'START-2', run: async () => {
      if (!selected('START-2')) return recordSkip('START-2');
      stopDriverIfLocked('START-2-cleanup');
      await runCaseFailsContains('START-2', 'config', ['start', '00000000-0000-0000-0000-000000000000']);
    } },
    { id: 'START-1', run: runStartCreatesDriverLockCase },
    { id: 'START-3', run: async () => {
      if (!selected('START-3')) return recordSkip('START-3');
      ensureDriverStarted('START-3-existing');
      await runCaseFailsContains('START-3', 'Driver already started', ['start', sim.udid]);
    } },
    { id: 'DEV-4', run: () => runCaseContains('DEV-4', 'configured', ['devices', '--simulator']) },
    { id: 'DEV-6', run: () => runCaseMatches('DEV-6', /Simulator|Device/, ['devices', '--simulator']) },
  ];
}
