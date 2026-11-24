/*
 * 静态演示版接口层：拦截 /api/* 请求，在浏览器内用内置档案完成
 * 检索、详情、路线、问答演示与云同步，逻辑与 apps/api 保持一致。
 */
(function () {
  'use strict';
  window.__JIUYU_STATIC__ = true;

  let items = Array.isArray(window.__JIUYU_DATA__) ? window.__JIUYU_DATA__ : [];
  let requestCount = 0;
  const startedAt = Date.now();
  const syncStates = new Map();

  const nativeFetch = window.fetch.bind(window);
  const imageUrl = (site) => (site && site.image ? `images/${site.image}` : '');

  function facets() {
    const unique = (key) => Array.from(new Set(items.map((item) => item[key]).filter(Boolean)));
    return { eras: ['全部', ...unique('era')], types: ['全部', ...unique('type')], cities: ['全部', ...unique('city')], total: items.length };
  }

  function slim(item) {
    return {
      id: item.id, name: item.name, city: item.city, era: item.era, type: item.type,
      typeDesc: item.typeDesc, dynasty: item.dynasty, summary: item.summary,
      image: item.image, keywords: item.keywords || []
    };
  }

  function search({ keyword = '', era = '全部', type = '全部', city = '全部', page = 1, pageSize = 12 } = {}) {
    const kw = String(keyword).trim().toLowerCase();
    const filtered = items.filter((item) => {
      if (era !== '全部' && item.era !== era) return false;
      if (type !== '全部' && item.type !== type) return false;
      if (city !== '全部' && item.city !== city) return false;
      if (!kw) return true;
      return [item.name, item.city, item.dynasty, item.type, item.typeDesc, item.summary, item.intro, ...(item.keywords || [])]
        .join(' ').toLowerCase().includes(kw);
    });
    const start = (page - 1) * pageSize;
    return { total: filtered.length, page, pageSize, items: filtered.slice(start, start + pageSize).map(slim) };
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

  function recommend({ city = '', era = '', keyword = '', limit = 4, exclude = [] } = {}) {
    return items
      .filter((item) => !exclude.includes(item.id))
      .map((item) => ({ item, value: score(item, { city, era, keyword }) }))
      .sort((a, b) => b.value - a.value || a.item.id.localeCompare(b.item.id))
      .slice(0, limit)
      .map((entry) => entry.item);
  }

  function related(id, limit = 4) {
    const current = items.find((item) => item.id === id);
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

  function retrieve(question, limit = 4) {
    const f = facets();
    const city = f.cities.find((c) => c !== '全部' && question.includes(c)) || '';
    const era = f.eras.find((e) => e !== '全部' && question.includes(e)) || '';
    const direct = items.filter((item) => question.includes(item.name));
    const rest = recommend({ city, era, keyword: question, limit, exclude: direct.map((d) => d.id) });
    return [...direct, ...rest].slice(0, limit);
  }

  function demoAnswer(question, sites) {
    if (/路线|推荐|一日|怎么玩|游/.test(question)) {
      const f = facets();
      const city = f.cities.find((c) => c !== '全部' && question.includes(c)) || '';
      const era = f.eras.find((e) => e !== '全部' && question.includes(e)) || '';
      const route = recommend({ city, era, keyword: question, limit: 3 });
      if (!route.length) return '这条路线暂时没有匹配的档案记录，可以换个城市或年代再问。';
      return `建议走「${route.map((item) => item.name).join(' → ')}」。` +
        (city ? `三处都在${city}，地理上顺路，` : '这些遗址在主题上关联紧密，') +
        `可以按 ${route.map((item) => item.era).filter((v, i, a) => a.indexOf(v) === i).join('、')} 的时间线理解黄河文化。`;
    }
    const primary = sites[0];
    if (!primary) return '档案里暂时没有收录这个问题的答案，可以换个遗址名再问。';
    const detail = primary.archaeology || primary.intro || primary.summary;
    const firstSentence = detail.split(/[。；]/).filter(Boolean).slice(0, 2).join('。') + '。';
    return `${primary.name}值得重点看：${firstSentence}它位于${primary.city}，年代为${primary.era}，可作为理解这一阶段黄河文化的关键样本。`;
  }

  /* ---- 云同步：与服务端 sync.js 相同的版本合并与墓碑规则，状态存于本机浏览器 ---- */
  const emptyState = () => ({ favorites: [], notes: [], history: [], tombstones: [] });
  const versionOf = (item = {}) => Number(item.updatedAt || item.createdAt || item.viewedAt || 0);
  const keyOf = (kind, item = {}) => {
    if (kind === 'notes') return item.logicalId || `${item.itemId || ''}|${item.createdAt || 0}`;
    if (kind === 'history') return item.itemId || String(item.id || '');
    return item.itemId || String(item.id || '');
  };
  function normalize(payload = {}) {
    const state = emptyState();
    for (const kind of ['favorites', 'notes', 'history']) state[kind] = Array.isArray(payload[kind]) ? payload[kind] : [];
    state.tombstones = Array.isArray(payload.tombstones) ? payload.tombstones : [];
    return state;
  }
  function mergeByKind(localList, remoteList, tombstones, kind) {
    const deleted = new Map(tombstones.filter((t) => t.kind === kind).map((t) => [t.id, Number(t.ts || 0)]));
    const merged = new Map();
    for (const item of localList) {
      const key = keyOf(kind, item);
      if ((deleted.get(key) || 0) > versionOf(item)) continue;
      merged.set(key, item);
    }
    for (const item of remoteList) {
      const key = keyOf(kind, item);
      if ((deleted.get(key) || 0) > versionOf(item)) { merged.delete(key); continue; }
      const current = merged.get(key);
      if (!current || versionOf(item) > versionOf(current)) merged.set(key, item);
    }
    return Array.from(merged.values());
  }
  function loadSync(userId) {
    if (syncStates.has(userId)) return syncStates.get(userId);
    let state = emptyState();
    try { state = normalize(JSON.parse(localStorage.getItem(`jiuyu-sync:${userId}`) || 'null') || {}); } catch (e) { /* 忽略损坏数据 */ }
    syncStates.set(userId, state);
    return state;
  }
  function pushSync(userId, payload) {
    const current = loadSync(userId);
    const incoming = normalize(payload);
    const tombstones = new Map();
    for (const tomb of [...current.tombstones, ...incoming.tombstones]) {
      const key = `${tomb.kind}:${tomb.id}`;
      if (!tombstones.has(key) || Number(tomb.ts || 0) > Number(tombstones.get(key).ts || 0)) tombstones.set(key, tomb);
    }
    const all = Array.from(tombstones.values());
    const merged = {
      favorites: mergeByKind(current.favorites, incoming.favorites, all, 'favorite'),
      notes: mergeByKind(current.notes, incoming.notes, all, 'note'),
      history: mergeByKind(current.history, incoming.history, all, 'history'),
      tombstones: all
    };
    syncStates.set(userId, merged);
    try { localStorage.setItem(`jiuyu-sync:${userId}`, JSON.stringify(merged)); } catch (e) { /* 存储已满时仅保留内存状态 */ }
    return merged;
  }

  function status() {
    return {
      app: { version: 'static-demo', env: 'static-demo', uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000), requestCount },
      data: { mode: 'static-demo', heritageCount: items.length },
      services: {
        rds: { configured: false, stats: { connected: false } },
        redis: { ready: false, counters: { hits: 0, misses: 0, sets: 0 } },
        obs: { configured: false, baseUrl: 'images/（随站点内置）' },
        llm: { configured: false, model: null }
      },
      sync: { activeUsers: syncStates.size }
    };
  }

  async function handle(url, init) {
    requestCount += 1;
    const { pathname, searchParams } = url;
    const p = new URLSearchParams(searchParams);
    const json = (data, code = 200) => new Response(JSON.stringify(data), { status: code, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
    const body = init && typeof init.body === 'string' ? JSON.parse(init.body) : {};

    if (pathname.endsWith('/api/meta')) {
      return json({ ...facets(), dataMode: 'static-demo', imageBase: 'images' });
    }
    if (pathname.endsWith('/api/heritages')) {
      const result = search({ keyword: p.get('keyword') || '', era: p.get('era') || '全部', type: p.get('type') || '全部', city: p.get('city') || '全部', page: Number(p.get('page') || 1), pageSize: Number(p.get('pageSize') || 12) });
      return json({ ...result, items: result.items.map((item) => ({ ...item, imageUrl: imageUrl(item) })) });
    }
    const detail = pathname.match(/\/api\/heritages\/([^/]+)$/);
    if (detail) {
      const item = items.find((entry) => entry.id === decodeURIComponent(detail[1]));
      if (!item) return json({ error: '未找到该遗址' }, 404);
      return json({ ...item, imageUrl: imageUrl(item), related: related(item.id, 4).map((r) => ({ ...slim(r), imageUrl: imageUrl(r) })) });
    }
    if (pathname.endsWith('/api/routes')) {
      const city = p.get('city') || '';
      const limit = Math.min(8, Number(p.get('limit') || 4));
      const list = recommend({ city, era: p.get('era') || '', keyword: p.get('keyword') || '', limit });
      return json({
        title: city ? `${city}研学路线` : '黄河文化主题路线',
        items: list.map((item) => ({ ...slim(item), imageUrl: imageUrl(item), reason: city === item.city ? '同城串联，交通成本低' : '主题相关，可按年代顺序理解' }))
      });
    }
    if (pathname.endsWith('/api/chat')) {
      const question = String(body.question || '').trim();
      if (!question) return json({ error: '问题不能为空' }, 400);
      await new Promise((resolve) => setTimeout(resolve, 450));
      const sites = retrieve(question, 4);
      return json({ answer: demoAnswer(question, sites), sources: sites.map((s) => ({ id: s.id, name: s.name, city: s.city, era: s.era })), mode: 'demo' });
    }
    if (pathname.endsWith('/api/sync')) {
      const userId = p.get('userId') || 'demo-user';
      if ((init && init.method) === 'POST') return json(pushSync(userId, body));
      return json(loadSync(userId));
    }
    if (pathname.endsWith('/api/status')) return json(status());
    if (pathname.endsWith('/api/health')) return json({ ok: true, service: 'jiuyu-yundang-static', version: 'static-demo', time: new Date().toISOString() });
    return json({ error: '接口不存在' }, 404);
  }

  window.fetch = function (input, init) {
    const raw = typeof input === 'string' ? input : (input && input.url) || '';
    let url;
    try { url = new URL(raw, location.href); } catch (e) { return nativeFetch(input, init); }
    if (!/\/api\//.test(url.pathname)) return nativeFetch(input, init);
    return handle(url, init);
  };
})();
