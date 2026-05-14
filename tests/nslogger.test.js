import { describe, test, expect, beforeAll, afterAll } from 'bun:test';
import net from 'net';
import tls from 'tls';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { execFileSync } from 'child_process';
import {
  parseMessage,
  formatLogEntry,
  formatBonjourStatusMessages,
  NSLoggerServer,
  PART_KEY_MESSAGE_TYPE,
  PART_KEY_TIMESTAMP_S,
  PART_KEY_TIMESTAMP_MS,
  PART_KEY_THREAD_ID,
  PART_KEY_TAG,
  PART_KEY_LEVEL,
  PART_KEY_MESSAGE,
  PART_KEY_MESSAGE_SEQ,
  PART_KEY_FILENAME,
  PART_KEY_LINENUMBER,
  PART_KEY_FUNCTIONNAME,
  PART_KEY_CLIENT_NAME,
  PART_KEY_CLIENT_VERSION,
  PART_KEY_OS_NAME,
  PART_KEY_OS_VERSION,
  PART_KEY_CLIENT_MODEL,
  PART_TYPE_STRING,
  PART_TYPE_INT16,
  PART_TYPE_INT32,
  PART_TYPE_INT64,
  LOGMSG_TYPE_LOG,
  LOGMSG_TYPE_CLIENTINFO,
  LOGMSG_TYPE_MARK,
  LOGMSG_TYPE_BLOCKSTART,
  LOGMSG_TYPE_BLOCKEND,
} from '../src/nslogger.js';

let tlsDir;
let tlsKeyPath;
let tlsCertPath;

function ensureTestTLSCredentials() {
  if (tlsKeyPath && tlsCertPath) return;
  tlsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ios-use-nslogger-test-'));
  tlsKeyPath = path.join(tlsDir, 'nslogger.key');
  tlsCertPath = path.join(tlsDir, 'nslogger.crt');
  execFileSync('openssl', [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-keyout',
    tlsKeyPath,
    '-out',
    tlsCertPath,
    '-nodes',
    '-subj',
    '/CN=ios-use NSLogger Test',
    '-days',
    '1',
  ], { stdio: 'ignore' });
}

function tlsServerOptions(opts = {}) {
  ensureTestTLSCredentials();
  return {
    keyPath: tlsKeyPath,
    certPath: tlsCertPath,
    ...opts,
  };
}

function buildMessage(parts) {
  const partBuffers = [];
  for (const [key, type, value] of parts) {
    const header = Buffer.alloc(2);
    header.writeUInt8(key, 0);
    header.writeUInt8(type, 1);
    let data;
    switch (type) {
      case PART_TYPE_STRING: {
        const strBuf = Buffer.from(value, 'utf-8');
        const sizeBuf = Buffer.alloc(4);
        sizeBuf.writeUInt32BE(strBuf.length, 0);
        data = Buffer.concat([sizeBuf, strBuf]);
        break;
      }
      case PART_TYPE_INT16: {
        data = Buffer.alloc(2);
        data.writeInt16BE(value, 0);
        break;
      }
      case PART_TYPE_INT32: {
        data = Buffer.alloc(4);
        data.writeInt32BE(value, 0);
        break;
      }
      case PART_TYPE_INT64: {
        data = Buffer.alloc(8);
        data.writeBigInt64BE(BigInt(value), 0);
        break;
      }
      default:
        data = Buffer.alloc(0);
    }
    partBuffers.push(Buffer.concat([header, data]));
  }

  const body = Buffer.concat(partBuffers);
  const totalSize = 2 + body.length;
  const header = Buffer.alloc(6);
  header.writeUInt32BE(totalSize, 0);
  header.writeUInt16BE(parts.length, 4);
  return Buffer.concat([header, body]);
}

describe('parseMessage', () => {
  test('parses a simple log message', () => {
    const msg = buildMessage([
      [PART_KEY_MESSAGE_TYPE, PART_TYPE_INT16, LOGMSG_TYPE_LOG],
      [PART_KEY_TIMESTAMP_S, PART_TYPE_INT32, 1700000000],
      [PART_KEY_THREAD_ID, PART_TYPE_INT64, 12345],
      [PART_KEY_TAG, PART_TYPE_STRING, 'network'],
      [PART_KEY_LEVEL, PART_TYPE_INT16, 0],
      [PART_KEY_MESSAGE, PART_TYPE_STRING, 'Hello NSLogger!'],
    ]);

    const result = parseMessage(msg);
    expect(result).not.toBeNull();
    expect(result.parts[PART_KEY_MESSAGE_TYPE]).toBe(LOGMSG_TYPE_LOG);
    expect(result.parts[PART_KEY_TIMESTAMP_S]).toBe(1700000000);
    expect(result.parts[PART_KEY_THREAD_ID]).toBe(12345);
    expect(result.parts[PART_KEY_TAG]).toBe('network');
    expect(result.parts[PART_KEY_LEVEL]).toBe(0);
    expect(result.parts[PART_KEY_MESSAGE]).toBe('Hello NSLogger!');
    expect(result.consumed).toBe(msg.length);
  });

  test('parses a CLIENTINFO message', () => {
    const msg = buildMessage([
      [PART_KEY_MESSAGE_TYPE, PART_TYPE_INT16, LOGMSG_TYPE_CLIENTINFO],
      [PART_KEY_TIMESTAMP_S, PART_TYPE_INT32, 1700000000],
      [PART_KEY_THREAD_ID, PART_TYPE_INT64, 1],
      [PART_KEY_CLIENT_NAME, PART_TYPE_STRING, 'Retouch'],
      [PART_KEY_CLIENT_VERSION, PART_TYPE_STRING, '1.0.0'],
      [PART_KEY_OS_NAME, PART_TYPE_STRING, 'iOS'],
      [PART_KEY_OS_VERSION, PART_TYPE_STRING, '17.0'],
      [PART_KEY_CLIENT_MODEL, PART_TYPE_STRING, 'iPhone'],
    ]);

    const result = parseMessage(msg);
    expect(result).not.toBeNull();
    expect(result.parts[PART_KEY_MESSAGE_TYPE]).toBe(LOGMSG_TYPE_CLIENTINFO);
    expect(result.parts[PART_KEY_CLIENT_NAME]).toBe('Retouch');
    expect(result.parts[PART_KEY_OS_NAME]).toBe('iOS');
  });

  test('returns null for incomplete buffer', () => {
    const buf = Buffer.alloc(4);
    expect(parseMessage(buf)).toBeNull();
  });

  test('returns null for buffer with insufficient data', () => {
    const header = Buffer.alloc(6);
    header.writeUInt32BE(100, 0);
    header.writeUInt16BE(1, 4);
    expect(parseMessage(header)).toBeNull();
  });

  test('parses message with Chinese characters', () => {
    const msg = buildMessage([
      [PART_KEY_MESSAGE_TYPE, PART_TYPE_INT16, LOGMSG_TYPE_LOG],
      [PART_KEY_TIMESTAMP_S, PART_TYPE_INT32, 1700000000],
      [PART_KEY_THREAD_ID, PART_TYPE_INT64, 1],
      [PART_KEY_MESSAGE, PART_TYPE_STRING, '埋点上报: show_category'],
    ]);

    const result = parseMessage(msg);
    expect(result).not.toBeNull();
    expect(result.parts[PART_KEY_MESSAGE]).toBe('埋点上报: show_category');
  });

  test('handles multiple messages in a single buffer', () => {
    const msg1 = buildMessage([
      [PART_KEY_MESSAGE_TYPE, PART_TYPE_INT16, LOGMSG_TYPE_LOG],
      [PART_KEY_TIMESTAMP_S, PART_TYPE_INT32, 1700000000],
      [PART_KEY_THREAD_ID, PART_TYPE_INT64, 1],
      [PART_KEY_MESSAGE, PART_TYPE_STRING, 'first'],
    ]);
    const msg2 = buildMessage([
      [PART_KEY_MESSAGE_TYPE, PART_TYPE_INT16, LOGMSG_TYPE_LOG],
      [PART_KEY_TIMESTAMP_S, PART_TYPE_INT32, 1700000001],
      [PART_KEY_THREAD_ID, PART_TYPE_INT64, 1],
      [PART_KEY_MESSAGE, PART_TYPE_STRING, 'second'],
    ]);

    const combined = Buffer.concat([msg1, msg2]);
    const result1 = parseMessage(combined);
    expect(result1).not.toBeNull();
    expect(result1.parts[PART_KEY_MESSAGE]).toBe('first');

    const remaining = combined.subarray(result1.consumed);
    const result2 = parseMessage(remaining);
    expect(result2).not.toBeNull();
    expect(result2.parts[PART_KEY_MESSAGE]).toBe('second');
  });
});

describe('formatLogEntry', () => {
  test('formats a log message with tag and level', () => {
    const entry = formatLogEntry({
      [PART_KEY_MESSAGE_TYPE]: LOGMSG_TYPE_LOG,
      [PART_KEY_TIMESTAMP_S]: 1700000000,
      [PART_KEY_TAG]: 'network',
      [PART_KEY_LEVEL]: 1,
      [PART_KEY_MESSAGE]: 'Connection established',
    });
    expect(entry).toContain('network');
    expect(entry).toContain('L1');
    expect(entry).toContain('Connection established');
  });

  test('formats CLIENTINFO message', () => {
    const entry = formatLogEntry({
      [PART_KEY_MESSAGE_TYPE]: LOGMSG_TYPE_CLIENTINFO,
      [PART_KEY_TIMESTAMP_S]: 1700000000,
      [PART_KEY_CLIENT_NAME]: 'Retouch',
      [PART_KEY_CLIENT_VERSION]: '1.0.0',
      [PART_KEY_OS_NAME]: 'iOS',
      [PART_KEY_OS_VERSION]: '17.0',
      [PART_KEY_CLIENT_MODEL]: 'iPhone',
    });
    expect(entry).toContain('[CLIENT_INFO]');
    expect(entry).toContain('Retouch');
    expect(entry).toContain('iOS');
  });

  test('formats MARK message', () => {
    const entry = formatLogEntry({
      [PART_KEY_MESSAGE_TYPE]: LOGMSG_TYPE_MARK,
      [PART_KEY_TIMESTAMP_S]: 1700000000,
      [PART_KEY_MESSAGE]: 'test marker',
    });
    expect(entry).toContain('[MARK]');
    expect(entry).toContain('test marker');
  });

  test('formats BLOCKSTART message', () => {
    const entry = formatLogEntry({
      [PART_KEY_MESSAGE_TYPE]: LOGMSG_TYPE_BLOCKSTART,
      [PART_KEY_TIMESTAMP_S]: 1700000000,
      [PART_KEY_TAG]: 'lifecycle',
      [PART_KEY_MESSAGE]: 'App launch',
    });
    expect(entry).toContain('[BLOCK_START]');
    expect(entry).toContain('lifecycle');
  });

  test('formats BLOCKEND message', () => {
    const entry = formatLogEntry({
      [PART_KEY_MESSAGE_TYPE]: LOGMSG_TYPE_BLOCKEND,
      [PART_KEY_TIMESTAMP_S]: 1700000000,
    });
    expect(entry).toContain('[BLOCK_END]');
  });

  test('includes filename and line number', () => {
    const entry = formatLogEntry({
      [PART_KEY_MESSAGE_TYPE]: LOGMSG_TYPE_LOG,
      [PART_KEY_TIMESTAMP_S]: 1700000000,
      [PART_KEY_MESSAGE]: 'test',
      [PART_KEY_FILENAME]: 'ViewController.swift',
      [PART_KEY_LINENUMBER]: 42,
      [PART_KEY_FUNCTIONNAME]: 'viewDidLoad',
    });
    expect(entry).toContain('ViewController.swift:42');
    expect(entry).toContain('viewDidLoad()');
  });
});

describe('NSLoggerServer', () => {
  let server;

  beforeAll(async () => {
    server = new NSLoggerServer(tlsServerOptions({ port: 0, publishBonjour: false }));
    await server.start();
  });

  afterAll(async () => {
    await server.stop();
    if (tlsDir) fs.rmSync(tlsDir, { recursive: true, force: true });
  });

  test('starts on a random port', () => {
    expect(server.getPort()).toBeGreaterThan(0);
  });

  test('grep returns empty array when no logs', () => {
    const result = server.grep('test');
    expect(result).toEqual([]);
  });

  test('receives and buffers log entries via TCP', async () => {
    const port = server.getPort();
    const msg = buildMessage([
      [PART_KEY_MESSAGE_TYPE, PART_TYPE_INT16, LOGMSG_TYPE_LOG],
      [PART_KEY_TIMESTAMP_S, PART_TYPE_INT32, 1700000000],
      [PART_KEY_THREAD_ID, PART_TYPE_INT64, 1],
      [PART_KEY_TAG, PART_TYPE_STRING, 'tracking'],
      [PART_KEY_LEVEL, PART_TYPE_INT16, 0],
      [PART_KEY_MESSAGE, PART_TYPE_STRING, 'show_category event fired'],
    ]);

    await new Promise((resolve, reject) => {
      const client = tls.connect({ port, host: '127.0.0.1', rejectUnauthorized: false });
      client.once('secureConnect', () => {
        client.write(msg, () => {
          setTimeout(() => {
            client.end();
            resolve();
          }, 200);
        });
      });
      client.on('error', reject);
    });

    await new Promise((r) => setTimeout(r, 300));

    const results = server.grep('show_category');
    expect(results.length).toBeGreaterThan(0);
    expect(results[0]).toContain('show_category event fired');
    expect(results[0]).toContain('tracking');
  });

  test('uses caller-provided TLS credentials when SSL is enabled', async () => {
    const secureServer = new NSLoggerServer(tlsServerOptions({ port: 0, useSSL: true, publishBonjour: false }));
    expect(secureServer.keyPath).toBe(tlsKeyPath);
    expect(secureServer.certPath).toBe(tlsCertPath);
    expect(fs.existsSync(tlsKeyPath)).toBe(true);
    expect(fs.existsSync(tlsCertPath)).toBe(true);

    await secureServer.start();
    const msg = buildMessage([
      [PART_KEY_MESSAGE_TYPE, PART_TYPE_INT16, LOGMSG_TYPE_LOG],
      [PART_KEY_TIMESTAMP_S, PART_TYPE_INT32, 1700000000],
      [PART_KEY_MESSAGE, PART_TYPE_STRING, 'secure log'],
    ]);

    await new Promise((resolve, reject) => {
      const client = tls.connect({ port: secureServer.getPort(), host: '127.0.0.1', rejectUnauthorized: false });
      client.once('secureConnect', () => {
        client.write(msg, () => {
          setTimeout(() => {
            client.end();
            resolve();
          }, 100);
        });
      });
      client.once('error', reject);
    });

    await new Promise((r) => setTimeout(r, 200));
    expect(secureServer.grep('secure log')).toHaveLength(1);
    await secureServer.stop();
  });

  test('grep with regex flags', async () => {
    server.clear();
    server.push('Test CASE insensitive');
    const results = server.grep('test case', 'i');
    expect(results.length).toBe(1);
  });

  test('clear empties the buffer', () => {
    server.push('some log');
    server.clear();
    expect(server.getLogCount()).toBe(0);
  });

  test('buffer respects maxBufferSize', () => {
    const smallServer = new NSLoggerServer({ port: 0, maxBufferSize: 3, useSSL: false });
    for (let i = 0; i < 5; i++) {
      smallServer.push(`log-${i}`);
    }
    expect(smallServer.getLogCount()).toBeLessThanOrEqual(3);
  });

  test('grep throws on invalid regex pattern', () => {
    expect(() => server.grep('[invalid')).toThrow('Invalid regex pattern');
  });

  test('negative maxBufferSize falls back to default', () => {
    const fallbackServer = new NSLoggerServer({ port: 0, maxBufferSize: -1, useSSL: false });
    expect(fallbackServer.getLogCount()).toBe(0);
    fallbackServer.push('test');
    expect(fallbackServer.getLogCount()).toBe(1);
  });

  test('bonjour status reflects disabled publishing', () => {
    const disabledServer = new NSLoggerServer({ port: 1234, publishBonjour: false, useSSL: false });
    expect(disabledServer.getBonjourStatus()).toMatchObject({
      publishEnabled: false,
      active: false,
      port: 1234,
      serviceType: '_nslogger._tcp',
      domain: 'local',
    });
  });

  test('bonjour status reflects TLS service type when SSL is enabled', () => {
    const secureServer = new NSLoggerServer(tlsServerOptions({ port: 1234, publishBonjour: false, useSSL: true }));
    expect(secureServer.getBonjourStatus()).toMatchObject({
      publishEnabled: false,
      active: false,
      port: 1234,
      serviceType: '_nslogger-ssl._tcp',
      domain: 'local',
    });
  });
});

describe('formatBonjourStatusMessages', () => {
  test('formats active bonjour publish message', () => {
    const messages = formatBonjourStatusMessages({
      publishEnabled: true,
      active: true,
      serviceName: 'tester',
      serviceType: '_nslogger._tcp',
      domain: 'local',
      port: 50000,
      error: null,
    });
    expect(messages).toEqual([
      {
        level: 'info',
        message: 'Bonjour publish process started: tester._nslogger._tcp.local:50000',
      },
    ]);
  });

  test('formats unavailable bonjour publish message with tcp hint', () => {
    const messages = formatBonjourStatusMessages({
      publishEnabled: true,
      active: false,
      serviceName: 'tester',
      serviceType: '_nslogger._tcp',
      domain: 'local',
      port: 50000,
      error: 'dns-sd unavailable',
    });
    expect(messages[0].level).toBe('warn');
    expect(messages[0].message).toContain('Bonjour publish unavailable');
    expect(messages[0].message).toContain('dns-sd unavailable');
    expect(messages[1].level).toBe('info');
    expect(messages[1].message).toContain('ephemeral port 50000');
    expect(messages[1].message).toContain('LoggerSetViewerHost()');
  });
});
