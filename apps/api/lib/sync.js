import { saveSyncState, loadSyncState } from './rds.js';

const states = new Map();

function emptyState() {
  return { favorites: [], notes: [], history: [], tombstones: [] };
}

function versionOf(item = {}) {
  return Number(item.updatedAt || item.createdAt || item.viewedAt || 0);
}

function keyOf(kind, item = {}) {
  if (kind === 'notes') return item.logicalId || `${item.itemId || ''}|${item.createdAt || 0}`;
  if (kind === 'history') return item.itemId || String(item.id || '');
  return item.itemId || String(item.id || '');
}

function mergeByKind(localList = [], remoteList = [], tombstones = [], kind = '') {
  const deleted = new Map(
    tombstones
      .filter((tomb) => tomb.kind === kind)
      .map((tomb) => [tomb.id, Number(tomb.ts || 0)])
  );
  const merged = new Map();
  for (const item of localList) {
    const key = keyOf(kind, item);
    const tombTs = deleted.get(key) || 0;
    if (tombTs > versionOf(item)) continue;
    merged.set(key, item);
  }
  for (const item of remoteList) {
    const key = keyOf(kind, item);
    const tombTs = deleted.get(key) || 0;
    if (tombTs > versionOf(item)) {
      merged.delete(key);
      continue;
    }
    const current = merged.get(key);
    if (!current || versionOf(item) > versionOf(current)) merged.set(key, item);
  }
  return Array.from(merged.values());
}

function normalize(payload = {}) {
  const state = emptyState();
  for (const kind of ['favorites', 'notes', 'history']) {
    state[kind] = Array.isArray(payload[kind]) ? payload[kind] : [];
  }
  state.tombstones = Array.isArray(payload.tombstones) ? payload.tombstones : [];
  return state;
}

async function persist(userId, state) {
  await saveSyncState(userId, state);
}

export async function pushState(userId, payload) {
  const incoming = normalize(payload);
  const current = states.get(userId) || await loadSyncState(userId) || emptyState();
  const tombstones = new Map();
  for (const tomb of [...normalize(current).tombstones, ...incoming.tombstones]) {
    const key = `${tomb.kind}:${tomb.id}`;
    if (!tombstones.has(key) || Number(tomb.ts || 0) > Number(tombstones.get(key).ts || 0)) {
      tombstones.set(key, tomb);
    }
  }
  const allTombstones = Array.from(tombstones.values());
  const merged = {
    favorites: mergeByKind(current.favorites, incoming.favorites, allTombstones, 'favorite'),
    notes: mergeByKind(current.notes, incoming.notes, allTombstones, 'note'),
    history: mergeByKind(current.history, incoming.history, allTombstones, 'history'),
    tombstones: allTombstones
  };
  states.set(userId, merged);
  await persist(userId, merged);
  return merged;
}

export async function pullState(userId) {
  const state = states.get(userId) || await loadSyncState(userId) || emptyState();
  states.set(userId, state);
  return state;
}

export function syncStats() {
  return { activeUsers: states.size };
}
