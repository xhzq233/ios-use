import { contactsCaseMetadata } from './sim/cases/contacts.mjs';
import { deviceConfigCaseMetadata } from './sim/cases/device-config.mjs';
import { hostBridgeCaseMetadata } from './sim/cases/host-bridge.mjs';
import {
  settingsAfterContactsCaseMetadata,
  settingsBeforeContactsCaseMetadata,
} from './sim/cases/settings.mjs';

export const simulatorCases = [
  ...deviceConfigCaseMetadata,
  ...settingsBeforeContactsCaseMetadata,
  ...contactsCaseMetadata,
  ...settingsAfterContactsCaseMetadata,
  ...hostBridgeCaseMetadata,
];

export const simulatorCaseIds = simulatorCases.map(testCase => testCase.id);

export const simulatorCaseMetadataById = new Map(
  simulatorCases.map(testCase => [testCase.id, testCase]),
);

export const swiftCliBridgeCaseIds = new Set(
  simulatorCases
    .filter(testCase => testCase.coverage === 'swift-cli-unit')
    .map(testCase => testCase.id),
);

export const driverUnitBridgeCaseIds = new Set(
  simulatorCases
    .filter(testCase => testCase.coverage === 'driver-unit')
    .map(testCase => testCase.id),
);

export const unsupportedCaseReasons = new Map(
  simulatorCases
    .filter(testCase => testCase.coverage === 'unsupported')
    .map(testCase => [testCase.id, `${testCase.setup}: ${testCase.assertion}`]),
);

const requiredFields = ['id', 'group', 'kind', 'setup', 'assertion', 'coverage'];

export function validateCaseMetadataSchema() {
  const seen = new Set();
  const errors = [];
  for (const testCase of simulatorCases) {
    for (const field of requiredFields) {
      if (typeof testCase[field] !== 'string' || testCase[field].length === 0) {
        errors.push(`${testCase.id || '<missing id>'}: missing ${field}`);
      }
    }
    if (seen.has(testCase.id)) errors.push(`${testCase.id}: duplicate id`);
    seen.add(testCase.id);
  }
  if (errors.length > 0) {
    throw new Error(`invalid simulator case metadata:\n${errors.join('\n')}`);
  }
}

export function bridgeCase(id) {
  const metadata = simulatorCaseMetadataById.get(id);
  if (metadata?.coverage === 'swift-cli-unit') {
    return { source: 'swift-cli-unit', reason: 'covered by Swift CLI unit tests; full Simulator runner does not execute Swift unit tests' };
  }
  if (metadata?.coverage === 'driver-unit') {
    return { source: 'driver-unit', reason: 'covered by Swift driver unit tests; full Simulator runner does not execute Swift unit tests' };
  }
  return null;
}

export function shouldRunPrerequisiteConfig({ caseFilterIds }) {
  if (!caseFilterIds) return true;
  const selected = [...caseFilterIds].map(id => simulatorCaseMetadataById.get(id)).filter(Boolean);
  if (selected.some(testCase => testCase.providesPrerequisite)) return false;
  return selected.some(testCase => {
    if (testCase.coverage !== 'simulator') return false;
    if (testCase.requiresPrerequisite === false) return false;
    if (testCase.providesPrerequisite) return false;
    return ![
      'none',
      'empty IOS_USE_HOME',
      'no active driver',
      'no driver lock',
      'no last capture',
      'stopped driver',
      'simulator target',
    ].includes(testCase.setup);
  });
}
