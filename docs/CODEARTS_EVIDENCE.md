# CodeArts 使用证据记录

赛题一要求下载并使用华为云码道 CodeArts 代码智能体，并体现其在需求分析、代码生成、项目构建、问题修复、部署上线中的价值。

> 本文件是证据模板。请按真实开发过程补充截图、时间和链接，不要编造。

## 一、必须留存的证据

| 环节 | 需要留存 | 对应本仓库材料 |
|---|---|---|
| 需求分析 | 输入赛题要求与原项目现状的提示词、CodeArts 输出的目标架构 | `docs/ARCHITECTURE.md` |
| 代码生成 | 生成 API 路由、RDS/Redis 适配、Web Demo 的提示词与代码片段 | `apps/api/`、`web/` |
| Skills 使用 | 创建/调用 Skill 的截图、Skill 文件、执行结果 | `codearts-skills/` |
| 单元测试 | 测试提示词、生成的测试用例、运行通过截图 | `scripts/smoke-test.js` |
| 问题修复 | Bug 描述、CodeArts 给出的修复建议、修复前后 diff | Git commit |
| 项目构建 | 项目分析、部署计划、构建日志截图 | `.auto-deploy/`、`Dockerfile` |
| 部署上线 | auto-deploy 执行日志、资源清单、`/api/status` 截图 | `docs/AUTO_DEPLOY_GUIDE.md` |

## 二、推荐提示词

### 需求分析

```text
我有 HarmonyOS/ArkTS 项目「九曲云档」，已有本地档案、收藏笔记和分布式同步。
赛题要求使用 CodeArts、智能体与 Skills 关联 RDS/Redis，并部署到华为云，提供可视化 Demo。
请给出最小改造架构，要求保留现有鸿蒙端，新增云上 API 和 Web Demo，并逐条映射到赛题硬性要求。
```

### 代码生成

```text
请基于 Node.js 内置 HTTP 模块生成一个云上 API 服务：
1. /api/heritages 支持关键词与年代、类型、城市筛选；
2. /api/chat 接收问题和历史，返回答案与来源；
3. /api/status 展示 RDS、Redis、OBS、大模型配置状态；
4. 未配置云资源时使用本地 JSON 兜底；
5. 不硬编码任何密钥。
```

### 问题修复

```text
当前 API 服务启动报错 ENOENT，HERITAGE_DATA_FILE 解析到错误目录。
请分析 env.js 中 ROOT 与相对路径解析逻辑，给出最小修复，并说明为什么修复有效。
```

### auto-deploy 一键部署

```text
使用 auto-deploy skill，把当前 Web 应用部署到华为云 ECS。

应用名：jiuyu-yundang-demo
区域：cn-north-4
规格：小规格，2 vCPU / 4 GiB
项目类型：Node.js 单端口 HTTP 服务
启动命令：node apps/api/server.js
监听端口：3000

应用依赖 RDS、Redis、OBS 和 MaaS，请使用 --env-file .env 安全注入环境变量。
不要把变量值、AK/SK、API Key 或密码写入部署报告。

部署完成后依次执行健康检查：
- /api/health
- /api/status
- /api/heritages?pageSize=1
- /api/chat

最后输出公网访问地址、资源清单和部署报告。
```

## 三、部署证据文件

auto-deploy 执行后会在 `.auto-deploy/` 下生成：

| 文件 | 答辩用途 |
|---|---|
| `analysis.json` | 证明智能体自动分析技术栈 |
| `resource-spec.json` | 证明自动规划云资源规格 |
| `deployment-plan.md` | 证明自动生成部署计划 |
| `run-summary.json` | 证明部署执行结果 |
| `timings.json` | 证明各阶段耗时 |
| `deployment-test-report.md` | 证明健康检查通过 |

## 四、Git 提交建议

建议按阶段提交，形成清晰证据链：

```text
feat: add cloud api with rds redis adapters
feat: add web demo for competition
fix: remove hardcoded llm api key
feat: add cloud-first harmony repository
feat: add codearts skills and auto-deploy guide
docs: add auto-deploy case study
docs: add huawei cloud deployment checklist
```

## 五、答辩表达模板

> 我们没有把 CodeArts 当作代码补全工具，而是把「赛题要求 → 架构设计 → API 生成 → 问题修复 → auto-deploy 一键上云 → 健康检查报告」这条链路都在 CodeArts 中完成，并把 Skills 沉淀为可复用工程资产。部署阶段我们用 auto-deploy Skill，通过自然语言完成 ECS、EIP、安全组创建和应用发布，同时用 `--env-file` 安全注入 RDS、Redis、OBS 和 MaaS 配置，证明从想法到云上应用的高效开发实践。
