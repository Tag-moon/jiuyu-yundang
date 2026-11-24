# Skill: heritage-data-import

## 描述

把 HarmonyOS 端的 `heritages.json` 转换为华为云 RDS for MySQL 的建表与初始化 SQL。

## 触发场景

- 新增或更新遗址档案；
- 需要把本地 JSON 数据迁移到 RDS；
- 需要生成可复现的 seed.sql。

## 输入变量

```text
SOURCE=harmony-app/entry/src/main/resources/rawfile/heritages.json
TARGET=scripts/seed.sql
TABLE=heritage_site
```

## 指令

请读取 `heritages.json`，生成 RDS 初始化 SQL：

1. 使用 `utf8mb4`；
2. `heritage_site` 表保留 id、name、city、era、type、type_desc、dynasty、summary、image、detail_json；
3. `detail_json` 保存完整条目 JSON；
4. 为 city、era、type 建索引；
5. 使用 `INSERT ... ON DUPLICATE KEY UPDATE`，保证可重复执行；
6. 对单引号、反斜杠、换行进行转义；
7. 输出执行导入的 mysql 命令。

## 期望输出

- `scripts/schema.sql`
- `scripts/seed.sql`
- 导入成功后的记录数校验命令
