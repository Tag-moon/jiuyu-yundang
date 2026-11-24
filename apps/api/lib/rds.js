import { env, numberEnv } from './env.js';

let pool = null;
let ready = false;
let lastError = '';

export function isRdsReady() {
  return ready;
}

export function rdsInfo() {
  return {
    ready,
    host: env.RDS_HOST || null,
    database: env.RDS_DATABASE || null,
    lastError: lastError || null
  };
}

export async function initRds() {
  if (!env.RDS_HOST || !env.RDS_USER || !env.RDS_DATABASE) return false;
  try {
    const mysql = await import('mysql2/promise');
    pool = mysql.createPool({
      host: env.RDS_HOST,
      port: numberEnv('RDS_PORT', 3306),
      user: env.RDS_USER,
      password: env.RDS_PASSWORD,
      database: env.RDS_DATABASE,
      waitForConnections: true,
      connectionLimit: 5,
      connectTimeout: 8000
    });
    const [rows] = await pool.query('SELECT 1 AS ok');
    ready = rows?.[0]?.ok === 1;
    lastError = '';
  } catch (error) {
    ready = false;
    lastError = error instanceof Error ? error.message : String(error);
  }
  return ready;
}

export async function loadHeritagesFromRds() {
  if (!ready || !pool) return null;
  try {
    const [rows] = await pool.query('SELECT detail_json FROM heritage_site ORDER BY id');
    return rows
      .map((row) => {
        const raw = row.detail_json;
        return typeof raw === 'string' ? JSON.parse(raw) : raw;
      })
      .filter(Boolean);
  } catch (error) {
    lastError = error instanceof Error ? error.message : String(error);
    return null;
  }
}

export async function saveChatMessage(payload) {
  if (!ready || !pool) return false;
  try {
    await pool.execute(
      'INSERT INTO chat_message (user_id, question, answer, sources, created_at) VALUES (?, ?, ?, ?, NOW())',
      [
        payload.userId || 'anonymous',
        String(payload.question).slice(0, 4000),
        String(payload.answer).slice(0, 8000),
        JSON.stringify(payload.sources || [])
      ]
    );
    return true;
  } catch (error) {
    lastError = error instanceof Error ? error.message : String(error);
    return false;
  }
}

export async function saveSyncState(userId, payload) {
  if (!ready || !pool) return false;
  try {
    await pool.execute(
      'INSERT INTO user_sync_state (user_id, payload, updated_at) VALUES (?, ?, NOW()) ' +
      'ON DUPLICATE KEY UPDATE payload = VALUES(payload), updated_at = NOW()',
      [userId, JSON.stringify(payload)]
    );
    return true;
  } catch (error) {
    lastError = error instanceof Error ? error.message : String(error);
    return false;
  }
}

export async function loadSyncState(userId) {
  if (!ready || !pool) return null;
  try {
    const [rows] = await pool.query(
      'SELECT payload FROM user_sync_state WHERE user_id = ?', [userId]
    );
    const raw = rows?.[0]?.payload;
    return typeof raw === 'string' ? JSON.parse(raw) : raw || null;
  } catch (error) {
    lastError = error instanceof Error ? error.message : String(error);
    return null;
  }
}

export async function getRdsStats() {
  if (!ready || !pool) return { connected: false, sites: 0, chats: 0 };
  try {
    const [sites] = await pool.query('SELECT COUNT(*) AS n FROM heritage_site');
    const [chats] = await pool.query('SELECT COUNT(*) AS n FROM chat_message');
    return {
      connected: true,
      sites: sites?.[0]?.n || 0,
      chats: chats?.[0]?.n || 0
    };
  } catch (error) {
    lastError = error instanceof Error ? error.message : String(error);
    return { connected: true, sites: 0, chats: 0 };
  }
}
