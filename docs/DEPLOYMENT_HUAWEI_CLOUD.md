# 华为云部署指南

> **推荐链路：auto-deploy Skill 一键部署。**  
> 传统 SSH/脚本方式仅作为备用方案保留，不作为赛题一首选演示路径。

## 0. 前提

- 已报名华为 ICT 大赛赛题一，并领取华为云代金券/成长积分；
- 已有华为云账号，已实名认证；
- 已获取 AK/SK；
- 本地具备 Python 3.10+、Bash、Terraform 1.8+、Git、SSH/SCP；
- 已复制 `.env.example` 为 `.env`，但不要提交真实密钥。

## 1. 准备外部服务

auto-deploy 只负责单台 ECS Web 应用部署，**不创建 RDS、Redis、OBS、MaaS**。这些必须提前准备。

### RDS for MySQL

- MySQL 8.0，数据库名 `jiuyu_yundang`，字符集 `utf8mb4`；
- 与 ECS 同区域、同 VPC，不开公网；
- 创建账号并授权该库；
- 初始化：

```bash
mysql -h <RDS_HOST> -u <RDS_USER> -p jiuyu_yundang < scripts/schema.sql
node scripts/import-heritages.js
mysql -h <RDS_HOST> -u <RDS_USER> -p jiuyu_yundang < scripts/seed.sql
```

### Redis / DCS

- Redis 5.0/6.0，基础版或单机版即可；
- 与 ECS 同区域、同 VPC；
- 设置密码，记录连接地址和端口。

### OBS

- 创建桶，例如 `jiuyu-images`；
- 新建目录 `heritage/`；
- 上传 `harmony-app/entry/src/main/resources/rawfile/images/` 下全部图片；
- 配置公共只读或桶策略；
- 记录访问前缀，例如：

```text
https://jiuyu-images.obs.cn-north-4.myhuaweicloud.com/heritage
```

### MaaS 大模型

在 MaaS / ModelArts Studio 中：

- 开通预置模型服务；
- 创建 API Key；
- 在“API 调用”页获取 Base URL 和模型 ID。

## 2. 填写环境变量

`.env` 至少包含：

```text
APP_ENV=huaweicloud
RDS_HOST=...
RDS_PORT=3306
RDS_USER=...
RDS_PASSWORD=...
RDS_DATABASE=jiuyu_yundang
REDIS_HOST=...
REDIS_PORT=6379
REDIS_PASSWORD=...
OBS_IMAGE_BASE_URL=...
LLM_BASE_URL=...
LLM_MODEL=...
LLM_API_KEY=...
SYNC_SECRET=<强随机字符串>
```

使用 auto-deploy 时通过 `--env-file .env` 安全注入，禁止把变量值写入部署报告。

## 3. 安装 auto-deploy Skill

在 CodeArts 智能体中输入：

```text
帮我安装 auto-deploy skill，Skill 地址是：https://gitcode.com/weixin_43883336/auto-deploy
```

## 4. 配置 AK/SK

任选一组：

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

## 5. 一键部署

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

部署完成后依次执行健康检查：
- /api/health
- /api/status
- /api/heritages?pageSize=1
- /api/chat

最后输出公网访问地址、资源清单和部署报告。
```

Skill 会自动完成：

1. 项目分析，生成 `analysis.json`；
2. 生成资源规格 `resource-spec.json`；
3. 生成 `deployment-plan.md`；
4. 创建/复用 SSH keypair；
5. 通过 Terraform 创建 ECS、EIP、安全组、VPC/子网；
6. 上传代码、安装运行时、启动服务；
7. 执行健康检查并输出报告。

## 6. 查看产物

`.auto-deploy/` 目录下常见文件：

| 文件 | 说明 |
|---|---|
| `analysis.json` | 项目分析结果 |
| `resource-spec.json` | 云资源规格 |
| `deployment-plan.md` | 部署计划 |
| `run-summary.json` | 执行摘要 |
| `timings.json` | 阶段耗时 |
| `deployment-test-report.md` | 健康检查报告 |

这些是答辩材料中证明自动部署的关键证据，请截图保存。

## 7. 验证清单

访问 Skill 输出的公网地址：

```text
http://<公网IP>:3000/api/status
```

应看到：

- `data.mode = huaweicloud-rds`；
- `services.rds.stats.connected = true`；
- `services.redis.ready = true`；
- `services.obs.configured = true`；
- `services.llm.configured = true`。

再访问 Web Demo 首页，完成一次检索、一次问答、一次路线生成和一次云同步推送/拉取。

## 8. 鸿蒙端收尾

修改：

```text
harmony-app/entry/src/main/ets/common/GuardianConfig.ets
```

把 `CLOUD_ENDPOINT` 改成 Skill 输出的公网 API 地址，然后重新编译。

## 9. 备用方案：传统脚本部署

如果智能体环境无法安装 auto-deploy Skill，可退回传统方式：

```bash
cp .env.deploy.example .env.deploy
# 填写 ECS_HOST / SSH_USER / SSH_KEY_PATH / REMOTE_DIR
bash scripts/deploy-huaweicloud.sh
```

该脚本仍可用，但不是赛题一首选演示路径。

## 10. 资源清理

比赛材料提交前不要清理。测试结束后如需销毁，在智能体中输入：

```text
使用 auto-deploy skill 清理本次部署创建的华为云资源。
请根据 .auto-deploy 目录中的 Terraform 状态执行销毁，并确认 ECS、EIP、安全组等资源已删除。
```

## 11. 常见问题

- **AK/SK 未识别**：在 Skill 目录执行 `python scripts/env_utils.py` 检查；
- **Terraform 下载 provider 失败**：更换可访问镜像源或手动预置 provider；
- **健康检查失败**：确认 `.env` 已通过 `--env-file` 注入，且 RDS/Redis 与 ECS 同 VPC；
- **图片 404**：检查 OBS 前缀和对象公共读权限；
- **问答显示本地演示模式**：说明 MaaS 未配置或调用失败，API 会自动兜底。
