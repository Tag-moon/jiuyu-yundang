import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.resolve(here, '../../..');

function readEnvFile(file) {
  if (!fs.existsSync(file)) return {};
  const result = {};
  for (const raw of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const index = line.indexOf('=');
    if (index < 0) continue;
    const key = line.slice(0, index).trim();
    let value = line.slice(index + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    result[key] = value;
  }
  return result;
}

const fileEnv = readEnvFile(path.join(ROOT, '.env'));

const defaults = {
  APP_ENV: 'local',
  PORT: '3000',
  APP_VERSION: '1.0.0-cloud-mvp',
  CORS_ORIGIN: '*',
  HERITAGE_DATA_FILE: 'harmony-app/entry/src/main/resources/rawfile/heritages.json',
  HERITAGE_IMAGE_DIR: 'harmony-app/entry/src/main/resources/rawfile/images',
  OBS_IMAGE_BASE_URL: '',
  RDS_HOST: '',
  RDS_PORT: '3306',
  RDS_USER: '',
  RDS_PASSWORD: '',
  RDS_DATABASE: 'jiuyu_yundang',
  REDIS_HOST: '',
  REDIS_PORT: '6379',
  REDIS_PASSWORD: '',
  REDIS_URL: '',
  LLM_BASE_URL: '',
  LLM_API_KEY: '',
  LLM_MODEL: '',
  SYNC_SECRET: 'change-me-before-deploy'
};

export const env = new Proxy({}, {
  get(_target, key) {
    if (key in process.env) return process.env[key];
    if (key in fileEnv) return fileEnv[key];
    return defaults[key] ?? '';
  },
  has(_target, key) {
    return key in process.env || key in fileEnv || key in defaults;
  },
  ownKeys() {
    return Array.from(new Set([...Object.keys(process.env), ...Object.keys(fileEnv), ...Object.keys(defaults)]));
  },
  getOwnPropertyDescriptor() {
    return { enumerable: true, configurable: true };
  }
});

export function resolvePath(value) {
  if (!value) return '';
  return path.isAbsolute(value) ? value : path.resolve(ROOT, value);
}

export function numberEnv(key, fallback) {
  const value = Number(env[key]);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}
