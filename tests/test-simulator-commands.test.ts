import { describe, expect, test } from 'bun:test';
import {
  isCaseSelected,
  parseCaseFilter,
  parseRunnerArgs,
  validateCaseFilter,
} from '../scripts/test_simulator_commands.ts';

describe('test_simulator_commands runner args', () => {
  test('selects exact case ids only', () => {
    const filter = parseCaseFilter('IN-5, dom-1');

    expect(isCaseSelected('IN-5', filter)).toBe(true);
    expect(isCaseSelected('DOM-1', filter)).toBe(true);
    expect(isCaseSelected('IN-6', filter)).toBe(false);
    expect(isCaseSelected('IN-5B', filter)).toBe(false);
    expect(isCaseSelected('IN', filter)).toBe(false);
  });

  test('no filter selects every case', () => {
    expect(isCaseSelected('IN-5')).toBe(true);
    expect(isCaseSelected('DOM-1')).toBe(true);
  });

  test('rejects empty case filter', () => {
    expect(() => parseCaseFilter(' , ')).toThrow('--case requires at least one case id');
  });

  test('parses supported runner args', () => {
    const parsed = parseRunnerArgs(['--skip-build', '--case', 'IN-5,DOM-1']);

    expect(parsed.skipBuild).toBe(true);
    expect(parsed.caseFilterIds).toEqual(new Set(['IN-5', 'DOM-1']));
  });

  test('rejects unknown runner args and missing case value', () => {
    expect(() => parseRunnerArgs(['--unknown'])).toThrow('unknown option --unknown');
    expect(() => parseRunnerArgs(['--case'])).toThrow('--case requires a value');
  });

  test('validates selected case ids against the registry', () => {
    const filter = parseCaseFilter('IN-5,DOM-1');

    expect(() => validateCaseFilter(['IN-5', 'DOM-1'], filter)).not.toThrow();
    expect(() => validateCaseFilter(['IN-5'], filter)).toThrow('unknown --case id: DOM-1');
  });
});
