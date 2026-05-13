import { describe, expect, test } from 'bun:test';
import {
  DRIVER_COMMANDS,
  omitUndefined,
} from '../src/driver-protocol/index.js';
import { toForyTarget } from '../src/driver-protocol/fory.js';

describe('driver protocol', () => {
  test('exports stable command names', () => {
    expect(DRIVER_COMMANDS.ACTIVATE_APP).toBe('activateApp');
    expect(DRIVER_COMMANDS.HOME).toBe('home');
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

  test('toForyTarget validates coordinate arrays', () => {
    expect(toForyTarget([10, 20])).toEqual({ label: '', point: { x: 10, y: 20 } });
    expect(() => toForyTarget(['10', '20'])).toThrow('Invalid coordinate point');
    expect(() => toForyTarget([Number.NaN, 20])).toThrow('Invalid coordinate point');
    expect(() => toForyTarget([Number.POSITIVE_INFINITY, 20])).toThrow('Invalid coordinate point');
  });
});
