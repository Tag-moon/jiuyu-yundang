# Skill: cloud-api-scaffold

## 描述

按赛题要求生成或扩展云上 API，覆盖档案检索、AI 问答、研学路线、云同步和运行状态。

## 触发场景

- 需要新增 API 接口；
- 需要把客户端直连大模型改为云侧代理；
- 需要让 Redis/RDS 参与核心业务流程。

## 输入变量

```text
RUNTIME=Node.js20+
FRAMEWORK=built-in-http
DATA_SOURCE=RDS_JSON_FALLBACK
CACHE=Redis
LLM=OpenAI-compatible
```

## 指令

请基于现有 `apps/api` 生成或扩展 API，要求：

1. 不硬编码任何密钥；
2. 未配置云资源时使用本地数据兜底；
3. `/api/heritages` 支持关键词、年代、类型、城市筛选；
4. `/api/chat` 先从档案检索上下文，再调用大模型，并返回 sources；
5. 相同问题使用 Redis 缓存，且状态面板能显示命中次数；
6. `/api/sync` 使用版本号和墓碑合并收藏、笔记、足迹；
7. `/api/status` 展示 RDS、Redis、OBS、LLM 的连接状态；
8. 输出接口清单和 curl 验证命令。

## 期望输出

- `apps/api/server.js` 路由更新建议
- 每个接口的 curl 冒烟测试命令
- API 文档片段
