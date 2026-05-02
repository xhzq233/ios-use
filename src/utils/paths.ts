import fs from 'fs';
import os from 'os';
import path from 'path';

export const IOS_USE_HOME = path.resolve(os.homedir(), '.ios-use');
export const STATE_DIR = path.join(IOS_USE_HOME, 'state');
export const LOG_DIR = path.join(IOS_USE_HOME, 'logs');
export const ARTIFACT_DIR = path.join(IOS_USE_HOME, 'artifacts');

export const CONFIG_FILE = path.join(IOS_USE_HOME, 'config.json');
export const SESSION_FILE = path.join(STATE_DIR, 'session.json');
export const NSLOG_LOCK_FILE = path.join(STATE_DIR, 'nslog.lock');

export const DRIVER_LOG_FILE = path.join(LOG_DIR, 'driver.log');

export function ensureDir(dir: string): void {
  fs.mkdirSync(dir, { recursive: true });
}

export function ensureStateDir(): void {
  ensureDir(STATE_DIR);
}

export function ensureLogDir(): void {
  ensureDir(LOG_DIR);
}

export function ensureArtifactDir(): void {
  ensureDir(ARTIFACT_DIR);
}

export function ensureIosUseHome(): void {
  ensureDir(IOS_USE_HOME);
  ensureStateDir();
  ensureLogDir();
  ensureArtifactDir();
}
