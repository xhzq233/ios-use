import { spawn } from 'node:child_process';

/** Run `simctl spawn <udid> log show` and return collected lines. */
export async function collectSimulatorLog(
  udid: string,
  opts: { lastSec?: number; bundleId?: string },
): Promise<string[]> {
  const args = ['simctl', 'spawn', udid, 'log', 'show', '--style', 'compact'];

  const lastSec = opts.lastSec && opts.lastSec > 0 ? opts.lastSec : 60;
  args.push('--last', `${lastSec}s`);

  if (opts.bundleId) {
    args.push('--predicate', `process CONTAINS "${opts.bundleId}"`);
  }

  return new Promise<string[]>((resolve) => {
    const proc = spawn('xcrun', args, { stdio: ['ignore', 'pipe', 'pipe'] });
    const lines: string[] = [];
    let stdoutBuf = '';
    let stderrBuf = '';

    proc.stdout.on('data', (chunk: Buffer) => {
      stdoutBuf += chunk.toString();
      const parts = stdoutBuf.split('\n');
      stdoutBuf = parts.pop() ?? '';
      for (const line of parts) {
        if (line.trim()) lines.push(line.trim());
      }
    });

    proc.stderr.on('data', (chunk: Buffer) => {
      stderrBuf += chunk.toString();
      const parts = stderrBuf.split('\n');
      stderrBuf = parts.pop() ?? '';
      for (const line of parts) {
        if (line.trim()) lines.push(line.trim());
      }
    });

    proc.on('error', () => resolve(lines));
    proc.on('close', () => {
      if (stdoutBuf.trim()) lines.push(stdoutBuf.trim());
      if (stderrBuf.trim()) lines.push(stderrBuf.trim());
      resolve(lines);
    });
  });
}
