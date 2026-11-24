#!/usr/bin/env node
/** 九曲云档 API 冒烟测试：node scripts/smoke-test.js */
const base = (process.env.BASE_URL || 'http://127.0.0.1:3000').replace(/\/$/, '');

const checks = [
  { name: 'health', path: '/api/health', validate: (d) => d.ok === true },
  { name: 'meta', path: '/api/meta', validate: (d) => d.total === 56 },
  { name: 'heritages', path: '/api/heritages?keyword=%E9%BE%99%E9%97%A8&pageSize=3', validate: (d) => d.total >= 1 && d.items[0].imageUrl },
  { name: 'detail', path: '/api/heritages/longmen', validate: (d) => d.name === '龙门石窟' && Array.isArray(d.related) },
  { name: 'routes', path: '/api/routes?city=%E6%B4%9B%E9%98%B3&limit=3', validate: (d) => d.items.length > 0 },
  {
    name: 'chat', path: '/api/chat', method: 'POST',
    body: { question: '推荐一条洛阳一日路线', history: [] },
    validate: (d) => typeof d.answer === 'string' && d.answer.length > 5 && Array.isArray(d.sources)
  },
  {
    name: 'sync', path: '/api/sync?userId=smoke-user', method: 'POST',
    body: {
      favorites: [{ itemId: 'longmen', itemName: '龙门石窟', createdAt: 1, updatedAt: Date.now() }],
      notes: [], history: [], tombstones: []
    },
    validate: (d) => Array.isArray(d.favorites) && d.favorites.length >= 1
  },
  { name: 'pull', path: '/api/sync?userId=smoke-user', validate: (d) => Array.isArray(d.notes) },
  { name: 'status', path: '/api/status', validate: (d) => d.data.heritageCount === 56 && d.services }
];

let failed = 0;
for (const check of checks) {
  try {
    const response = await fetch(base + check.path, {
      method: check.method || 'GET',
      headers: check.body ? { 'Content-Type': 'application/json' } : {},
      body: check.body ? JSON.stringify(check.body) : undefined
    });
    const data = await response.json();
    const ok = response.ok && check.validate(data);
    console.log(`${ok ? 'PASS' : 'FAIL'} ${check.name}`);
    if (!ok) {
      failed += 1;
      console.log(JSON.stringify(data).slice(0, 500));
    }
  } catch (error) {
    failed += 1;
    console.log(`FAIL ${check.name}: ${error.message}`);
  }
}

const html = await fetch(base + '/').then((r) => r.text());
if (html.includes('九曲云档')) console.log('PASS web-demo');
else { failed += 1; console.log('FAIL web-demo'); }

console.log(failed === 0 ? '\n全部检查通过。' : `\n${failed} 项检查失败。`);
process.exit(failed === 0 ? 0 : 1);
