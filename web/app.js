const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

const state = {
  meta: null,
  page: 1,
  pageSize: 12,
  keyword: '',
  history: [],
  totalPages: 1
};

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

async function api(path, options = {}) {
  const response = await fetch(`/api${path}`, {
    ...options,
    headers: options.body
      ? { 'Content-Type': 'application/json', ...(options.headers || {}) }
      : options.headers
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || `请求失败：${response.status}`);
  return data;
}

function initNav() {
  $$('.nav-item').forEach((button) => {
    button.addEventListener('click', () => {
      $$('.nav-item').forEach((item) => item.classList.remove('active'));
      $$('.tab-panel').forEach((panel) => panel.classList.remove('active'));
      button.classList.add('active');
      $(`#panel-${button.dataset.tab}`).classList.add('active');
      if (button.dataset.tab === 'cloud') loadStatus();
    });
  });
}

function fillSelect(select, values, placeholder) {
  select.innerHTML = '';
  if (placeholder !== undefined) {
    const option = document.createElement('option');
    option.value = '';
    option.textContent = placeholder;
    select.appendChild(option);
  }
  values.forEach((value) => {
    const option = document.createElement('option');
    option.value = value;
    option.textContent = value;
    select.appendChild(option);
  });
}

async function loadMeta() {
  state.meta = await api('/meta');
  $('#archiveCount').textContent = `档案总数 ${state.meta.total} 处`;
  fillSelect($('#eraFilter'), state.meta.eras);
  fillSelect($('#typeFilter'), state.meta.types);
  fillSelect($('#cityFilter'), state.meta.cities);
  fillSelect($('#routeEra'), state.meta.eras, '全部年代');
  fillSelect($('#routeCity'), state.meta.cities, '全部城市');
  const staticMode = state.meta.dataMode === 'static-demo';
  $('#envPill').textContent = staticMode ? '演示版 · 档案内置'
    : (state.meta.dataMode === 'huaweicloud-rds' ? 'RDS 数据已连接' : '本地数据兜底模式');
  $('#envPill').className = staticMode || state.meta.dataMode === 'huaweicloud-rds' ? 'pill ok' : 'pill warn';
}

const SEAL_NUMERALS = ['壹', '贰', '叁', '肆', '伍', '陆', '柒', '捌', '玖', '拾', '拾壹', '拾贰'];

function heritageCard(item, index) {
  const lead = index === 0;
  return `
    <article class="heritage-card${lead ? ' lead' : ''}" data-id="${escapeHtml(item.id)}" style="--i:${index}">
      <div class="card-cover">
        <img src="${escapeHtml(item.imageUrl)}" alt="${escapeHtml(item.name)}" loading="lazy" />
        <span class="card-seal" aria-hidden="true">${SEAL_NUMERALS[index] || index + 1}</span>
      </div>
      <div class="card-body">
        ${lead ? '<span class="lead-badge">卷首特展</span>' : ''}
        <div class="card-tags">
          <span class="tag red">${escapeHtml(item.era)}</span>
          <span class="tag">${escapeHtml(item.city)}</span>
          <span class="tag">${escapeHtml(item.typeDesc || item.type)}</span>
        </div>
        <h3 class="card-title">${escapeHtml(item.name)}</h3>
        <p class="card-summary">${escapeHtml(item.summary)}</p>
      </div>
    </article>`;
}

function initTheme() {
  const root = document.documentElement;
  const toggle = $('#themeToggle');
  const apply = (theme) => {
    root.dataset.theme = theme;
    const toPaper = theme === 'night';
    toggle.setAttribute('aria-pressed', String(theme === 'paper'));
    toggle.querySelector('.theme-glyph').textContent = toPaper ? '☀' : '☾';
    toggle.querySelector('.theme-label').textContent = toPaper ? '宣纸' : '夜墨';
    toggle.title = toPaper ? '切换到宣纸浅色主题' : '切换到夜墨深色主题';
  };
  let saved = null;
  try { saved = localStorage.getItem('jiuyu-theme'); } catch (e) { /* file:// 下可能受限 */ }
  const param = new URLSearchParams(location.search).get('theme');
  const initial = param === 'paper' || param === 'night' ? param : (saved === 'paper' ? 'paper' : 'night');
  apply(initial);
  toggle.addEventListener('click', () => {
    const next = root.dataset.theme === 'night' ? 'paper' : 'night';
    apply(next);
    try { localStorage.setItem('jiuyu-theme', next); } catch (e) { /* 忽略 */ }
  });
}

function initReveal() {
  const targets = $$('.reveal');
  if (!('IntersectionObserver' in window)) {
    targets.forEach((el) => el.classList.add('in'));
    return;
  }
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('in');
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.12 });
  targets.forEach((el) => observer.observe(el));
}

let heritageReq = 0;
async function loadHeritages() {
  const req = ++heritageReq;
  const params = new URLSearchParams({
    keyword: state.keyword,
    era: $('#eraFilter').value || '全部',
    type: $('#typeFilter').value || '全部',
    city: $('#cityFilter').value || '全部',
    page: String(state.page),
    pageSize: String(state.pageSize)
  });
  $('#resultCount').textContent = '正在检索档案…';
  const data = await api(`/heritages?${params}`);
  if (req !== heritageReq) return;
  $('#heritageGrid').innerHTML = data.items.map(heritageCard).join('');
  $('#resultCount').textContent = `共找到 ${data.total} 处遗址`;
  state.totalPages = Math.max(1, Math.ceil(data.total / data.pageSize));
  $('#pageLabel').textContent = `${data.page} / ${state.totalPages}`;
  $('#prevPage').disabled = data.page <= 1;
  $('#nextPage').disabled = data.page >= state.totalPages;
  $$('.heritage-card').forEach((card) => {
    card.addEventListener('click', () => openDetail(card.dataset.id));
  });
}

async function openDetail(id) {
  try {
    const item = await api(`/heritages/${encodeURIComponent(id)}`);
    const events = (item.events || []).map((event) => `<li><b>${escapeHtml(event.time)}</b> ${escapeHtml(event.title)}</li>`).join('');
    const relics = (item.relics || []).map((relic) => `<li><b>${escapeHtml(relic.name)}</b>：${escapeHtml(relic.desc)}</li>`).join('');
    const related = (item.related || []).map((relatedItem) => `
      <span class="source" data-related="${escapeHtml(relatedItem.id)}">${escapeHtml(relatedItem.name)}</span>
    `).join('');
    $('#detailContent').innerHTML = `
      <img class="detail-cover" src="${escapeHtml(item.imageUrl)}" alt="${escapeHtml(item.name)}" />
      <h2 class="detail-title">${escapeHtml(item.name)}</h2>
      <div class="detail-meta">${escapeHtml(item.city)} · ${escapeHtml(item.era)} · ${escapeHtml(item.dynasty)} · ${escapeHtml(item.typeDesc || item.type)}</div>
      <div class="detail-section"><h3>档案摘要</h3><p>${escapeHtml(item.summary)}</p></div>
      <div class="detail-section"><h3>遗址介绍</h3><p>${escapeHtml(item.intro)}</p></div>
      ${item.archaeology ? `<div class="detail-section"><h3>考古发现</h3><p>${escapeHtml(item.archaeology)}</p></div>` : ''}
      ${relics ? `<div class="detail-section"><h3>代表性文物</h3><ul class="detail-list">${relics}</ul></div>` : ''}
      ${events ? `<div class="detail-section"><h3>历史事件</h3><ul class="detail-list">${events}</ul></div>` : ''}
      ${item.tourism?.address ? `<div class="detail-section"><h3>研学信息</h3><p>${escapeHtml(item.tourism.address)}｜${escapeHtml(item.tourism.openTime || '')}｜${escapeHtml(item.tourism.ticket || '')}</p></div>` : ''}
      <div class="detail-section"><h3>关联推荐${state.meta?.dataMode === 'huaweicloud-rds' ? '（RDS 关系检索）' : ''}</h3><div class="sources">${related}</div></div>`;
    $('#detailMask').classList.add('show');
    $$('[data-related]').forEach((tag) => {
      tag.style.cursor = 'pointer';
      tag.addEventListener('click', () => {
        $('#detailMask').classList.remove('show');
        openDetail(tag.dataset.related);
      });
    });
  } catch (error) {
    alert(error.message);
  }
}

function appendMessage(role, text, sources = []) {
  const wrapper = document.createElement('div');
  wrapper.className = `msg ${role}`;
  const sourceHtml = sources.length
    ? `<div class="sources">${sources.map((source) => `<span class="source">${escapeHtml(source.name)} · ${escapeHtml(source.city)}</span>`).join('')}</div>`
    : '';
  wrapper.innerHTML = `
    <div class="msg-avatar">${role === 'user' ? '我' : '灵'}</div>
    <div class="msg-body">
      <div class="msg-name">${role === 'user' ? '演示用户' : '黄河守护灵'}</div>
      <div class="msg-text">${escapeHtml(text)}</div>
      ${sourceHtml}
    </div>`;
  $('#chatMessages').appendChild(wrapper);
  $('#chatMessages').scrollTop = $('#chatMessages').scrollHeight;
}

async function sendChat(question) {
  const text = String(question || $('#chatInput').value).trim();
  if (!text) return;
  $('#chatInput').value = '';
  appendMessage('user', text);
  $('#chatMode').textContent = '检索档案并生成回答…';
  const typing = document.createElement('div');
  typing.className = 'msg assistant msg-typing';
  typing.innerHTML = `
    <div class="msg-avatar">灵</div>
    <div class="msg-body">
      <div class="msg-name">黄河守护灵</div>
      <div class="msg-text"><span class="typing-dot"></span><span class="typing-dot"></span><span class="typing-dot"></span></div>
    </div>`;
  $('#chatMessages').appendChild(typing);
  $('#chatMessages').scrollTop = $('#chatMessages').scrollHeight;
  try {
    const result = await api('/chat', {
      method: 'POST',
      body: JSON.stringify({ question: text, history: state.history, userId: $('#userId').value })
    });
    typing.remove();
    appendMessage('assistant', result.answer, result.sources);
    state.history.push({ role: 'user', content: text });
    state.history.push({ role: 'assistant', content: result.answer });
    $('#chatMode').textContent = result.mode === 'cloud' ? '大模型已接入' : '本地演示模式';
    $('#chatMode').className = result.mode === 'cloud' ? 'pill ok' : 'pill warn';
  } catch (error) {
    typing.remove();
    appendMessage('assistant', `问答失败：${error.message}`);
    $('#chatMode').textContent = '问答异常';
  }
}

let routeReq = 0;
async function generateRoute() {
  const req = ++routeReq;
  const params = new URLSearchParams({
    keyword: $('#routeKeyword').value,
    city: $('#routeCity').value,
    era: $('#routeEra').value,
    limit: '4'
  });
  $('#routeResult').innerHTML = '<div class="empty-state">正在按档案关系生成路线…</div>';
  const data = await api(`/routes?${params}`);
  if (req !== routeReq) return;
  if (!data.items.length) {
    $('#routeResult').innerHTML = '<div class="empty-state">没有匹配的遗址，请调整条件。</div>';
    return;
  }
  $('#routeResult').innerHTML = `
    <div class="route-title">${escapeHtml(data.title)}</div>
    <div class="route-list">${data.items.map((item, index) => `
      <div class="route-stop" style="--i:${index}">
        <div class="route-index">${index + 1}</div>
        <div>
          <div class="route-stop-name">${escapeHtml(item.name)}</div>
          <div class="route-stop-meta">${escapeHtml(item.city)} · ${escapeHtml(item.era)} · ${escapeHtml(item.typeDesc || item.type)}</div>
        </div>
        <div class="route-reason">${escapeHtml(item.reason)}</div>
      </div>`).join('')}</div>`;
}

function statusCard(title, value, detail, on, index) {
  return `
    <div class="status-card" style="--i:${index}">
      <div class="status-card-title"><b>${escapeHtml(title)}</b><span class="status-dot ${on ? 'on' : 'off'}"></span></div>
      <div class="status-value">${escapeHtml(value)}</div>
      <div class="status-detail">${escapeHtml(detail)}</div>
    </div>`;
}

async function loadStatus() {
  try {
    const data = await api('/status');
    const cards = [
      statusCard('API 服务', data.app.env, `${data.app.version}｜运行 ${data.app.uptimeSeconds}s｜请求 ${data.app.requestCount}`, true, 0),
      statusCard('档案数据', data.data.heritageCount, `来源：${data.data.mode}`, data.data.mode === 'huaweicloud-rds', 1),
      statusCard('RDS for MySQL', data.services.rds.stats.connected ? '已连接' : '演示模式',
        data.services.rds.stats.sites ? `${data.services.rds.stats.sites} 条档案｜${data.services.rds.stats.chats} 条问答` : '配置 RDS_HOST 后自动切换', data.services.rds.stats.connected, 2),
      statusCard('Redis / DCS', data.services.redis.ready ? '已连接' : '进程内缓存',
        `命中 ${data.services.redis.counters.hits}｜未命中 ${data.services.redis.counters.misses}｜写入 ${data.services.redis.counters.sets}`, data.services.redis.ready, 3),
      statusCard('OBS 图片', data.services.obs.configured ? '已配置' : '本地兜底', data.services.obs.baseUrl, data.services.obs.configured, 4),
      statusCard('大模型服务', data.services.llm.configured ? '已接入' : '演示模式',
        data.services.llm.model || '配置 LLM_BASE_URL 后自动切换', data.services.llm.configured, 5)
    ];
    $('#statusGrid').innerHTML = cards.join('');
  } catch (error) {
    $('#statusGrid').innerHTML = `<div class="empty-state">状态加载失败：${escapeHtml(error.message)}</div>`;
  }
}

function sampleSyncPayload() {
  const now = Date.now();
  return {
    favorites: [{ itemId: 'longmen', itemName: '龙门石窟', itemEra: '汉唐', itemType: '古建筑', itemCity: '洛阳', tags: ['研学路线'], createdAt: now, updatedAt: now }],
    notes: [{ itemId: 'longmen', itemName: '龙门石窟', content: '奉先寺卢舍那大佛是重点。', createdAt: now, updatedAt: now }],
    history: [{ itemId: 'longmen', itemName: '龙门石窟', viewedAt: now }],
    tombstones: []
  };
}

async function syncPush() {
  try {
    const result = await api(`/sync?userId=${encodeURIComponent($('#userId').value)}`, {
      method: 'POST', body: JSON.stringify(sampleSyncPayload())
    });
    $('#syncPreview').textContent = JSON.stringify(result, null, 2);
    $('#syncMessage').textContent = `已推送：收藏 ${result.favorites.length}｜笔记 ${result.notes.length}｜足迹 ${result.history.length}`;
  } catch (error) {
    $('#syncMessage').textContent = error.message;
  }
}

async function syncPull() {
  try {
    const result = await api(`/sync?userId=${encodeURIComponent($('#userId').value)}`);
    $('#syncPreview').textContent = JSON.stringify(result, null, 2);
    $('#syncMessage').textContent = `已拉取：收藏 ${result.favorites.length}｜笔记 ${result.notes.length}｜足迹 ${result.history.length}`;
  } catch (error) {
    $('#syncMessage').textContent = error.message;
  }
}

function bindEvents() {
  $('#searchBtn').addEventListener('click', () => {
    state.page = 1;
    state.keyword = $('#keyword').value;
    loadHeritages();
  });
  $('#keyword').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') $('#searchBtn').click();
  });
  ['#eraFilter', '#typeFilter', '#cityFilter'].forEach((selector) => {
    $(selector).addEventListener('change', () => { state.page = 1; loadHeritages(); });
  });
  $('#prevPage').addEventListener('click', () => { if (state.page > 1) { state.page -= 1; loadHeritages(); } });
  $('#nextPage').addEventListener('click', () => { if (state.page < state.totalPages) { state.page += 1; loadHeritages(); } });
  $('#detailClose').addEventListener('click', () => $('#detailMask').classList.remove('show'));
  $('#detailMask').addEventListener('click', (event) => {
    if (event.target === $('#detailMask')) $('#detailMask').classList.remove('show');
  });
  $('#chatSend').addEventListener('click', () => sendChat());
  $('#chatInput').addEventListener('keydown', (event) => { if (event.key === 'Enter') sendChat(); });
  $$('#suggestions button').forEach((button) => {
    button.addEventListener('click', () => sendChat(button.textContent));
  });
  $('#routeBtn').addEventListener('click', generateRoute);
  $('#refreshStatus').addEventListener('click', loadStatus);
  $('#syncPush').addEventListener('click', syncPush);
  $('#syncPull').addEventListener('click', syncPull);
}

function showLaunchNotice(mode, message) {
  const ready = mode === 'ready';
  const notice = document.createElement('div');
  notice.className = 'launch-notice';
  const theme = document.documentElement.dataset.theme || 'night';
  notice.innerHTML = ready ? `
    <div class="launch-seal">云</div>
    <div class="launch-body">
      <h2>服务已就绪 · 请入云上展厅</h2>
      <p>当前是直接双击打开的本地文件（file:// 协议），档案数据、图片与 AI 问答需经本地服务加载。已检测到服务正在运行。</p>
      <a class="primary launch-link" href="http://localhost:3000/?theme=${theme}">进入云上展厅</a>
    </div>` : `
    <div class="launch-seal">启</div>
    <div class="launch-body">
      <h2>请先启动本地服务</h2>
      <p>${escapeHtml(message)}</p>
      <p>在项目根目录执行 <code>node apps/api/server.js</code>，服务就绪后通过下方地址访问完整功能。</p>
      <a class="primary launch-link" href="http://localhost:3000">打开 localhost:3000</a>
    </div>`;
  document.querySelector('.content').prepend(notice);
  $('#envPill').textContent = ready ? '服务运行中 · 本地预览' : '未连接服务';
  $('#envPill').className = ready ? 'pill ok' : 'pill warn';
  $('#archiveCount').textContent = '档案总数 —';
  $('#resultCount').textContent = ready ? '服务运行中，请进入云上展厅' : '等待服务连接';
  $('#heritageGrid').innerHTML = '<div class="empty-state">启动服务后即可查看 56 处遗址档案</div>';
}

async function probeService() {
  try {
    const response = await fetch('http://localhost:3000/api/health', { cache: 'no-store' });
    return response.ok;
  } catch (error) {
    return false;
  }
}

async function main() {
  initTheme();
  initNav();
  initReveal();
  if (location.protocol === 'file:' && !window.__JIUYU_STATIC__) {
    const ready = await probeService();
    showLaunchNotice(ready ? 'ready' : 'start', '当前是直接双击打开的本地文件（file:// 协议），档案数据、图片与 AI 问答需要通过本地服务加载。');
    return;
  }
  bindEvents();
  await loadMeta();
  await loadHeritages();
  await loadStatus();
}

main().catch((error) => {
  showLaunchNotice('start', window.__JIUYU_STATIC__
    ? `演示版加载失败：${error.message}`
    : `服务连接失败：${error.message}`);
});
