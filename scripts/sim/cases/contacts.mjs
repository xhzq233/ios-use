export const contactsCaseMetadata = [
  { id: 'IN-1', group: 'contacts', kind: 'input', setup: 'new contact form', assertion: 'dom contains first name value', coverage: 'simulator' },
  { id: 'IN-2', group: 'contacts', kind: 'input-traits', setup: 'new contact form', assertion: 'dom contains last name value', coverage: 'simulator' },
  { id: 'IN-3', group: 'contacts', kind: 'input-focused', setup: 'new contact form with focused first name', assertion: 'input without --tap appends to focused field while keyboard is visible', coverage: 'simulator' },
  { id: 'IN-4', group: 'contacts', kind: 'input-error', setup: 'settings home', assertion: 'non-input target fails', coverage: 'simulator' },
  { id: 'IN-5', group: 'contacts', kind: 'input-search', setup: 'Contacts app search field', assertion: 'dom contains search content', coverage: 'simulator' },
  { id: 'IN-6', group: 'contacts', kind: 'input-keyboard-open', setup: 'new contact form', assertion: 'dom contains two edited fields', coverage: 'simulator' },
  { id: 'DA-1', group: 'contacts', kind: 'dismiss-alert', setup: 'discard contact alert', assertion: 'alert dismissed', coverage: 'simulator' },
  { id: 'DA-2', group: 'contacts', kind: 'dismiss-alert-index', setup: 'discard contact alert', assertion: 'alert dismissed by index', coverage: 'simulator' },
  { id: 'TAP-11', group: 'contacts', kind: 'wait-then-tap', setup: 'discard contact alert', assertion: 'waitFor and immediate tap both succeed', coverage: 'simulator' },
];

export function buildContactsCases(ctx) {
  const {
    artifactDir,
    path,
    readFileIfExists,
    recordFail,
    recordPass,
    recordRecovery,
    recordSkip,
    runCaseContains,
    runCaseFailsMatches,
    runCli,
    runInputAndVerifyDom,
    selected,
    settingsHome,
    sleep,
    openContactsNewContact,
    discardContactIfNeeded,
    openContactsDiscardAlert,
    verifyContactsNameFields,
    runCliToFiles,
  } = ctx;

  return [
    { id: 'IN-1', run: async () => { await runInputAndVerifyDom('IN-1', 'First name', 'Alpha', 'First name=Alpha', [], openContactsNewContact); if (selected('IN-1')) await discardContactIfNeeded(); } },
    { id: 'IN-2', run: async () => { await runInputAndVerifyDom('IN-2', 'Last name', 'Beta', 'Last name=Beta', ['--traits', 'Input'], openContactsNewContact); if (selected('IN-2')) await discardContactIfNeeded(); } },
    { id: 'IN-3', run: async () => {
      if (!selected('IN-3')) return recordSkip('IN-3');
      await openContactsNewContact();
      const setup = runCliToFiles(['input', '--tap', 'First name', '--content', 'Alpha', '--traits', 'Input'], path.join(artifactDir, 'IN-3-setup.out'), path.join(artifactDir, 'IN-3-setup.err'));
      if (setup.code !== 0) {
        recordFail('IN-3', setup.stdout + setup.stderr, 'setup');
        await discardContactIfNeeded();
        return;
      }
      const out = path.join(artifactDir, 'IN-3.out');
      const err = path.join(artifactDir, 'IN-3.err');
      const domOut = path.join(artifactDir, 'IN-3-dom.out');
      const domErr = path.join(artifactDir, 'IN-3-dom.err');
      console.log('[sim-test] RUN IN-3: ios-use input --content More with keyboard visible');
      const res = runCliToFiles(['input', '--content', 'More'], out, err);
      const dom = runCliToFiles(['dom', '--fresh'], domOut, domErr);
      if (res.code === 0 && dom.code === 0 && dom.stdout.includes('First name=AlphaMore')) recordPass('IN-3');
      else recordFail('IN-3', `${res.stdout}${res.stderr}${dom.stdout}${dom.stderr}`, res.code === 0 && dom.code === 0 ? 'assertion' : 'command');
      await discardContactIfNeeded();
    } },
    { id: 'IN-4', run: () => runCaseFailsMatches('IN-4', /not inputtable|not found|keyboard|failed/i, ['input', '--tap', 'General', '--content', 'Nope', '--traits', 'Button'], settingsHome) },
    { id: 'IN-5', run: () => runInputAndVerifyDom('IN-5', 'Search', 'ZZZIOSUse', 'ZZZIOSUse', ['--traits', 'Input'], async () => {
      runCli(['terminateApp', 'com.apple.MobileAddressBook']);
      runCli(['activateApp', 'com.apple.MobileAddressBook']);
      await sleep(1000);
    }) },
    { id: 'IN-6', run: async () => {
      if (!selected('IN-6')) return recordSkip('IN-6');
      console.log('[sim-test] RUN IN-6: input two Contacts fields with keyboard open');
      const firstAttempt = await verifyContactsNameFields('IN-6', '');
      let attempts = 1;
      if (!firstAttempt) {
        attempts++;
        recordRecovery('case-retry', 'IN-6', 'rebuilding Contacts form');
        await discardContactIfNeeded();
        console.log('[sim-test] IN-6: retrying after rebuilding Contacts form');
      }
      const casePassed = firstAttempt || await verifyContactsNameFields('IN-6', '-retry');
      if (casePassed) {
        recordPass('IN-6', { attempts });
      } else {
        const details = [
          'IN-6.out',
          'IN-6.err',
          'IN-6-dom.out',
          'IN-6-dom.err',
          'IN-6-retry.out',
          'IN-6-retry.err',
          'IN-6-retry-dom.out',
          'IN-6-retry-dom.err',
        ].map(file => readFileIfExists(path.join(artifactDir, file))).join('');
        recordFail('IN-6', details, 'assertion', { attempts });
      }
      await discardContactIfNeeded();
    } },
    { id: 'DA-1', run: () => runCaseContains('DA-1', 'Alert dismissed', ['dismissAlert'], openContactsDiscardAlert) },
    { id: 'DA-2', run: () => runCaseContains('DA-2', 'Alert dismissed', ['dismissAlert', '--index', '0'], openContactsDiscardAlert) },
    { id: 'TAP-11', run: async () => {
      if (!selected('TAP-11')) return recordSkip('TAP-11');
      const out = path.join(artifactDir, 'TAP-11.out');
      const err = path.join(artifactDir, 'TAP-11.err');
      console.log('[sim-test] RUN TAP-11: waitFor Discard Changes then immediate tap');
      await openContactsDiscardAlert();
      const wait = runCli(['waitFor', '--label', 'Discard Changes', '--traits', 'Button', '--timeout', '3']);
      const tap = runCli(['tap', 'Discard Changes', '--traits', 'Button']);
      ctx.writeFile(out, wait.stdout + tap.stdout);
      ctx.writeFile(err, wait.stderr + tap.stderr);
      if (wait.code === 0 && tap.code === 0) recordPass('TAP-11');
      else recordFail('TAP-11', wait.stdout + wait.stderr + tap.stdout + tap.stderr, 'command');
    } },
  ];
}
