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
    const stdout: string[] = [];
    const stderr: string[] = [];
    let stdoutBuf = '';
    let stderrBuf = '';

    proc.stdout.on('data', (chunk: Buffer) => {
      stdoutBuf += chunk.toString();
      const parts = stdoutBuf.split('\n');
      stdoutBuf = parts.pop() ?? '';
      for (const line of parts) {
        if (line.trim()) stdout.push(line.trim());
      }
    });

    proc.stderr.on('data', (chunk: Buffer) => {
      stderrBuf += chunk.toString();
      const parts = stderrBuf.split('\n');
      stderrBuf = parts.pop() ?? '';
      for (const line of parts) {
        if (line.trim()) stderr.push(line.trim());
      }
    });

    proc.on('error', () => resolve(stdout));
    proc.on('close', () => {
      if (stdoutBuf.trim()) stdout.push(stdoutBuf.trim());
      // log show outputs to stderr, not stdout
      const allLines = [...stdout, ...stderr];
      resolve(allLines);
    });
  });
}
