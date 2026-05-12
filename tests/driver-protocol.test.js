import { describe, expect, test } from 'bun:test';
import {
  DRIVER_COMMANDS,
  omitUndefined,
} from '../src/driver-protocol/index.js';

describe('driver protocol', () => {
  test('exports stable command names', () => {
    expect(DRIVER_COMMANDS.CREATE_SESSION).toBe('createSession');
    expect(DRIVER_COMMANDS.LONG_PRESS).toBe('longPress');
    expect(DRIVER_COMMANDS.WAIT_FOR).toBe('waitFor');
    expect(DRIVER_COMMANDS.OPEN_URL).toBe('openURL');
  });

  test('omitUndefined removes undefined fields only', () => {
    expect(omitUndefined({
      label: '蓝牙',
      timeout: undefined,
      raw: false,
    })).toEqual({
      label: '蓝牙',
      raw: false,
    });
  });
});
