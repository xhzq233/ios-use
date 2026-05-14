import net from 'node:net';
import plist from 'plist';
import { USBMUX_REQUEST_TIMEOUT_MS } from '../constants.js';

const USBMUXD_SOCKET = '/var/run/usbmuxd';
const HEADER_SIZE = 16;

function swap16(val: number): number {
  return ((val & 0xff) << 8) | ((val >> 8) & 0xff);
}

export function encodeMessage(payload: Record<string, unknown>, tag: number): Buffer {
  const plistBuf = Buffer.from(plist.build(payload));
  const header = Buffer.allocUnsafe(HEADER_SIZE);
  header.writeUInt32LE(HEADER_SIZE + plistBuf.length, 0);
  header.writeUInt32LE(1, 4);   // version
  header.writeUInt32LE(8, 8);   // type = plist
  header.writeUInt32LE(tag, 12);
  return Buffer.concat([header, plistBuf]);
}

export function readMessage(buf: Buffer): { tag: number; payload: any; rest: Buffer } | null {
  if (buf.length < HEADER_SIZE) return null;
  const msgLen = buf.readUInt32LE(0);
  if (buf.length < msgLen) return null;
  const tag = buf.readUInt32LE(12);
  const payload = plist.parse(buf.subarray(HEADER_SIZE, msgLen).toString('utf8')) as any;
  return { tag, payload, rest: buf.subarray(msgLen) };
}

/**
 * Connect to a device port through usbmuxd, eliminating the need for iproxy.
 * Returns a net.Socket tunneled directly to the device.
 */
export async function connectUsbmux(udid: string, port: number): Promise<net.Socket> {
  const socket = net.createConnection(USBMUXD_SOCKET);

  await new Promise<void>((resolve, reject) => {
    const onConnect = () => { socket.off('error', reject); resolve(); };
    socket.once('connect', onConnect);
    socket.once('error', reject);
  });

  let buf = Buffer.alloc(0);

  function sendAndReceive(payload: Record<string, unknown>, tag: number): Promise<any> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        socket.removeListener('data', onData);
        reject(new Error(`usbmux request timed out (tag=${tag})`));
      }, USBMUX_REQUEST_TIMEOUT_MS);

      function onData(raw: Buffer) {
        buf = buf.length === 0 ? raw : Buffer.concat([buf, raw]);
        try {
          const msg = readMessage(buf);
          if (msg) {
            buf = msg.rest;
            clearTimeout(timer);
            socket.removeListener('data', onData);
            resolve(msg.payload);
          }
        } catch (e) {
          clearTimeout(timer);
          socket.removeListener('data', onData);
          reject(e instanceof Error ? e : new Error(String(e)));
        }
      }

      socket.on('data', onData);
      socket.write(encodeMessage(payload, tag));
    });
  }

  try {
    // Step 1: ListDevices to find DeviceID
    const listResp = await sendAndReceive({
      MessageType: 'ListDevices',
      ProgName: 'IOSUseDriver',
      ClientVersionString: '1.0',
    }, 0);

    const devices = listResp.DeviceList as Array<{ Properties: { SerialNumber: string; DeviceID: number } }>;
    const normalizedUdid = udid.replace(/-/g, '').toLowerCase();
    const device = devices.find(d => d.Properties.SerialNumber.replace(/-/g, '').toLowerCase() === normalizedUdid);
    if (!device) {
      socket.destroy();
      throw new Error(
        `Device ${udid} not found via usbmux (0 USB devices found). `
        + 'The device may be connected via WiFi — USB connection is required. '
        + 'Please connect the device via USB cable.',
      );
    }

    // Step 2: Connect to port on device
    const connectResp = await sendAndReceive({
      MessageType: 'Connect',
      ProgName: 'IOSUseDriver',
      ClientVersionString: '1.0',
      DeviceID: device.Properties.DeviceID,
      PortNumber: swap16(port),
    }, 1);

    if (connectResp.Number !== 0) {
      socket.destroy();
      throw new Error(`usbmux Connect failed with code ${connectResp.Number}. Is the driver running on port ${port}?`);
    }

    // Remove all data listeners — the socket is now a raw tunnel
    socket.removeAllListeners('data');

    return socket;
  } catch (err) {
    socket.removeAllListeners();
    socket.destroy();
    throw err;
  }
}

export function listUsbDeviceUdids(): Promise<string[]> {
  return new Promise((resolve) => {
    const socket = net.createConnection(USBMUXD_SOCKET);
    const onError = () => { socket.destroy(); resolve([]); };
    socket.once('error', onError);
    socket.once('connect', () => {
      let buf = Buffer.alloc(0);
      const timer = setTimeout(() => { socket.destroy(); resolve([]); }, 3000);
      socket.on('data', (raw: Buffer) => {
        buf = buf.length === 0 ? raw : Buffer.concat([buf, raw]);
        try {
          const msg = readMessage(buf);
          if (!msg) return;
          clearTimeout(timer);
          socket.destroy();
          const devices = (msg.payload.DeviceList ?? []) as Array<{ Properties?: { SerialNumber?: string; ConnectionType?: string } }>;
          resolve(devices.filter(d => d.Properties?.ConnectionType === 'USB' && d.Properties?.SerialNumber).map(d => d.Properties!.SerialNumber!));
        } catch {
          clearTimeout(timer);
          socket.destroy();
          resolve([]);
        }
      });
      socket.write(encodeMessage({ MessageType: 'ListDevices', ProgName: 'ios-use', ClientVersionString: '1.0' }, 0));
    });
  });
}
