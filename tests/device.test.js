import { describe, test, expect } from 'bun:test';
import { formatDeviceLabel, getDefaultDevice, parseDeviceOutput, resolveDevice } from '../src/device.js';

const sampleOutput = `== Devices ==
iPhone 16 Pro (18.3.2) (00008101-AAAAAAAAAAAAAA01)
iPhone 16 (17.7) (00008101-BBBBBBBBBBBBBB02)
== Simulators ==
iPhone 16 (26.0.1) (8D3C62FA-EFD2-4990-A619-12B97BA5BBC5)
iPhone 17 Pro (26.0.1) (41A6FE60-DA29-4B2D-B7D6-736FA0D87D75)
== Devices Offline ==
`;

describe('device helpers', () => {
  test('parseDeviceOutput extracts real devices', () => {
    const devices = parseDeviceOutput(sampleOutput);
    const realDevices = devices.filter(d => d.type === 'real');
    expect(realDevices).toHaveLength(2);
    expect(realDevices[0]).toEqual({
      name: 'iPhone 16 Pro',
      version: '18.3.2',
      udid: '00008101-AAAAAAAAAAAAAA01',
      type: 'real',
    });
  });

  test('parseDeviceOutput extracts simulators', () => {
    const devices = parseDeviceOutput(sampleOutput);
    const simulators = devices.filter(d => d.type === 'simulator');
    expect(simulators).toHaveLength(2);
    expect(simulators[0]).toEqual({
      name: 'iPhone 16',
      version: '26.0.1',
      udid: '8D3C62FA-EFD2-4990-A619-12B97BA5BBC5',
      type: 'simulator',
    });
  });

  test('getDefaultDevice returns the first USB real device', () => {
    const devices = parseDeviceOutput(sampleOutput);
    expect(getDefaultDevice(devices, {
      usbUdids: ['00008101-AAAAAAAAAAAAAA01'],
    }).udid).toBe('00008101-AAAAAAAAAAAAAA01');
  });

  test('getDefaultDevice prefers the first USB real device over simulators', () => {
    const devices = [
      { name: 'iPhone 16', version: '26.0.1', udid: '8D3C62FA-EFD2-4990-A619-12B97BA5BBC5', type: 'simulator' },
      { name: 'WiFi Phone', version: '18.3.2', udid: '00008101-AAAAAAAAAAAAAA01', type: 'real' },
      { name: 'USB Phone', version: '18.4', udid: '00008101-BBBBBBBBBBBBBB02', type: 'real' },
    ];
    expect(getDefaultDevice(devices, {
      usbUdids: ['00008101-BBBBBBBBBBBBBB02'],
    }).udid).toBe('00008101-BBBBBBBBBBBBBB02');
  });

  test('getDefaultDevice throws when no USB real device matches', () => {
    const devices = [
      { name: 'Archived Phone', version: '18.3.2', udid: '00008101-AAAAAAAAAAAAAA01', type: 'real' },
      { name: 'iPhone 16', version: '26.0.1', udid: '8D3C62FA-EFD2-4990-A619-12B97BA5BBC5', type: 'simulator' },
    ];
    expect(() => getDefaultDevice(devices, {
      usbUdids: ['00008101-NOT-PRESENT'],
    })).toThrow('No USB-connected iOS device found');
  });

  test('resolveDevice finds requested udid', () => {
    const devices = parseDeviceOutput(sampleOutput);
    expect(resolveDevice('00008101-BBBBBBBBBBBBBB02', devices).name).toBe('iPhone 16');
  });

  test('resolveDevice finds simulator udid', () => {
    const devices = parseDeviceOutput(sampleOutput);
    expect(resolveDevice('8D3C62FA-EFD2-4990-A619-12B97BA5BBC5', devices).type).toBe('simulator');
  });

  test('resolveDevice throws for unknown udid', () => {
    const devices = parseDeviceOutput(sampleOutput);
    expect(() => resolveDevice('missing-udid', devices)).toThrow('Requested device not found');
    expect(() => resolveDevice('missing-udid', devices)).toThrow('ios-use devices');
  });

  test('formatDeviceLabel prints name version type and udid', () => {
    expect(formatDeviceLabel({ name: 'My iPhone', version: '18.3.2', udid: 'abc', type: 'real' })).toBe('My iPhone | iOS 18.3.2 | Device | UDID: abc');
    expect(formatDeviceLabel({ name: 'iPhone 16', version: '26.0.1', udid: 'def', type: 'simulator' })).toBe('iPhone 16 | iOS 26.0.1 | Simulator | UDID: def');
  });
});
