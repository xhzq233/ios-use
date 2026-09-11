#!/usr/bin/env node
// Real stdio protocol / JavaScript lifecycle smoke; no Device or model needed.
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';

const binary = resolve(process.argv[2] ?? './ios-use');
const taskHome = await mkdtemp(join(tmpdir(), 'ios-use-mcp-test-'));
const clients = [];
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=', 'base64');

function childPIDs(pid) {
  try { return execFileSync('/usr/bin/pgrep', ['-P', String(pid)], {encoding: 'utf8'}).trim().split(/\s+/).map(Number); }
  catch (error) { if (error.status === 1) return []; throw error; }
}

function isAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (error) { if (error.code === 'ESRCH') return false; throw error; }
}

async function until(predicate, message) {
  for (let n = 0; n < 100; n++) {
    if (await predicate()) return;
    await delay(30);
  }
  throw new Error(message);
}

function client() {
  const child = spawn(binary, ['mcp'], {env: {...process.env, IOS_USE_HOME: taskHome}, stdio: ['pipe', 'pipe', 'pipe']});
  const pending = new Map();
  let nextID = 1;
  let stderr = '';
  child.stderr.on('data', chunk => { stderr += chunk; });
  const exited = new Promise(resolve => child.once('exit', (code, signal) => resolve({code, signal})));
  child.once('exit', () => {
    for (const request of pending.values()) request.reject(new Error(`MCP exited: ${stderr}`));
    pending.clear();
  });
  createInterface({input: child.stdout}).on('line', line => {
    let message;
    try { message = JSON.parse(line); } // stdout must contain complete protocol messages.
    catch {
      for (const request of pending.values()) request.reject(new Error(`Invalid MCP stdout frame (${line.length} characters)`));
      pending.clear();
      return;
    }
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    if (message.error) request.reject(new Error(JSON.stringify(message.error)));
    else request.resolve(message.result);
  });
  const send = message => child.stdin.write(JSON.stringify({jsonrpc: '2.0', ...message}) + '\n');
  const request = (method, params) => {
    const id = nextID++;
    const result = new Promise((resolve, reject) => pending.set(id, {resolve, reject}));
    send({id, method, params});
    return {id, result};
  };
  const call = (name, args = {}) => request('tools/call', {name, arguments: args});
  const result = {
    child, exited, request, call,
    notify: (method, params) => send({method, params}),
    js: (code, timeout_ms = 3000) => call('js', {code, timeout_ms}).result,
    async initialize() {
      const initialized = await request('initialize', {protocolVersion: '2025-11-25', capabilities: {}, clientInfo: {name: 'ios-use-smoke', version: '1'}}).result;
      assert.ok(initialized.capabilities.tools);
      send({method: 'notifications/initialized'});
      const {tools} = await request('tools/list', {}).result;
      assert.ok(tools.some(tool => tool.name === 'js'));
      assert.ok(tools.some(tool => tool.name === 'js_reset'));
    },
  };
  clients.push(result);
  return result;
}

function ok(result) { assert.notEqual(result.isError, true, JSON.stringify(result)); return result; }
function value(result) { return JSON.parse(ok(result).content[0].text); }

try {
  const mcp = client();
  await mcp.initialize();
  ok(await mcp.js('let count = 40; let unicode = "你好🌍";'));
  assert.equal(value(await mcp.js('await new Promise(r => setTimeout(r, 1200)); count += 2; nodeRepl.write(JSON.stringify({count, length: Array.from(unicode).length}));')).count, 42);
  assert.equal(value(await mcp.js('nodeRepl.write(JSON.stringify(Array.from(unicode).length));')), 3);
  assert.equal((await mcp.js('throw new Error("smoke");')).isError, true);
  assert.equal(value(await mcp.js('nodeRepl.write(JSON.stringify(++count));')), 43);
  assert.equal((await mcp.js('let = ;')).isError, true);
  const emitted = ok(await mcp.js(`await nodeRepl.emitImage(new Uint8Array(${JSON.stringify([...png])}));`)).content[0];
  assert.equal(emitted.type, 'image');
  assert.equal(emitted.mimeType, 'image/png');
  assert.deepEqual(Buffer.from(emitted.data, 'base64'), png);
  ok(await mcp.call('js_reset').result);
  assert.equal(value(await mcp.js('nodeRepl.write(JSON.stringify(typeof count === "undefined"));')), true);

  // A CPU-bound script must preserve emitted output, terminate, and be replaceable.
  const timed = await mcp.js('nodeRepl.write(JSON.stringify(123)); while (true) {}', 200);
  assert.equal(timed.isError, true);
  assert.equal(JSON.parse(timed.content[0].text), 123);
  assert.equal(value(await mcp.js('nodeRepl.write(JSON.stringify(6 * 7));')), 42);

  // Cancellation and reset can interrupt an active tools/call without polling a shell.
  const cancelled = mcp.call('js', {code: 'while (true) {}', timeout_ms: 10000});
  cancelled.result.catch(() => {}); // The SDK may omit a response to cancelled requests.
  await delay(150);
  mcp.notify('notifications/cancelled', {requestId: cancelled.id, reason: 'smoke'});
  ok(await mcp.call('js_reset').result);
  const busy = mcp.call('js', {code: 'while (true) {}', timeout_ms: 10000});
  await delay(150);
  assert.equal((await mcp.js('nodeRepl.write(0);')).isError, true);
  ok(await mcp.call('js_reset').result);
  assert.equal((await busy.result).isError, true);
  assert.equal(value(await mcp.js('nodeRepl.write(JSON.stringify(1 + 1));')), 2);
  console.log('[mcp-test] discovery, persistent JS, errors, images, timeout, cancellation and reset passed');

  // Slow clients plus concurrent replies must not interleave large JSON frames.
  mcp.child.stdout.pause();
  const large = mcp.js(`let bigImage = new Uint8Array(1024 * 1024); bigImage.set(${JSON.stringify([...png])}); await nodeRepl.emitImage(bigImage);`);
  const replies = [large];
  await delay(200);
  replies.push(mcp.request('ping', {}).result);
  replies.push(mcp.request('tools/list', {}).result);
  await delay(100);
  mcp.child.stdout.resume();
  const [largeResult] = await Promise.all(replies);
  assert.equal(Buffer.from(ok(largeResult).content[0].data, 'base64').length, 1024 * 1024);
  console.log('[mcp-test] large image response remains framed under stdout backpressure');

  // EOF and SIGTERM must clean up the server-owned Node, including a busy loop.
  for (const termination of ['eof', 'SIGTERM']) {
    const stopping = client();
    await stopping.initialize();
    ok(await stopping.js('let ready = true;'));
    const pids = childPIDs(stopping.child.pid);
    assert.equal(pids.length, 1, 'expected one persistent Node child');
    const running = stopping.call('js', {code: 'while (true) {}', timeout_ms: 10000});
    running.result.catch(() => {});
    await delay(150);
    if (termination === 'eof') stopping.child.stdin.end();
    else stopping.child.kill(termination);
    await until(() => stopping.child.exitCode !== null || stopping.child.signalCode !== null, `${termination}: MCP did not exit`);
    await until(() => pids.every(pid => !isAlive(pid)), `${termination}: Node child leaked`);
  }
  console.log('[mcp-test] client EOF and SIGTERM clean up busy JavaScript children');
} finally {
  for (const {child, exited} of clients) {
    if (child.exitCode === null && child.signalCode === null) {
      for (const pid of childPIDs(child.pid)) { try { process.kill(pid, 'SIGKILL'); } catch {} }
      child.kill('SIGKILL');
    }
    await exited;
  }
  await rm(taskHome, {recursive: true, force: true});
}
