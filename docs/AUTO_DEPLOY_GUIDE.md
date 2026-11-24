# auto-deploy 一键部署指南（推荐）

赛题一强调“基于已有智能体和 Skills，进行应用作品在华为云上的快速部署”。因此本项目**首选 auto-deploy Skill 一键部署**，而不是传统手工开 ECS、写 SSH 脚本的方式。

官方案例原文已复制到：`docs/auto-deploy-case-study.md`。

## 一、能力边界

`auto-deploy` Skill 能自动完成：

- 分析项目技术栈、端口、启动命令和健康检查路径；
- 生成 `analysis.json`、`resource-spec.json`、`deployment-plan.md`；
- 创建或复用 SSH keypair；
- 通过 Terraform 创建 ECS、EIP、安全组、VPC/子网；
- 上传代码、安装运行时、启动服务；
- 执行健康检查并输出部署报告。

它**不负责**创建以下资源，必须提前准备：

- RDS for MySQL；
- Redis/DCS；
- OBS；
- MaaS 大模型服务。

这些外部服务的连接信息通过 `--env-file .env` 安全注入。

## 二、前置准备

### 1. 本机环境

| 依赖 | 要求 |
|---|---|
| Python | 3.10+ |
| Bash | Git Bash / Linux Bash / WSL |
| Terraform | 1.8.0+ |
| Git | 2.0+ |
| SSH / SCP | 系统可用 |

### 2. 华为云 AK/SK

控制台路径：

`我的凭证 → 访问密钥 → 创建访问密钥`

任选一组写入环境变量：

```bash
export HW_ACCESS_KEY="<YOUR_AK>"
export HW_SECRET_KEY="<YOUR_SK>"
```

或：

```bash
export HUAWEICLOUD_ACCESS_KEY="<YOUR_AK>"
export HUAWEICLOUD_SECRET_KEY="<YOUR_SK>"
```

PowerShell：

```powershell
$env:HW_ACCESS_KEY="<YOUR_AK>"
$env:HW_SECRET_KEY="<YOUR_SK>"
```

不要提交 AK/SK，不要把密钥发到群聊。

### 3. 提前准备外部服务

- RDS：建库 `jiuyu_yundang`，执行 `scripts/schema.sql` 和 `scripts/seed.sql`；
- Redis/DCS：同区域、同 VPC，设置密码；
- OBS：创建 `heritage/` 目录并上传遗址图片；
- MaaS：开通模型，记录 Base URL、模型 ID、API Key。

然后复制 `.env.example` 为 `.env` 并填写完整。

## 三、安装 auto-deploy Skill

在 CodeArts 智能体中输入：

```text
帮我安装 auto-deploy skill，Skill 地址是：https://gitcode.com/weixin_43883336/auto-deploy
```

安装后确认目录包含：

```text
SKILL.md
scripts/
templates/
README.md
```

## 四、执行一键部署

进入项目根目录 `jiuyu-cloud-mvp`，在 CodeArts 智能体中输入：

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

部署完成后请依次执行健康检查：
- /api/health
- /api/status
- /api/heritages?pageSize=1
- /api/chat

最后输出公网访问地址、资源清单和部署报告。
```

如果希望成本更低，可以把规格描述改成：

```text
使用最便宜的规格
```

Skill 会自动映射到 `--flavor-tier minimal`。

## 五、查看产物

部署完成后会生成 `.auto-deploy/` 目录，常见文件：

| 文件 | 用途 |
|---|---|
| `analysis.json` | 项目分析结果 |
| `resource-spec.json` | 云资源规格 |
| `deployment-plan.md` | 部署计划 |
| `run-summary.json` | 执行摘要 |
| `timings.json` | 阶段耗时 |
| `deployment-test-report.md` | 健康检查报告 |

这些文件是答辩时证明“智能体完成云上部署”的重要证据，建议截图保存。

## 六、验证

访问 Skill 输出的公网地址：

```text
http://<公网IP>:3000/api/status
```

确认：

- `data.mode = huaweicloud-rds`
- `services.rds.stats.connected = true`
- `services.redis.ready = true`
- `services.obs.configured = true`
- `services.llm.configured = true`

再打开 Web Demo 首页，完成检索、问答、路线和云同步演示。

## 七、鸿蒙端收尾

修改：

```text
harmony-app/entry/src/main/ets/common/GuardianConfig.ets
```

把 `CLOUD_ENDPOINT` 改成 Skill 输出的公网 API 地址：

```ts
static readonly CLOUD_ENDPOINT: string = 'http://<公网IP>:3000/api';
```

正式演示建议后续换成域名 + HTTPS。

## 八、资源清理

比赛答辩和材料提交前不要清理。测试结束后如需销毁资源，在智能体中输入：

```text
使用 auto-deploy skill 清理本次部署创建的华为云资源。
请根据 .auto-deploy 目录中的 Terraform 状态执行销毁，并确认 ECS、EIP、安全组等资源已删除。
```

注意：不要手工删掉一部分资源后继续复用同一个 Terraform 状态。
