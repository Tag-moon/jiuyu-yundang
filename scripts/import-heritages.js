#!/usr/bin/env node
/**
 * 把 HarmonyOS 端的 heritages.json 转换为 RDS 初始化 SQL。
 * 用法：node scripts/import-heritages.js
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const source = path.join(root, 'harmony-app/entry/src/main/resources/rawfile/heritages.json');
const output = path.join(here, 'seed.sql');

function sql(value) {
  if (value === undefined || value === null) return 'NULL';
  return "'" + String(value)
    .replaceAll('\\', '\\\\')
    .replaceAll("'", "''")
    .replaceAll('\n', '\\n')
    .replaceAll('\r', '\\r') + "'";
}

const items = JSON.parse(fs.readFileSync(source, 'utf8'));
if (!Array.isArray(items) || items.length === 0) {
  throw new Error('heritages.json 为空或格式错误');
}

const lines = [
  '-- 由 scripts/import-heritages.js 自动生成，请勿手工编辑',
  'SET NAMES utf8mb4;',
  ''
];

for (let i = 0; i < items.length; i += 20) {
  const chunk = items.slice(i, i + 20);
  const values = chunk.map((item) => '(' + [
    sql(item.id),
    sql(item.name),
    sql(item.city),
    sql(item.era),
    sql(item.type),
    sql(item.typeDesc),
    sql(item.dynasty),
    sql(item.summary),
    sql(item.image),
    sql(JSON.stringify(item))
  ].join(', ') + ')').join(',\n');
  lines.push(
    'INSERT INTO heritage_site ' +
    '(id, name, city, era, type, type_desc, dynasty, summary, image, detail_json) VALUES\n' +
    values + '\n' +
    'ON DUPLICATE KEY UPDATE\n' +
    '  name = VALUES(name), city = VALUES(city), era = VALUES(era), type = VALUES(type),\n' +
    '  type_desc = VALUES(type_desc), dynasty = VALUES(dynasty), summary = VALUES(summary),\n' +
    '  image = VALUES(image), detail_json = VALUES(detail_json);',
    ''
  );
}

fs.writeFileSync(output, lines.join('\n'), 'utf8');
console.log(`已生成 ${output}，共 ${items.length} 条遗址档案。`);
console.log('导入 RDS：mysql -h <RDS_HOST> -u <RDS_USER> -p jiuyu_yundang < scripts/seed.sql');
