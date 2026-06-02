export const settingsBeforeContactsCaseMetadata = [
  { id: 'AA-1', group: 'settings', kind: 'home', setup: 'active driver', assertion: 'home then dom shows SpringBoard', coverage: 'simulator' },
  { id: 'AS-7', group: 'settings', kind: 'unsupported', setup: 'host lock semantics', assertion: 'unsupported by simulator runner', coverage: 'unsupported', requiresPrerequisite: false },
  { id: 'AA-2', group: 'settings', kind: 'activate-app', setup: 'active driver', assertion: 'stdout plus Settings DOM postcondition', coverage: 'simulator' },
  { id: 'AA-3', group: 'settings', kind: 'activate-app', setup: 'Safari foreground', assertion: 'stdout reports Preferences activated', coverage: 'simulator' },
  { id: 'DOM-1', group: 'settings', kind: 'dom', setup: 'settings home', assertion: 'dom shows Preferences app', coverage: 'simulator' },
  { id: 'DOM-2', group: 'settings', kind: 'dom-raw', setup: 'settings home', assertion: 'raw dom contains Application', coverage: 'simulator' },
  { id: 'DOM-5', group: 'settings', kind: 'dom', setup: 'settings home', assertion: 'dom contains Settings', coverage: 'simulator' },
  { id: 'DOM-6', group: 'settings', kind: 'dom', setup: 'settings home', assertion: 'dom omits Window header', coverage: 'simulator' },
  { id: 'DOM-7', group: 'settings', kind: 'dom-perf', setup: 'settings home', assertion: 'cold and warm DOM stay under guardrails', coverage: 'simulator' },
  { id: 'DOM-8', group: 'settings', kind: 'dom', setup: 'settings home', assertion: 'dom shows Preferences app', coverage: 'simulator' },
  { id: 'FIND-1', group: 'settings', kind: 'find', setup: 'settings home', assertion: 'stdout contains Find', coverage: 'simulator' },
  { id: 'FIND-2', group: 'settings', kind: 'find', setup: 'settings home', assertion: 'exact label does not return contains ambiguity', coverage: 'simulator' },
  { id: 'FIND-3', group: 'settings', kind: 'find', setup: 'settings home', assertion: 'find button by traits', coverage: 'simulator' },
  { id: 'FIND-4', group: 'settings', kind: 'find', setup: 'general page', assertion: 'find disabled chevron button', coverage: 'simulator' },
  { id: 'FIND-5', group: 'settings', kind: 'find-fuzzy', setup: 'settings home', assertion: 'misspelling returns suggestions or match', coverage: 'simulator' },
  { id: 'FIND-7', group: 'settings', kind: 'find', setup: 'settings home', assertion: 'find generated HomeScreen label', coverage: 'simulator' },
  { id: 'FIND-8', group: 'settings', kind: 'find', setup: 'settings home', assertion: 'find search button by traits', coverage: 'simulator' },
  { id: 'FIND-9', group: 'settings', kind: 'find', setup: 'general page', assertion: 'find disabled chevron output', coverage: 'simulator' },
  { id: 'FIND-12', group: 'settings', kind: 'find-auto-label', setup: 'settings home', assertion: 'auto label can be found by traits', coverage: 'simulator' },
  { id: 'FIND-10A', group: 'settings', kind: 'find-cindex', setup: 'settings home', assertion: 'positive cindex selects first child', coverage: 'simulator' },
  { id: 'FIND-10B', group: 'settings', kind: 'find-cindex', setup: 'settings home', assertion: 'negative cindex selects last child', coverage: 'simulator' },
  { id: 'FIND-11A', group: 'settings', kind: 'find-error', setup: 'settings home', assertion: 'out-of-range cindex returns not found', coverage: 'simulator' },
  { id: 'FIND-1B', group: 'settings', kind: 'find-input-value', setup: 'contacts new contact with first name', assertion: 'find can locate input value', coverage: 'simulator' },
  { id: 'FIND-5B', group: 'settings', kind: 'find-error', setup: 'settings home', assertion: 'missing label returns not found', coverage: 'simulator' },
  { id: 'WF-1', group: 'settings', kind: 'waitFor', setup: 'settings home', assertion: 'waitFor finds General button', coverage: 'simulator' },
  { id: 'WF-2', group: 'settings', kind: 'waitFor-error', setup: 'settings home', assertion: 'missing label times out', coverage: 'simulator' },
  { id: 'WF-4', group: 'settings', kind: 'waitFor-error', setup: 'settings home', assertion: 'short timeout reports timed out/not found', coverage: 'simulator' },
  { id: 'WF-5', group: 'settings', kind: 'waitFor-cindex', setup: 'settings home', assertion: 'waitFor cindex finds General', coverage: 'simulator' },
  { id: 'SC-2', group: 'settings', kind: 'screenshot', setup: 'settings home', assertion: 'named screenshot file exists', coverage: 'simulator' },
  { id: 'SC-1', group: 'settings', kind: 'screenshot', setup: 'settings home', assertion: 'protocol screenshot file exists', coverage: 'simulator' },
  { id: 'TAP-1', group: 'settings', kind: 'tap', setup: 'settings home', assertion: 'stdout plus About DOM postcondition', coverage: 'simulator' },
  { id: 'TAP-5', group: 'settings', kind: 'tap-offset', setup: 'settings home', assertion: 'tap with pixel offset succeeds', coverage: 'simulator' },
  { id: 'TAP-6', group: 'settings', kind: 'tap-offset-ratio', setup: 'settings home', assertion: 'tap with ratio offset succeeds', coverage: 'simulator' },
  { id: 'TAP-7', group: 'settings', kind: 'tap-offset-ratio', setup: 'settings home', assertion: 'missing y ratio defaults correctly', coverage: 'simulator' },
  { id: 'TAP-8', group: 'settings', kind: 'tap-offset', setup: 'settings home', assertion: 'missing x offset defaults correctly', coverage: 'simulator' },
  { id: 'TAP-2', group: 'settings', kind: 'tap', setup: 'general page', assertion: 'tap About succeeds', coverage: 'simulator' },
  { id: 'TAP-9', group: 'settings', kind: 'tap-error', setup: 'general page', assertion: 'coordinate target rejects offset', coverage: 'simulator' },
  { id: 'TAP-10', group: 'settings', kind: 'tap-offset', setup: 'general page', assertion: 'large offset tap reports command result', coverage: 'simulator' },
  { id: 'TAP-12', group: 'settings', kind: 'tap-cindex', setup: 'settings home', assertion: 'tap cindex navigates to About', coverage: 'simulator' },
  { id: 'TAP-13', group: 'settings', kind: 'tap-error', setup: 'settings home', assertion: 'coordinate target rejects cindex', coverage: 'simulator' },
  { id: 'TAP-3', group: 'settings', kind: 'tap-coordinate', setup: 'general page', assertion: 'coordinate tap succeeds', coverage: 'simulator' },
  { id: 'TAP-4', group: 'settings', kind: 'tap-error', setup: 'settings home', assertion: 'missing label returns not found', coverage: 'simulator' },
  { id: 'AS-9', group: 'settings', kind: 'post-dom-mutation', setup: 'settings home', assertion: 'tap --dom appends fresh DOM', coverage: 'simulator' },
  { id: 'SW-7B', group: 'settings', kind: 'swipe-distance', setup: 'general page', assertion: 'forth distance reports down direction', coverage: 'simulator' },
  { id: 'SW-10', group: 'settings', kind: 'swipe-error', setup: 'general page near top', assertion: 'back distance reports boundary', coverage: 'simulator' },
  { id: 'SW-12', group: 'settings', kind: 'swipe-error', setup: 'general page', assertion: 'missing target reports not found/suggestions', coverage: 'simulator' },
  { id: 'SW-13', group: 'settings', kind: 'swipe-target', setup: 'settings home', assertion: 'target swipe reports scrolls', coverage: 'simulator' },
  { id: 'SW-14', group: 'settings', kind: 'swipe-target', setup: 'settings home', assertion: 'target swipe reports scrolls', coverage: 'simulator' },
  { id: 'SW-15', group: 'settings', kind: 'swipe-target-from', setup: 'settings home', assertion: 'target-from swipe reports scrolls', coverage: 'simulator' },
  { id: 'SW-17', group: 'settings', kind: 'swipe-traits', setup: 'settings home', assertion: 'target with traits reports scrolls', coverage: 'simulator' },
  { id: 'SW-1', group: 'settings', kind: 'swipe-target', setup: 'general page', assertion: 'swipe to Keyboard reports scrolls', coverage: 'simulator' },
  { id: 'SW-2', group: 'settings', kind: 'swipe-target-dir', setup: 'general page', assertion: 'swipe to Keyboard with dir reports scrolls', coverage: 'simulator' },
  { id: 'SW-3', group: 'settings', kind: 'swipe-target', setup: 'general page', assertion: 'swipe to Keyboard reports scrolls', coverage: 'simulator' },
  { id: 'SW-3B', group: 'settings', kind: 'swipe-cindex', setup: 'settings home', assertion: 'target child selected by cindex', coverage: 'simulator' },
  { id: 'SW-4', group: 'settings', kind: 'swipe-target-from', setup: 'general page scrolled to Keyboard', assertion: 'back swipe reports up direction', coverage: 'simulator' },
  { id: 'SW-5', group: 'settings', kind: 'swipe-coordinate-from', setup: 'general page', assertion: 'coordinate from swipe reports scrolls', coverage: 'simulator' },
  { id: 'SW-6', group: 'settings', kind: 'swipe-coordinate-target', setup: 'general page', assertion: 'coordinate target swipe reports scrolls', coverage: 'simulator' },
  { id: 'SW-7', group: 'settings', kind: 'swipe-distance', setup: 'general page', assertion: 'distance swipe reports scrolls', coverage: 'simulator' },
  { id: 'SW-8', group: 'settings', kind: 'swipe-distance', setup: 'general page', assertion: 'distance swipe reports scrolls', coverage: 'simulator' },
  { id: 'SW-9', group: 'settings', kind: 'swipe-distance', setup: 'general page', assertion: 'large distance reports down direction', coverage: 'simulator' },
  { id: 'SW-11', group: 'settings', kind: 'swipe-error', setup: 'general page at lower boundary', assertion: 'forth distance reports boundary or connection failure', coverage: 'simulator' },
  { id: 'LP-1', group: 'settings', kind: 'longpress', setup: 'general page', assertion: 'longpress About succeeds', coverage: 'simulator' },
  { id: 'LP-2', group: 'settings', kind: 'longpress-coordinate', setup: 'general page', assertion: 'coordinate longpress succeeds', coverage: 'simulator' },
  { id: 'LP-3', group: 'settings', kind: 'longpress', setup: 'general page', assertion: 'longpress About succeeds', coverage: 'simulator' },
  { id: 'LP-4', group: 'settings', kind: 'longpress-duration', setup: 'general page', assertion: 'longpress custom duration succeeds', coverage: 'simulator' },
  { id: 'LP-5', group: 'settings', kind: 'longpress', setup: 'general page', assertion: 'longpress About succeeds', coverage: 'simulator' },
  { id: 'LP-6', group: 'settings', kind: 'longpress-icon', setup: 'SpringBoard Safari icon', assertion: 'longpress icon succeeds', coverage: 'simulator' },
  { id: 'DOM-5B', group: 'settings', kind: 'dom-springboard-menu', setup: 'SpringBoard Safari icon menu', assertion: 'dom contains shortcut item', coverage: 'simulator' },
  { id: 'SW-16B', group: 'settings', kind: 'dom-springboard-menu', setup: 'SpringBoard Safari icon menu', assertion: 'dom contains shortcut item', coverage: 'simulator' },
];

export const settingsAfterContactsCaseMetadata = [
  { id: 'TA-1', group: 'settings', kind: 'terminate-app', setup: 'settings home', assertion: 'stdout reports terminated', coverage: 'simulator' },
  { id: 'TA-2', group: 'settings', kind: 'terminate-app', setup: 'settings home', assertion: 'stdout reports terminated', coverage: 'simulator' },
  { id: 'AA-6', group: 'settings', kind: 'activate-app', setup: 'active driver', assertion: 'stdout plus Settings DOM postcondition', coverage: 'simulator' },
  { id: 'OU-1', group: 'settings', kind: 'open-url', setup: 'simulator target', assertion: 'open succeeds and Safari DOM shows Example Domain', coverage: 'simulator' },
  { id: 'OU-2', group: 'settings', kind: 'open-url-no-driver', setup: 'stopped driver', assertion: 'open succeeds without recreating driver.lock', coverage: 'simulator' },
  { id: 'OU-3', group: 'host-bridge', kind: 'bridge', setup: 'none', assertion: 'bridged to Swift CLI unit tests', coverage: 'swift-cli-unit', requiresPrerequisite: false },
  { id: 'OU-4', group: 'host-bridge', kind: 'bridge', setup: 'none', assertion: 'bridged to Swift CLI unit tests', coverage: 'swift-cli-unit', requiresPrerequisite: false },
  { id: 'OU-5', group: 'host-bridge', kind: 'bridge', setup: 'none', assertion: 'bridged to Swift CLI unit tests', coverage: 'swift-cli-unit', requiresPrerequisite: false },
  { id: 'OU-6', group: 'host-bridge', kind: 'bridge', setup: 'none', assertion: 'bridged to Swift CLI unit tests', coverage: 'swift-cli-unit', requiresPrerequisite: false },
  { id: 'HOME-1', group: 'settings', kind: 'home', setup: 'active driver', assertion: 'home then delayed dom shows SpringBoard', coverage: 'simulator' },
  { id: 'DOM-3', group: 'settings', kind: 'dom', setup: 'SpringBoard', assertion: 'dom returns App header', coverage: 'simulator' },
  { id: 'HOME-2', group: 'settings', kind: 'home-dom', setup: 'SpringBoard', assertion: 'dom shows SpringBoard', coverage: 'simulator' },
  { id: 'AA-4', group: 'settings', kind: 'activate-app', setup: 'active driver', assertion: 'stdout plus Settings DOM postcondition', coverage: 'simulator' },
  { id: 'AA-5', group: 'settings', kind: 'activate-app-error', setup: 'active driver', assertion: 'invalid bundle fails', coverage: 'simulator' },
  { id: 'AS-1', group: 'settings', kind: 'active-session-error', setup: 'no driver lock', assertion: 'dom fails with No active driver', coverage: 'simulator', requiresPrerequisite: false },
  { id: 'AS-2', group: 'settings', kind: 'parser-error', setup: 'none', assertion: 'driver command rejects --udid', coverage: 'simulator', requiresPrerequisite: false },
  { id: 'AS-3', group: 'settings', kind: 'active-session', setup: 'settings home', assertion: 'dom shows Preferences', coverage: 'simulator' },
  { id: 'AS-4', group: 'settings', kind: 'unsupported', setup: 'unit-only connect retry', assertion: 'unsupported by simulator runner', coverage: 'unsupported', requiresPrerequisite: false },
  { id: 'AS-5', group: 'settings', kind: 'unsupported', setup: 'unit-only send failure', assertion: 'unsupported by simulator runner', coverage: 'unsupported', requiresPrerequisite: false },
  { id: 'AS-6', group: 'settings', kind: 'unsupported', setup: 'unit-only flow reuse', assertion: 'unsupported by simulator runner', coverage: 'unsupported', requiresPrerequisite: false },
  { id: 'AS-8', group: 'settings', kind: 'proxy-no-driver', setup: 'no driver lock', assertion: 'proxy read/doctor do not require active driver error', coverage: 'simulator', requiresPrerequisite: false },
];

export function buildSettingsBeforeContactsCases(ctx) {
  const {
    artifactDir,
    fs,
    path,
    readDriverLockInfo,
    readFileIfExists,
    recordFail,
    recordPass,
    recordSkip,
    resetSettingsHome,
    runAutoLabelFindCase,
    runCase,
    runCaseContains,
    runCaseContainsAndDomContains,
    runCaseFailsContains,
    runCaseFailsMatches,
    runCaseMatches,
    runCli,
    runCliToFiles,
    runDomPerfCase,
    runDomNoWindowHeaderCase,
    runFindExactPreferredCase,
    runInputAndVerifyDom,
    runPostDomMutationCase,
    selected,
    settingsHome,
    generalPage,
    openContactsNewContact,
    discardContactIfNeeded,
    openHomeScreenWithSafariIcon,
  } = ctx;

  return [
    { id: 'AA-1', run: async () => {
      if (!selected('AA-1')) return recordSkip('AA-1');
      console.log('[sim-test] RUN AA-1: ios-use home && sleep 1s && dom --fresh');
      const home = runCliToFiles(['home'], path.join(artifactDir, 'AA-1-home.out'), path.join(artifactDir, 'AA-1-home.err'));
      await ctx.sleep(1000);
      const dom = runCliToFiles(['dom', '--fresh'], path.join(artifactDir, 'AA-1.out'), path.join(artifactDir, 'AA-1.err'));
      if (home.code === 0 && dom.code === 0 && dom.stdout.includes('App: com.apple.springboard')) recordPass('AA-1');
      else recordFail('AA-1', home.stdout + home.stderr + dom.stdout + dom.stderr, home.code === 0 && dom.code === 0 ? 'assertion' : 'command');
    } },
    { id: 'AS-7', run: () => ctx.unsupportedCase('AS-7') },
    { id: 'AA-2', run: () => runCaseContainsAndDomContains('AA-2', 'App com.apple.Preferences activated', ['activateApp', 'com.apple.Preferences'], 'App: com.apple.Preferences') },
    { id: 'AA-3', run: async () => {
      await runCaseContains('AA-3', 'activated', ['activateApp', 'com.apple.Preferences'], async () => {
        runCliToFiles(['activateApp', 'com.apple.mobilesafari'], path.join(artifactDir, 'AA-3-safari.out'), path.join(artifactDir, 'AA-3-safari.err'));
      });
    } },
    { id: 'DOM-1', run: () => runCaseContains('DOM-1', 'App: com.apple.Preferences', ['dom', '--fresh'], settingsHome) },
    { id: 'DOM-2', run: () => runCaseContains('DOM-2', '[App]', ['dom', '--raw', '--fresh'], settingsHome) },
    { id: 'DOM-5', run: () => runCaseContains('DOM-5', 'Settings', ['dom', '--fresh'], settingsHome) },
    { id: 'DOM-6', run: runDomNoWindowHeaderCase },
    { id: 'DOM-7', run: runDomPerfCase },
    { id: 'DOM-8', run: () => runCaseContains('DOM-8', 'App: com.apple.Preferences', ['dom', '--fresh'], settingsHome) },
    { id: 'FIND-1', run: () => runCaseContains('FIND-1', 'Find', ['find', 'General'], settingsHome) },
    { id: 'FIND-2', run: () => runFindExactPreferredCase('FIND-2') },
    { id: 'FIND-3', run: () => runCaseContains('FIND-3', 'Find', ['find', 'com.apple.settings.general', '--traits', 'Button'], settingsHome) },
    { id: 'FIND-4', run: () => runCaseContains('FIND-4', 'Find', ['find', 'chevron', '--traits', 'Button,disabled'], generalPage) },
    { id: 'FIND-5', run: () => runCaseMatches('FIND-5', /suggestions|Did you mean|General/, ['find', 'Generak'], settingsHome) },
    { id: 'FIND-7', run: () => runCaseContains('FIND-7', 'Find', ['find', 'HomeScreen'], settingsHome) },
    { id: 'FIND-8', run: () => runCaseContains('FIND-8', 'Find', ['find', 'com.apple.settings.search', '--traits', 'Button'], settingsHome) },
    { id: 'FIND-9', run: () => runCaseContains('FIND-9', 'chevron', ['find', 'chevron', '--traits', 'Button,disabled'], generalPage) },
    { id: 'FIND-12', run: runAutoLabelFindCase },
    { id: 'FIND-10A', run: () => runCaseContains('FIND-10A', 'Text "General"', ['find', 'com.apple.settings.general', '--traits', 'Button', '--cindex', '0'], settingsHome) },
    { id: 'FIND-10B', run: () => runCaseContains('FIND-10B', 'chevron.forward', ['find', 'com.apple.settings.general', '--traits', 'Button', '--cindex', '-1'], settingsHome) },
    { id: 'FIND-11A', run: () => runCaseFailsContains('FIND-11A', 'not found', ['find', 'com.apple.settings.general', '--traits', 'Button', '--cindex', '99'], settingsHome) },
    { id: 'FIND-1B', run: async () => {
      await runCaseContains('FIND-1B', 'First name=iosuse-find', ['find', 'iosuse-find', '--traits', 'Input'], async () => {
        await openContactsNewContact();
        const input = runCliToFiles(['input', '--label', 'First name', '--content', 'iosuse-find', '--traits', 'Input'], path.join(artifactDir, 'FIND-1B-input.out'), path.join(artifactDir, 'FIND-1B-input.err'));
        if (input.code !== 0) throw new Error(`FIND-1B setup input failed\n${input.stdout}${input.stderr}`);
      });
      if (selected('FIND-1B')) await discardContactIfNeeded();
    } },
    { id: 'FIND-5B', run: () => runCaseFailsContains('FIND-5B', 'not found', ['find', '__ios_use_missing_label__'], settingsHome) },
    { id: 'WF-1', run: () => runCaseContains('WF-1', 'waited=', ['waitFor', '--label', 'com.apple.settings.general', '--traits', 'Button', '--timeout', '2'], settingsHome) },
    { id: 'WF-2', run: () => runCaseFailsMatches('WF-2', /timed out|not found/i, ['waitFor', '--label', '__ios_use_missing_label__', '--timeout', '0.3'], settingsHome) },
    { id: 'WF-4', run: () => runCaseFailsMatches('WF-4', /timed out|not found/i, ['waitFor', '--label', '__ios_use_missing_label__', '--timeout', '0.2'], settingsHome) },
    { id: 'WF-5', run: () => runCaseContains('WF-5', 'General', ['waitFor', '--label', 'com.apple.settings.general', '--traits', 'Button', '--cindex', '0', '--timeout', '2'], settingsHome) },
    { id: 'SC-2', run: async () => {
      await runCase('SC-2', ['screenshot', '--name', 'sim_command_screenshot'], settingsHome);
      if (selected('SC-2')) {
        const screenshot = path.join(ctx.iosHome, 'artifacts/sim_command_screenshot.jpg');
        if (fs.existsSync(screenshot) && fs.statSync(screenshot).size > 0) fs.copyFileSync(screenshot, path.join(artifactDir, 'sim_command_screenshot.jpg'));
        else recordFail('SC-2', `[sim-test] FAIL SC-2 screenshot file missing: ${screenshot}\n`, 'assertion');
      }
    } },
    { id: 'SC-1', run: async () => {
      if (!selected('SC-1')) return recordSkip('SC-1');
      await settingsHome();
      console.log('[sim-test] RUN SC-1: ios-use screenshot smoke');
      const out = path.join(artifactDir, 'SC-1.out');
      const err = path.join(artifactDir, 'SC-1.err');
      const name = 'sim_command_protocol_screenshot';
      const res = runCliToFiles(['screenshot', '--name', name], out, err);
      const screenshot = path.join(ctx.iosHome, 'artifacts', `${name}.jpg`);
      if (res.code === 0 && fs.existsSync(screenshot) && fs.statSync(screenshot).size > 2) recordPass('SC-1');
      else recordFail('SC-1', res.stdout + res.stderr, res.code === 0 ? 'assertion' : 'command');
    } },
    { id: 'TAP-1', run: () => runCaseContainsAndDomContains('TAP-1', 'Tap', ['tap', 'com.apple.settings.general', '--traits', 'Button'], 'About', settingsHome) },
    { id: 'TAP-5', run: () => runCaseContains('TAP-5', 'Tap', ['tap', 'com.apple.settings.general', '--offset', '10,10', '--traits', 'Button'], settingsHome) },
    { id: 'TAP-6', run: () => runCaseContains('TAP-6', 'Tap', ['tap', 'com.apple.settings.general', '--offset-ratio', '0.5,0.5', '--traits', 'Button'], settingsHome) },
    { id: 'TAP-7', run: () => runCaseContains('TAP-7', 'Tap', ['tap', 'com.apple.settings.general', '--offset-ratio', '0.5,', '--traits', 'Button'], settingsHome) },
    { id: 'TAP-8', run: () => runCaseContains('TAP-8', 'Tap', ['tap', 'com.apple.settings.general', '--offset', ',10', '--traits', 'Button'], settingsHome) },
    { id: 'TAP-2', run: () => runCaseContains('TAP-2', 'Tap', ['tap', 'About', '--traits', 'Cell'], generalPage) },
    { id: 'TAP-9', run: () => runCaseFailsContains('TAP-9', 'offset requires element label', ['tap', '200,400', '--offset', '1,1'], generalPage) },
    { id: 'TAP-10', run: () => runCaseContains('TAP-10', 'Tap', ['tap', 'About', '--offset', '500,500', '--traits', 'Cell'], generalPage) },
    { id: 'TAP-12', run: async () => {
      if (!selected('TAP-12')) return recordSkip('TAP-12');
      await settingsHome();
      const out = path.join(artifactDir, 'TAP-12.out');
      const err = path.join(artifactDir, 'TAP-12.err');
      console.log('[sim-test] RUN TAP-12: tap cindex child and verify navigation');
      const tap = runCliToFiles(['tap', 'com.apple.settings.general', '--traits', 'Button', '--cindex', '0'], out, err);
      const verify = runCliToFiles(['find', 'About', '--traits', 'Cell'], path.join(artifactDir, 'TAP-12-verify.out'), path.join(artifactDir, 'TAP-12-verify.err'));
      if (tap.code === 0 && verify.code === 0) recordPass('TAP-12');
      else recordFail('TAP-12', tap.stdout + tap.stderr + verify.stdout + verify.stderr, tap.code === 0 && verify.code === 0 ? 'assertion' : 'command');
    } },
    { id: 'TAP-13', run: () => runCaseFailsContains('TAP-13', 'point target does not support traits or cindex', ['tap', '200,400', '--cindex', '0'], settingsHome) },
    { id: 'TAP-3', run: () => runCase('TAP-3', ['tap', '200,400'], generalPage) },
    { id: 'TAP-4', run: () => runCaseFailsContains('TAP-4', 'not found', ['tap', '__ios_use_missing_label__'], settingsHome) },
    { id: 'AS-9', run: runPostDomMutationCase },
    { id: 'SW-7B', run: () => runCaseMatches('SW-7B', /scrolls=\d+ direction=down/, ['swipe', '--distance', '200', '--dir', 'forth'], generalPage) },
    { id: 'SW-10', run: () => runCaseFailsMatches('SW-10', /boundary.*direction=up/, ['swipe', '--distance', '200', '--dir', 'back'], async () => { await generalPage(); runCli(['swipe', '--distance', '200', '--dir', 'back']); }) },
    { id: 'SW-12', run: () => runCaseFailsMatches('SW-12', /not found|suggestions/i, ['swipe', '--to', '__ios_use_missing_label__'], generalPage) },
    { id: 'SW-13', run: () => runCaseContains('SW-13', 'scrolls=', ['swipe', '--to', 'Settings'], settingsHome) },
    { id: 'SW-14', run: () => runCaseContains('SW-14', 'scrolls=', ['swipe', '--to', 'Settings'], settingsHome) },
    { id: 'SW-15', run: () => runCaseContains('SW-15', 'scrolls=', ['swipe', '--to', 'Settings', '--from', 'com.apple.settings.general'], settingsHome) },
    { id: 'SW-17', run: () => runCaseContains('SW-17', 'scrolls=', ['swipe', '--to', 'com.apple.settings.general', '--traits', 'Button'], settingsHome) },
    { id: 'SW-1', run: () => runCaseContains('SW-1', 'scrolls=', ['swipe', '--to', 'Keyboard', '--traits', 'Cell'], generalPage) },
    { id: 'SW-2', run: () => runCaseContains('SW-2', 'scrolls=', ['swipe', '--to', 'Keyboard', '--dir', 'forth', '--traits', 'Cell'], generalPage) },
    { id: 'SW-3', run: () => runCaseContains('SW-3', 'scrolls=', ['swipe', '--to', 'Keyboard', '--traits', 'Cell'], generalPage) },
    { id: 'SW-3B', run: () => runCaseContains('SW-3B', 'Text "Search"', ['swipe', '--to', 'com.apple.settings.search', '--from', 'com.apple.settings.general', '--traits', 'Button', '--cindex', '0'], settingsHome) },
    { id: 'SW-4', run: () => runCaseMatches('SW-4', /scrolls=\d+ direction=up/, ['swipe', '--to', 'About', '--from', 'Keyboard', '--dir', 'back', '--traits', 'Cell'], async () => { await generalPage(); runCliToFiles(['swipe', '--to', 'Keyboard', '--traits', 'Cell'], path.join(artifactDir, 'SW-4-setup.out'), path.join(artifactDir, 'SW-4-setup.err')); }) },
    { id: 'SW-5', run: () => runCaseContains('SW-5', 'scrolls=', ['swipe', '--to', 'About', '--from', '200,650', '--traits', 'Cell'], generalPage) },
    { id: 'SW-6', run: () => runCaseContains('SW-6', 'scrolls=', ['swipe', '--to', '100,700'], generalPage) },
    { id: 'SW-7', run: () => runCaseContains('SW-7', 'scrolls=', ['swipe', '--distance', '200', '--dir', 'forth'], generalPage) },
    { id: 'SW-8', run: () => runCaseContains('SW-8', 'scrolls=', ['swipe', '--distance', '200', '--dir', 'forth'], generalPage) },
    { id: 'SW-9', run: () => runCaseMatches('SW-9', /scrolls=\d+ direction=down/, ['swipe', '--distance', '900', '--dir', 'forth'], generalPage) },
    { id: 'SW-11', run: () => runCaseFailsMatches('SW-11', /boundary.*direction=down|not connected/i, ['swipe', '--distance', '200', '--dir', 'forth'], async () => { await generalPage(); for (let i = 0; i < 6; i++) runCli(['swipe', '--distance', '900', '--dir', 'forth']); }) },
    { id: 'LP-1', run: () => runCaseContains('LP-1', 'Longpress', ['longpress', 'About', '--traits', 'Cell'], generalPage) },
    { id: 'LP-2', run: () => runCaseContains('LP-2', 'Longpress', ['longpress', '200,400'], generalPage) },
    { id: 'LP-3', run: () => runCaseContains('LP-3', 'Longpress', ['longpress', 'About', '--traits', 'Cell'], generalPage) },
    { id: 'LP-4', run: () => runCaseContains('LP-4', 'Longpress', ['longpress', 'About', '--duration', '500', '--traits', 'Cell'], generalPage) },
    { id: 'LP-5', run: () => runCaseContains('LP-5', 'Longpress', ['longpress', 'About', '--traits', 'Cell'], generalPage) },
    { id: 'LP-6', run: () => runCaseContains('LP-6', 'Longpress', ['longpress', 'Safari', '--traits', 'Icon', '--duration', '900'], openHomeScreenWithSafariIcon) },
    { id: 'DOM-5B', run: () => runCaseContains('DOM-5B', 'com.apple.springboardhome.application-shortcut-item', ['dom', '--fresh'], () => ctx.openSpringboardIconMenu('DOM-5B')) },
    { id: 'SW-16B', run: () => runCaseContains('SW-16B', 'com.apple.springboardhome.application-shortcut-item', ['dom', '--fresh'], () => ctx.openSpringboardIconMenu('SW-16B')) },
  ];
}

export function buildSettingsAfterContactsCases(ctx) {
  const {
    artifactDir,
    path,
    readDriverLockInfo,
    readFileIfExists,
    recordFail,
    recordPass,
    recordSkip,
    runCaseContains,
    runCaseContainsAndDomContains,
    runCaseFailsContains,
    runCaseFailsMatches,
    runCli,
    runCliToFiles,
    runCommand,
    runProxyReadDoctorNoLockCase,
    runSwiftBridgeCase,
    selected,
    settingsHome,
    sim,
    sleep,
    stopDriverIfLocked,
    unsupportedCase,
    ensureDriverStarted,
    verifyExampleDomainOpened,
  } = ctx;

  return [
    { id: 'TA-1', run: () => runCaseContains('TA-1', 'terminated', ['terminateApp', 'com.apple.Preferences'], settingsHome) },
    { id: 'TA-2', run: () => runCaseContains('TA-2', 'terminated', ['terminateApp', 'com.apple.Preferences'], settingsHome) },
    { id: 'AA-6', run: () => runCaseContainsAndDomContains('AA-6', 'activated', ['activateApp', 'com.apple.Preferences'], 'App: com.apple.Preferences') },
    { id: 'OU-1', run: async () => {
      if (!selected('OU-1')) return recordSkip('OU-1');
      console.log('[sim-test] RUN OU-1: open https://example.com and verify Safari DOM');
      const open = runCliToFiles(['open', 'https://example.com', '--udid', sim.udid], path.join(artifactDir, 'OU-1.out'), path.join(artifactDir, 'OU-1.err'));
      const verified = open.code === 0 && await verifyExampleDomainOpened('OU-1');
      if (verified) recordPass('OU-1');
      else recordFail('OU-1', open.stdout + open.stderr + readFileIfExists(path.join(artifactDir, 'OU-1-verify-dom.out')) + readFileIfExists(path.join(artifactDir, 'OU-1-verify-dom.err')), open.code === 0 ? 'assertion' : 'command');
    } },
    { id: 'OU-2', run: async () => {
      if (!selected('OU-2')) return recordSkip('OU-2');
      console.log('[sim-test] RUN OU-2: ios-use stop && open https://example.com --udid <sim> without recreating driver.lock');
      const stopBefore = stopDriverIfLocked('OU-2-stop-before') ?? { code: 0, stdout: '', stderr: '' };
      const open = runCliToFiles(['open', 'https://example.com', '--udid', sim.udid], path.join(artifactDir, 'OU-2.out'), path.join(artifactDir, 'OU-2.err'));
      const lockAfterOpen = readDriverLockInfo();
      const stopAfter = runCliToFiles(['stop'], path.join(artifactDir, 'OU-2-stop-after.out'), path.join(artifactDir, 'OU-2-stop-after.err'));
      const verified = stopBefore.code === 0
        && open.code === 0
        && lockAfterOpen == null
        && stopAfter.code !== 0
        && `${stopAfter.stdout}\n${stopAfter.stderr}`.includes('No active driver');
      if (verified) ensureDriverStarted('OU-2-restore');
      if (verified) recordPass('OU-2');
      else recordFail('OU-2', stopBefore.stdout + stopBefore.stderr + open.stdout + open.stderr + stopAfter.stdout + stopAfter.stderr, stopBefore.code === 0 && open.code === 0 ? 'assertion' : 'command');
    } },
    ...['OU-3', 'OU-4', 'OU-5', 'OU-6'].map(id => ({ id, run: () => runSwiftBridgeCase(id) })),
    { id: 'HOME-1', run: async () => {
      const id = 'HOME-1';
      if (!selected(id)) return recordSkip(id);
      const out = path.join(artifactDir, `${id}.out`);
      const err = path.join(artifactDir, `${id}.err`);
      const domOut = path.join(artifactDir, `${id}-dom.out`);
      const domErr = path.join(artifactDir, `${id}-dom.err`);
      console.log('[sim-test] RUN HOME-1: ios-use home + delayed dom postcondition');
      const home = await runCommand(id, ['home'], out, err);
      if (!home) return;
      await sleep(1000);
      const dom = await runCommand(id, ['dom', '--fresh'], domOut, domErr);
      if (!dom) return;
      if (home.code === 0 && home.stdout.includes('Home') && dom.code === 0 && dom.stdout.includes('App: com.apple.springboard')) recordPass(id);
      else recordFail(id, home.stdout + home.stderr + dom.stdout + dom.stderr, home.code === 0 && dom.code === 0 ? 'assertion' : 'command');
    } },
    { id: 'DOM-3', run: () => runCaseContains('DOM-3', 'App:', ['dom', '--fresh'], async () => { runCli(['home']); await sleep(1000); }) },
    { id: 'HOME-2', run: () => runCaseContains('HOME-2', 'App: com.apple.springboard', ['dom', '--fresh'], async () => { runCli(['home']); await sleep(1000); }) },
    { id: 'AA-4', run: () => runCaseContainsAndDomContains('AA-4', 'activated', ['activateApp', 'com.apple.Preferences'], 'App: com.apple.Preferences') },
    { id: 'AA-5', run: () => runCaseFailsMatches('AA-5', /app not found|state=unknown|not installed/i, ['activateApp', 'com.iosuse.invalid.bundle']) },
    { id: 'AS-1', run: async () => { if (!selected('AS-1')) return recordSkip('AS-1'); stopDriverIfLocked('AS-1'); await runCaseFailsContains('AS-1', 'No active driver', ['dom', '--fresh']); } },
    { id: 'AS-2', run: () => runCaseFailsMatches('AS-2', /unknown option '--udid'/i, ['dom', '--fresh', '--udid', '00000000-0000-0000-0000-000000000000']) },
    { id: 'AS-3', run: () => runCaseContains('AS-3', 'App: com.apple.Preferences', ['dom', '--fresh'], settingsHome) },
    { id: 'AS-4', run: () => unsupportedCase('AS-4') },
    { id: 'AS-5', run: () => unsupportedCase('AS-5') },
    { id: 'AS-6', run: () => unsupportedCase('AS-6') },
    { id: 'AS-8', run: runProxyReadDoctorNoLockCase },
  ];
}
