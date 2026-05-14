import { describe, expect, test } from 'bun:test';
import { Connection } from '../src/driver-protocol/connection.ts';

describe('Connection buffering', () => {
  test('readExact avoids Buffer.concat for fragmented pending read', async () => {
    const conn = new Connection({});
    const origConcat = Buffer.concat;
    let concatCalls = 0;
    (Buffer as unknown as { concat: typeof Buffer.concat }).concat = ((...args: Parameters<typeof Buffer.concat>) => {
      concatCalls++;
      return origConcat(...args);
    }) as typeof Buffer.concat;

    try {
      const p = (conn as any).readExact(6) as Promise<Buffer>;
      (conn as any).onData(Buffer.from('ab'));
      (conn as any).onData(Buffer.from('cd'));
      (conn as any).onData(Buffer.from('ef'));
      const out = await p;
      expect(out.toString()).toBe('abcdef');
      expect(concatCalls).toBe(0);
    } finally {
      (Buffer as unknown as { concat: typeof Buffer.concat }).concat = origConcat;
      conn.disconnect();
    }
  });

  test('readExact preserves extra bytes from a satisfying chunk', async () => {
    const conn = new Connection({});
    try {
      const first = (conn as any).readExact(4) as Promise<Buffer>;
      (conn as any).onData(Buffer.from('abcdef'));
      expect((await first).toString()).toBe('abcd');
      expect(((await (conn as any).readExact(2)) as Buffer).toString()).toBe('ef');
    } finally {
      conn.disconnect();
    }
  });

  test('readExact consumes existing partial buffer before pending chunks', async () => {
    const conn = new Connection({});
    try {
      (conn as any).onData(Buffer.from('ab'));
      const first = (conn as any).readExact(4) as Promise<Buffer>;
      (conn as any).onData(Buffer.from('cdxy'));
      expect((await first).toString()).toBe('abcd');
      expect(((await (conn as any).readExact(2)) as Buffer).toString()).toBe('xy');
    } finally {
      conn.disconnect();
    }
  });

  test('disconnect rejects a pending read and clears partial state', async () => {
    const conn = new Connection({});
    const pending = (conn as any).readExact(4) as Promise<Buffer>;
    (conn as any).onData(Buffer.from('ab'));

    conn.disconnect();

    await expect(pending).rejects.toThrow('connection disconnected');
    expect((conn as any).buffer.length).toBe(0);
    expect((conn as any).readBuffer).toBeNull();
    expect((conn as any).readOffset).toBe(0);
  });
});
