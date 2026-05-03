import { execFileSync } from 'child_process';
import { listUsbDeviceUdids } from './driver-client/usbmux.js';

export interface Device {
  name: string;
  version: string;
  udid: string;
  type: 'real' | 'simulator';
}

const DEVICE_LINE_RE = /^\s*(.+?)\s+(?:\((\d+\.\d+(?:\.\d+)?)\)\s+)?\(([0-9A-Fa-f-]+)\)\s*$/i;
const SIMCTL_BOOTED_RE = /^\s*(.+?)\s+\(([0-9A-Fa-f-]+)\)\s+\(Booted\)/i;

/**
 * Parse output of `xcrun xctrace list devices` to find connected real devices and simulators.
 * Returns [{name, version, udid, type}]
 */
export function parseDeviceOutput(output: string): Device[] {
  const devices: Device[] = [];
  let section: 'none' | 'real' | 'simulator' = 'none';

  for (const line of output.split('\n')) {
    if (line.startsWith('== Devices ==')) {
      section = 'real';
      continue;
    }
    if (line.startsWith('== Simulators ==')) {
      section = 'simulator';
      continue;
    }
    if (line.startsWith('== ')) {
      section = 'none';
      continue;
    }
    if (!line.trim() || section === 'none') continue;

    // Real device: "iPhone 15 (17.0) (00008101-001234567890ABCD)" or "MyiPhone (00008101-001234567890ABCD)"
    // Simulator:  "iPhone 16 (26.0.1) (8D3C62FA-EFD2-4990-A619-12B97BA5BBC5)"
    const match = line.match(DEVICE_LINE_RE);
    if (match) {
      devices.push({
        name: match[1].trim(),
        version: match[2] || '',
        udid: match[3],
        type: section === 'simulator' ? 'simulator' : 'real',
      });
    }
  }

  return devices;
}

const SIMULATOR_UDID_RE = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i;

export function detectDevices(): Device[] {
  const output = execFileSync('xcrun', ['xctrace', 'list', 'devices'], { encoding: 'utf-8' });
  return parseDeviceOutput(output);
}

function normalizeUdid(udid: string): string {
  return udid.replace(/-/g, '').toLowerCase();
}

export async function detectRealDevices(): Promise<Device[]> {
  const all = detectDevices().filter(d => d.type === 'real');
  const usbUdids = await listUsbDeviceUdids();
  if (usbUdids.length === 0) return all;
  const usbSet = new Set(usbUdids.map(normalizeUdid));
  return all.filter(d => usbSet.has(normalizeUdid(d.udid)));
}

export function detectBootedSimulators(): Device[] {
  const output = execFileSync('xcrun', ['simctl', 'list', 'devices', 'booted'], { encoding: 'utf-8' });
  const devices: Device[] = [];
  let currentOsVersion = '';

  for (const line of output.split('\n')) {
    if (line.startsWith('-- ')) {
      const osMatch = line.match(/^--\s+(.+?)\s+--/);
      if (osMatch) currentOsVersion = osMatch[1].trim().replace(/^iOS\s+/i, '');
      continue;
    }
    const match = line.match(SIMCTL_BOOTED_RE);
    if (match) {
      devices.push({
        name: match[1].trim(),
        version: currentOsVersion,
        udid: match[2],
        type: 'simulator',
      });
    }
  }

  return devices;
}

export function getDefaultDevice(
  devices: Device[] = detectDevices(),
  options: { usbUdids?: string[] } = {},
): Device {
  const usbSet = new Set((options.usbUdids ?? []).map(normalizeUdid));
  if (usbSet.size > 0) {
    const usbReal = devices.find((device) => device.type === 'real' && usbSet.has(normalizeUdid(device.udid)));
    if (usbReal) return usbReal;
  }

  throw new Error('No USB-connected iOS device found. Connect a device over USB, or pass --udid explicitly for a simulator.');
}

export async function resolveDefaultDevice(): Promise<Device> {
  const devices = detectDevices();
  const usbUdids = await listUsbDeviceUdids();
  return getDefaultDevice(devices, { usbUdids });
}

export function resolveDevice(udid: string | undefined, devices: Device[] = detectDevices()): Device {
  if (devices.length === 0) {
    throw new Error('No connected iOS devices or simulators found. Connect a device or boot a simulator and try again.');
  }

  if (!udid) {
    return getDefaultDevice(devices);
  }

  const device = devices.find((item) => item.udid === udid);
  if (device) {
    return device;
  }

  // Auto-boot simulator if the UDID is valid but not currently booted
  if (SIMULATOR_UDID_RE.test(udid)) {
    try {
      execFileSync('xcrun', ['simctl', 'boot', udid], { encoding: 'utf-8', stdio: 'pipe' });
    } catch {
      // May already be booting or booted; ignore and retry detection
    }
    // Retry detection up to 3s for the simulator to appear in xctrace
    for (let i = 0; i < 6; i++) {
      const redevices = detectDevices();
      const rede = redevices.find((item) => item.udid === udid);
      if (rede) return rede;
      try { execFileSync('sleep', ['0.5'], { stdio: 'ignore' }); } catch { /* ignore sleep failure */ }
    }
  }

  throw new Error(`Requested device not found: ${udid}. Run "ios-use device" to see available devices.`);
}

export function formatDeviceLabel(device: Device): string {
  const typeLabel = device.type === 'simulator' ? 'Simulator' : 'Device';
  return `${device.name || 'Unknown'} | iOS ${device.version || 'unknown'} | ${typeLabel} | UDID: ${device.udid}`;
}
