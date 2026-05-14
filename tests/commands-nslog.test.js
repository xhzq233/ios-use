import { describe, test, expect, beforeEach, afterEach, spyOn } from 'bun:test';
import tls from 'tls';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { execFileSync } from 'child_process';
import { nslogStreamAction } from '../src/commands/nslog.js';
import {
  NSLoggerServer,
  PART_KEY_MESSAGE_TYPE,
  PART_KEY_TIMESTAMP_S,
  PART_KEY_MESSAGE,
  PART_TYPE_INT16,
  PART_TYPE_INT32,
  PART_TYPE_STRING,
  LOGMSG_TYPE_LOG,
} from '../src/nslogger.js';
import { logger } from '../src/utils/logger.js';

function createTestTLSCredentials() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ios-use-nslog-command-test-'));
  const keyPath = path.join(dir, 'nslogger.key');
  const certPath = path.join(dir, 'nslogger.crt');
  execFileSync('openssl', [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-keyout',
    keyPath,
    '-out',
    certPath,
    '-nodes',
    '-subj',
    '/CN=ios-use NSLogger Command Test',
    '-days',
    '1',
  ], { stdio: 'ignore' });
  return { dir, keyPath, certPath };
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

describe('nslog stream', () => {
  let logSpy;
  let infoSpy;
  let warnSpy;

  beforeEach(() => {
    logSpy = spyOn(console, 'log').mockImplementation(() => {});
    infoSpy = spyOn(logger, 'info').mockImplementation(() => {});
    warnSpy = spyOn(logger, 'warn').mockImplementation(() => {});
  });

  afterEach(() => {
    logSpy.mockRestore();
    infoSpy.mockRestore();
    warnSpy.mockRestore();
  });

  test('streams matching NSLogger entries over TLS by default and stops on SIGINT', async () => {
    const tlsCreds = createTestTLSCredentials();
    try {
      const action = nslogStreamAction({ grep: 'show_category', flags: '', setExitCode: false, skipLock: true, keyPath: tlsCreds.keyPath, certPath: tlsCreds.certPath });
      await new Promise((resolve) => setTimeout(resolve, 100));

      const output = infoSpy.mock.calls.flat().join(' ');
      const portMatch = output.match(/port (\d+)/);
      expect(portMatch).not.toBeNull();
      expect(output).toContain('._nslogger-ssl._tcp.local:');
      const port = Number(portMatch[1]);

      const client = tls.connect({ port, host: '127.0.0.1', rejectUnauthorized: false });
      await new Promise((resolve, reject) => {
        client.once('secureConnect', resolve);
        client.once('error', reject);
      });

      client.write(buildMessage([
        [PART_KEY_MESSAGE_TYPE, PART_TYPE_INT16, LOGMSG_TYPE_LOG],
        [PART_KEY_TIMESTAMP_S, PART_TYPE_INT32, 1700000000],
        [PART_KEY_MESSAGE, PART_TYPE_STRING, 'show_category fired'],
      ]));

      await new Promise((resolve) => setTimeout(resolve, 100));
      expect(logSpy).toHaveBeenCalled();

      process.emit('SIGINT');
      client.end();
      await action;
    } finally {
      fs.rmSync(tlsCreds.dir, { recursive: true, force: true });
    }
  });

  test('warns when bonjour publishing is unavailable', async () => {
    const tlsCreds = createTestTLSCredentials();
    const original = NSLoggerServer.prototype.publishBonjourService;
    NSLoggerServer.prototype.publishBonjourService = function mockPublishFailure() {
      this.bonjourStatus.attempted = true;
      this.bonjourStatus.active = false;
      this.bonjourStatus.error = 'dns-sd unavailable';
    };

    try {
      const action = nslogStreamAction({ setExitCode: false, skipLock: true, keyPath: tlsCreds.keyPath, certPath: tlsCreds.certPath });
      await new Promise((resolve) => setTimeout(resolve, 100));

      const warnings = warnSpy.mock.calls.flat().join(' ');
      const infos = infoSpy.mock.calls.flat().join(' ');
      expect(warnings).toContain('Bonjour publish unavailable; iOS NSLogger clients using default settings may not auto-discover this viewer');
      expect(warnings).toContain('dns-sd unavailable');
      expect(infos).toContain('TCP server is healthy on ephemeral port');

      process.emit('SIGINT');
      await action;
    } finally {
      NSLoggerServer.prototype.publishBonjourService = original;
      fs.rmSync(tlsCreds.dir, { recursive: true, force: true });
    }
  });
});
