import fs from 'node:fs';
import { env, resolvePath } from './env.js';

let items = [];
let source = 'local-json';

function loadLocal() {
  const file = resolvePath(env.HERITAGE_DATA_FILE);
  const text = fs.readFileSync(file, 'utf8');
  return JSON.parse(text);
}

export function setHeritageItems(next, nextSource = 'rds') {
  if (!Array.isArray(next) || next.length === 0) return false;
  items = next;
  source = nextSource;
  return true;
}

export function initStore() {
  items = loadLocal();
  source = 'local-json';
  return items.length;
}

export function getDataMode() {
  return source;
}

export function all() {
  return items;
}

export function count() {
  return items.length;
}

export function getById(id) {
  return items.find((item) => item.id === id) || null;
}

export function facets() {
  const unique = (key) => Array.from(new Set(items.map((item) => item[key]).filter(Boolean)));
  return {
    eras: ['全部', ...unique('era')],
    types: ['全部', ...unique('type')],
    cities: ['全部', ...unique('city')],
    total: items.length
  };
}

export function search({ keyword = '', era = '全部', type = '全部', city = '全部',
  page = 1, pageSize = 12 } = {}) {
  const kw = String(keyword).trim().toLowerCase();
  const filtered = items.filter((item) => {
    if (era !== '全部' && item.era !== era) return false;
    if (type !== '全部' && item.type !== type) return false;
    if (city !== '全部' && item.city !== city) return false;
    if (!kw) return true;
    const pool = [item.name, item.city, item.dynasty, item.type, item.typeDesc,
      item.summary, item.intro, ...(item.keywords || [])].join(' ').toLowerCase();
    return pool.includes(kw);
  });
  const start = (page - 1) * pageSize;
  return {
    total: filtered.length,
    page,
    pageSize,
    items: filtered.slice(start, start + pageSize).map(slim)
  };
}

export function slim(item) {
  return {
    id: item.id,
    name: item.name,
    city: item.city,
    era: item.era,
    type: item.type,
    typeDesc: item.typeDesc,
    dynasty: item.dynasty,
    summary: item.summary,
    image: item.image,
    keywords: item.keywords || []
  };
}

function score(item, { city = '', era = '', keyword = '' } = {}) {
  let value = 0;
  if (city && item.city === city) value += 5;
  if (era && item.era === era) value += 3;
  if (keyword) {
    const pool = [item.name, item.summary, ...(item.keywords || [])].join(' ');
    for (const token of keyword.split(/[\s,，、]+/).filter((t) => t.length > 1)) {
      if (pool.includes(token)) value += 2;
    }
  }
  return value;
}

export function recommend({ city = '', era = '', keyword = '', limit = 4, exclude = [] } = {}) {
  return items
    .filter((item) => !exclude.includes(item.id))
    .map((item) => ({ item, value: score(item, { city, era, keyword }) }))
    .sort((a, b) => b.value - a.value || a.item.id.localeCompare(b.item.id))
    .slice(0, limit)
    .map((entry) => entry.item);
}

export function related(id, limit = 4) {
  const current = getById(id);
  if (!current) return [];
  return items
    .filter((item) => item.id !== id)
    .map((item) => {
      let value = 0;
      if (item.era === current.era) value += 3;
      if (item.city === current.city) value += 2;
      if (item.type === current.type) value += 1;
      return { item, value };
    })
    .sort((a, b) => b.value - a.value)
    .slice(0, limit)
    .map((entry) => entry.item);
}

export function retrieve(question, limit = 4) {
  const city = facets().cities.find((c) => c !== '全部' && question.includes(c)) || '';
  const era = facets().eras.find((e) => e !== '全部' && question.includes(e)) || '';
  const direct = items.filter((item) => question.includes(item.name));
  const rest = recommend({ city, era, keyword: question, limit, exclude: direct.map((d) => d.id) });
  return [...direct, ...rest].slice(0, limit);
}
