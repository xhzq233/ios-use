import { describe, test, expect, beforeAll, afterAll } from 'bun:test';
import net from 'node:net';
import { Connection } from '../src/driver-client/connection.js';

function createMockServer(port) {
  return new Promise((resolve, reject) => {
    const server = net.createServer((socket) => {
      socket.on('data', (data) => {
        const reqLen = data.readUInt32BE(0);
        const reqBody = data.subarray(4, 4 + reqLen);
        const req = JSON.parse(reqBody.toString('utf-8'));
        // Return a proper ResponseFrame
        const resp = JSON.stringify({ ok: true, error: null, data: req.c });
        const respBuf = Buffer.from(resp, 'utf-8');
        const header = Buffer.alloc(4);
        header.writeUInt32BE(respBuf.length, 0);
        socket.write(Buffer.concat([header, respBuf]));
      });
    });
    server.listen(port, () => resolve(server));
    server.on('error', reject);
  });
}

describe('Connection', () => {
  let server;
  const port = 18100;

  beforeAll(async () => {
    server = await createMockServer(port);
  });

  afterAll(() => {
    server.close();
  });

  test('connect and disconnect lifecycle', async () => {
    const conn = new Connection({ host: '127.0.0.1', port, directTcp: true });
    await conn.connect();
    expect(conn.isConnected).toBe(true);
    conn.disconnect();
    expect(conn.isConnected).toBe(false);
  });

  test('send serializes requests through queue', async () => {
    const conn = new Connection({ host: '127.0.0.1', port, directTcp: true });
    await conn.connect();
    const resp = await conn.send('ping', { extra: 1 });
    expect(resp.ok).toBe(true);
    expect(resp.data).toBe('ping');
    conn.disconnect();
  });

  test('send rejects when not connected', async () => {
    const conn = new Connection({ host: '127.0.0.1', port: port + 1, directTcp: true });
    try {
      await conn.send('ping');
      expect(false).toBe(true); // should not reach here
    } catch (err) {
      expect(String(err)).toContain('not connected');
    }
  });

  test('connect rejects on unreachable port', async () => {
    const conn = new Connection({ host: '127.0.0.1', port: 1, directTcp: true });
    try {
      await conn.connect();
      expect(false).toBe(true); // should not reach here
    } catch (err) {
      const msg = String(err);
      expect(msg.includes('timeout') || msg.includes('ECONNREFUSED')).toBe(true);
    }
  });

  test('concurrent sends are serialized and return correct responses', async () => {
    const conn = new Connection({ host: '127.0.0.1', port, directTcp: true });
    await conn.connect();
    const [r1, r2, r3] = await Promise.all([
      conn.send('a'),
      conn.send('b'),
      conn.send('c'),
    ]);
    expect(r1.data).toBe('a');
    expect(r2.data).toBe('b');
    expect(r3.data).toBe('c');
    conn.disconnect();
  });

  test('disconnect then reconnect works', async () => {
    const conn = new Connection({ host: '127.0.0.1', port, directTcp: true });
    await conn.connect();
    const resp1 = await conn.send('ping');
    expect(resp1.ok).toBe(true);
    conn.disconnect();

    await conn.connect();
    const resp2 = await conn.send('pong');
    expect(resp2.ok).toBe(true);
    conn.disconnect();
  });
});
