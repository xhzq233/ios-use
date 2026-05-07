import { describe, expect, test } from 'bun:test';
import {
  DRIVER_COMMANDS,
  createRequestFrame,
  isBinaryResponseCommand,
  omitUndefined,
} from '../src/driver-protocol/index.js';

describe('driver protocol', () => {
  test('exports stable command names', () => {
    expect(DRIVER_COMMANDS.CREATE_SESSION).toBe('createSession');
    expect(DRIVER_COMMANDS.LONG_PRESS).toBe('longPress');
    expect(DRIVER_COMMANDS.WAIT_FOR).toBe('waitFor');
    expect(DRIVER_COMMANDS.PROBE_FETCH).toBe('probeFetch');
  });

  test('createRequestFrame builds protocol frame shape', () => {
    expect(createRequestFrame(DRIVER_COMMANDS.TAP, { label: '设置' })).toEqual({
      c: 'tap',
      args: { label: '设置' },
    });
    expect(createRequestFrame(DRIVER_COMMANDS.DOM)).toEqual({
      c: 'dom',
      args: undefined,
    });
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

  test('binary response command is declared in protocol layer', () => {
    expect(isBinaryResponseCommand(DRIVER_COMMANDS.SCREENSHOT)).toBe(true);
    expect(isBinaryResponseCommand(DRIVER_COMMANDS.DOM)).toBe(false);
  });
});
