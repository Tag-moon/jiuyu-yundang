import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { env, numberEnv, ROOT, resolvePath } from './lib/env.js';
import * as store from './lib/store.js';
import * as rds from './lib/rds.js';
import * as redis from './lib/redis.js';
import * as obs from './lib/obs.js';
import * as llm from './lib/llm.js';
import * as sync from './lib/sync.js';

const PORT = numberEnv('PORT', 3000);
const WEB_DIR = path.join(ROOT, 'web');
const IMAGE_DIR = resolvePath(env.HERITAGE_IMAGE_DIR);
const startedAt = Date.now();
let requestCount = 0;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon'
};

function send(res, status, body, contentType = 'application/json; charset=utf-8') {
  const payload = typeof body === 'string' || Buffer.isBuffer(body)
    ? body
    : JSON.stringify(body, null, 2);
  res.writeHead(status, {
    'Content-Type': contentType,
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': env.CORS_ORIGIN || '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization'
  });
  res.end(payload);
}

function sendJson(res, status, data) {
  send(res, status, data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > 2_000_000) reject(new Error('请求体过大'));
    });
    req.on('end', () => {
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error('JSON 格式错误'));
      }
    });
    req.on('error', reject);
  });
}

function serveFile(res, file) {
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return false;
  const ext = path.extname(file).toLowerCase();
  send(res, 200, fs.readFileSync(file), MIME[ext] || 'application/octet-stream');
  return true;
}

async function handleApi(req, res, url) {
  const { pathname, searchParams } = url;

  if (pathname === '/api/health' && req.method === 'GET') {
    return sendJson(res, 200, {
      ok: true,
      service: 'jiuyu-yundang-api',
      version: env.APP_VERSION || '1.0.0',
      time: new Date().toISOString()
    });
  }

  if (pathname === '/api/meta' && req.method === 'GET') {
    return sendJson(res, 200, {
      ...store.facets(),
      dataMode: store.getDataMode(),
      imageBase: obs.obsInfo().baseUrl
    });
  }

  if (pathname === '/api/heritages' && req.method === 'GET') {
    const result = store.search({
      keyword: searchParams.get('keyword') || '',
      era: searchParams.get('era') || '全部',
      type: searchParams.get('type') || '全部',
      city: searchParams.get('city') || '全部',
      page: Number(searchParams.get('page') || 1),
      pageSize: Number(searchParams.get('pageSize') || 12)
    });
    return sendJson(res, 200, {
      ...result,
      items: result.items.map((item) => ({ ...item, imageUrl: obs.imageUrl(item) }))
    });
  }

  const detailMatch = pathname.match(/^\/api\/heritages\/([^/]+)$/);
  if (detailMatch && req.method === 'GET') {
    const id = decodeURIComponent(detailMatch[1]);
    const item = store.getById(id);
    if (!item) return sendJson(res, 404, { error: '未找到该遗址' });
    return sendJson(res, 200, {
      ...item,
      imageUrl: obs.imageUrl(item),
      related: store.related(id, 4).map((relatedItem) => ({
        ...store.slim(relatedItem),
        imageUrl: obs.imageUrl(relatedItem)
      }))
    });
  }

  if (pathname === '/api/routes' && req.method === 'GET') {
    const city = searchParams.get('city') || '';
    const era = searchParams.get('era') || '';
    const keyword = searchParams.get('keyword') || '';
    const limit = Math.min(8, Number(searchParams.get('limit') || 4));
    const items = store.recommend({ city, era, keyword, limit });
    return sendJson(res, 200, {
      title: city ? `${city}研学路线` : '黄河文化主题路线',
      items: items.map((item) => ({
        ...store.slim(item),
        imageUrl: obs.imageUrl(item),
        reason: city === item.city ? '同城串联，交通成本低' : '主题相关，可按年代顺序理解'
      }))
    });
  }

  if (pathname === '/api/chat' && req.method === 'POST') {
    const body = await readBody(req);
    const question = String(body.question || '').trim();
    if (!question) return sendJson(res, 400, { error: '问题不能为空' });
    const history = Array.isArray(body.history) ? body.history : [];
    const cacheKey = 'chat:' + crypto.createHash('sha1').update(question).digest('hex');
    let result = await redis.getJson(cacheKey);
    if (!result) {
      result = await llm.answerQuestion(question, history);
      await redis.setJson(cacheKey, result, 300);
    }
    await redis.incr('chat:total');
    await rds.saveChatMessage({ ...result, question, userId: body.userId || 'anonymous' });
    return sendJson(res, 200, result);
  }

  if (pathname === '/api/sync') {
    const userId = searchParams.get('userId') || 'demo-user';
    if (req.method === 'GET') {
      return sendJson(res, 200, await sync.pullState(userId));
    }
    if (req.method === 'POST') {
      const body = await readBody(req);
      return sendJson(res, 200, await sync.pushState(userId, body));
    }
  }

  if (pathname === '/api/status' && req.method === 'GET') {
    const rdsStats = await rds.getRdsStats();
    return sendJson(res, 200, {
      app: {
        version: env.APP_VERSION || '1.0.0',
        env: env.APP_ENV || 'local',
        uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
        requestCount
      },
      data: {
        mode: store.getDataMode(),
        heritageCount: store.count()
      },
      services: {
        rds: { ...rds.rdsInfo(), stats: rdsStats },
        redis: redis.redisInfo(),
        obs: obs.obsInfo(),
        llm: {
          configured: Boolean(env.LLM_BASE_URL && env.LLM_API_KEY),
          model: env.LLM_MODEL || null
        }
      },
      sync: sync.syncStats()
    });
  }

  return sendJson(res, 404, { error: '接口不存在' });
}

const server = http.createServer(async (req, res) => {
  requestCount += 1;
  try {
    const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
    if (req.method === 'OPTIONS') return send(res, 204, '');

    if (url.pathname.startsWith('/api/')) return await handleApi(req, res, url);

    if (url.pathname.startsWith('/images/') && req.method === 'GET') {
      const name = path.basename(decodeURIComponent(url.pathname.slice('/images/'.length)));
      if (serveFile(res, path.join(IMAGE_DIR, name))) return;
      return sendJson(res, 404, { error: '图片不存在' });
    }

    if (req.method === 'GET') {
      const relative = decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname);
      const target = path.join(WEB_DIR, path.normalize(relative).replace(/^(\.\.[/\\])+/, ''));
      if (!target.startsWith(WEB_DIR)) return sendJson(res, 403, { error: '禁止访问' });
      if (serveFile(res, target)) return;
    }

    return sendJson(res, 404, { error: '页面不存在' });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error('[九曲云档 API]', message);
    return sendJson(res, 500, { error: message });
  }
});

async function bootstrap() {
  await rds.initRds();
  await redis.initRedis();
  const rdsData = await rds.loadHeritagesFromRds();
  if (rdsData && rdsData.length > 0) {
    store.setHeritageItems(rdsData, 'huaweicloud-rds');
    console.log(`[九曲云档] 已从 RDS 加载 ${rdsData.length} 条遗址数据`);
  } else {
    const count = store.initStore();
    console.log(`[九曲云档] 本地数据兜底加载 ${count} 条遗址数据`);
  }
  console.log(`[九曲云档] RDS: ${rds.isRdsReady() ? '已连接' : '未配置/不可用'}`);
  console.log(`[九曲云档] Redis: ${redis.isRedisReady() ? '已连接' : '未配置/不可用'}`);
  console.log(`[九曲云档] API 已启动: http://localhost:${PORT}`);
  server.listen(PORT, '0.0.0.0');
}

bootstrap();
