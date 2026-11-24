import { env, numberEnv } from './env.js';

let client = null;
let ready = false;
let lastError = '';
const counters = { hits: 0, misses: 0, sets: 0 };

export function isRedisReady() {
  return ready;
}

export function redisInfo() {
  return {
    ready,
    host: env.REDIS_HOST || env.REDIS_URL || null,
    lastError: lastError || null,
    counters: { ...counters }
  };
}

export async function initRedis() {
  if (!env.REDIS_HOST && !env.REDIS_URL) return false;
  try {
    const { createClient } = await import('redis');
    client = env.REDIS_URL
      ? createClient({ url: env.REDIS_URL })
      : createClient({
          socket: {
            host: env.REDIS_HOST,
            port: numberEnv('REDIS_PORT', 6379)
          },
          password: env.REDIS_PASSWORD || undefined
        });
    client.on('error', (error) => {
      lastError = error instanceof Error ? error.message : String(error);
    });
    await client.connect();
    ready = true;
    lastError = '';
  } catch (error) {
    ready = false;
    client = null;
    lastError = error instanceof Error ? error.message : String(error);
  }
  return ready;
}

export async function getJson(key) {
  if (!ready || !client) {
    counters.misses += 1;
    return null;
  }
  try {
    const raw = await client.get(key);
    if (raw === null) {
      counters.misses += 1;
      return null;
    }
    counters.hits += 1;
    return JSON.parse(raw);
  } catch (error) {
    counters.misses += 1;
    lastError = error instanceof Error ? error.message : String(error);
    return null;
  }
}

export async function setJson(key, value, ttlSeconds = 300) {
  counters.sets += 1;
  if (!ready || !client) return false;
  try {
    await client.set(key, JSON.stringify(value), { EX: ttlSeconds });
    return true;
  } catch (error) {
    lastError = error instanceof Error ? error.message : String(error);
    return false;
  }
}

export async function incr(key) {
  if (!ready || !client) return 0;
  try {
    return await client.incr(key);
  } catch (error) {
    lastError = error instanceof Error ? error.message : String(error);
    return 0;
  }
}
