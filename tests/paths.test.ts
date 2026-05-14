import { afterEach, describe, expect, test } from 'bun:test';
import os from 'os';
import path from 'path';

describe('ios-use paths', () => {
  const originalIosUseHome = process.env.IOS_USE_HOME;

  afterEach(() => {
    if (originalIosUseHome === undefined) {
      delete process.env.IOS_USE_HOME;
    } else {
      process.env.IOS_USE_HOME = originalIosUseHome;
    }
  });

  test('defaults to ~/.ios-use', async () => {
    delete process.env.IOS_USE_HOME;
    const paths = await import(`../src/utils/paths.ts?paths-default=${Date.now()}`);

    expect(paths.IOS_USE_HOME).toBe(path.resolve(os.homedir(), '.ios-use'));
    expect(paths.CONFIG_FILE).toBe(path.join(paths.IOS_USE_HOME, 'config.json'));
    expect(paths.SESSION_FILE).toBe(path.join(paths.IOS_USE_HOME, 'state', 'session.json'));
  });

  test('respects IOS_USE_HOME override', async () => {
    process.env.IOS_USE_HOME = '/tmp/ios-use-custom-home';
    const paths = await import(`../src/utils/paths.ts?paths-override=${Date.now()}`);

    expect(paths.IOS_USE_HOME).toBe('/tmp/ios-use-custom-home');
    expect(paths.CONFIG_FILE).toBe('/tmp/ios-use-custom-home/config.json');
    expect(paths.SESSION_FILE).toBe('/tmp/ios-use-custom-home/state/session.json');
    expect(paths.ARTIFACT_DIR).toBe('/tmp/ios-use-custom-home/artifacts');
  });
});
