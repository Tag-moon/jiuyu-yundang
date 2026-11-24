# 架构说明

## 一句话架构

鸿蒙端和 Web Demo 访问云上 API；云上 API 关联华为云 RDS、Redis、OBS 与大模型服务；CodeArts 智能体和 Skills 贯穿需求分析、代码生成、数据导入、测试和部署。

## 分层

### 入口层

- **HarmonyOS 端**：保留遗址浏览、收藏、笔记、知识图谱、桌面卡片和分布式同步体验。
- **Web 可视化 Demo**：评委通过浏览器直接体验检索、问答、路线和云运行状态。

### 应用层

`apps/api/server.js` 提供：

| 接口 | 说明 |
|---|---|
| `GET /api/health` | 健康检查 |
| `GET /api/meta` | 年代/类型/城市筛选项 |
| `GET /api/heritages` | 关键词与三维筛选 |
| `GET /api/heritages/:id` | 遗址详情与关联推荐 |
| `GET /api/routes` | 研学路线 |
| `POST /api/chat` | AI 问答，返回答案与来源 |
| `GET/POST /api/sync` | 云同步拉取/推送 |
| `GET /api/status` | 云资源运行状态 |
| `GET /images/:name` | 本地图片兜底 |

### 华为云资源层

- **RDS for MySQL**：`heritage_site` 存完整档案 JSON 与检索字段；`chat_message` 存问答；`user_sync_state` 存用户云同步状态。
- **Redis/DCS**：缓存问答结果、热点检索，统计命中/未命中/写入次数。
- **OBS**：存放遗址图片。未配置 OBS 时由 API 从本地 rawfile 提供图片。
- **大模型服务**：通过 OpenAI 兼容格式调用华为云 MaaS/ModelArts Studio 可用的大模型；未配置时使用内置演示模式。

## 数据流向

1. 用户提问 → API 从档案中检索相关遗址；
2. API 把遗址上下文、用户问题和最近对话组成 Prompt；
3. 大模型返回答案，API 附上可追溯来源；
4. 问答写入 RDS，结果写入 Redis；
5. Web Demo 的状态面板展示服务连接与缓存统计，形成可验证证据。

## 云同步策略

保留原 HarmonyOS 端 `DistributedKVStore` 的端侧同步能力，同时新增云端同步：

- 收藏按 `updatedAt || createdAt` 比较；
- 笔记按逻辑标识 `itemId|createdAt` 合并；
- 足迹按 `itemId` 去重；
- 删除墓碑按时间戳传播；
- 云端合并结果回写本地库。

这样既保留鸿蒙多设备协同特色，又满足赛题「应用跑在云上」的要求。

## 本地兜底设计

未配置 RDS/Redis/OBS/大模型时，系统自动使用：

- 本地 `heritages.json`；
- 进程内缓存计数；
- 本地 rawfile 图片；
- 内置档案问答与路线生成。

这保证评委或开发者在没有云资源时也能完整演示交互；配置云资源后自动切换到真实华为云链路。
