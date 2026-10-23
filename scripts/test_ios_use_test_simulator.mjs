import assert from 'node:assert/strict';
import { test } from 'node:test';
import { chooseRuntime, chooseDeviceType, findReusableDevice } from './ios_use_test_simulator.js';

const phone = { name: 'iPhone 16', identifier: 'type.phone', productFamily: 'iPhone' };
const duo = { name: 'iPhone Duo', identifier: 'type.duo', productFamily: 'iPhone' };
const older = { name: 'iOS 18.5', version: '18.5', identifier: 'runtime.old', isAvailable: true, supportedDeviceTypes: [phone] };
const latest = { name: 'iOS 27.1', version: '27.1', identifier: 'runtime.new', isAvailable: true, supportedDeviceTypes: [duo] };

test('automatic selection uses a device supported by the newest runtime', () => {
  const runtime = chooseRuntime([older, latest]);
  assert.equal(runtime, latest);
  assert.equal(chooseDeviceType(runtime), duo);
});
test('explicit device chooses its newest compatible runtime', () => {
  assert.equal(chooseRuntime([latest, older], '', phone.name), older);
  assert.equal(chooseDeviceType(older, phone.identifier), phone);
});
test('an incompatible explicit pair fails instead of silently changing device', () => {
  assert.throws(() => chooseRuntime([latest, older], latest.version, phone.name));
  assert.throws(() => chooseDeviceType(latest, phone.name));
});
test('unavailable and non-iOS runtimes are excluded', () => {
  const unavailable = { ...latest, isAvailable: false };
  const tv = { ...latest, name: 'tvOS 99', version: '99' };
  assert.equal(chooseRuntime([unavailable, older, tv]), older);
  assert.throws(() => chooseRuntime([unavailable]));
});
test('reuse respects runtime, device type and requested name despite cached UDID', () => {
  const stale = { udid: 'cached-test-device', name: 'IOSUseTest', runtimeIdentifier: older.identifier, deviceTypeIdentifier: phone.identifier };
  const current = { ...stale, udid: 'compatible-test-device', runtimeIdentifier: latest.identifier, deviceTypeIdentifier: duo.identifier };
  assert.equal(findReusableDevice([stale, current], { udid: stale.udid }, latest, duo, 'IOSUseTest'), current);
  assert.equal(findReusableDevice([stale], { udid: stale.udid }, latest, duo, 'IOSUseTest'), null);
  assert.equal(findReusableDevice([current], { udid: current.udid }, latest, duo, 'AnotherTest'), null);
});
test('version ordering is numeric and explicit runtime is honored', () => {
  const earlier = { ...latest, name: 'iOS 27.2', version: '27.2', identifier: 'runtime.27.2' };
  const later = { ...latest, name: 'iOS 27.10', version: '27.10', identifier: 'runtime.27.10' };
  assert.equal(chooseRuntime([earlier, later]), later);
  assert.equal(chooseRuntime([earlier, later], earlier.identifier), earlier);
});
