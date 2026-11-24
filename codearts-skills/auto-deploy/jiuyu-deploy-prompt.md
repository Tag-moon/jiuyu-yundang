# Skill 模板：auto-deploy

## 描述

调用官方 `auto-deploy` Skill，把「九曲云档」Node.js Web 应用一键部署到华为云 ECS。

## 触发场景

- 赛题一要求体现 CodeArts + Skills 快速部署；
- 需要自动创建 ECS、EIP、安全组并发布应用；
- 答辩前需要部署报告和健康检查证据。

## 前置条件

- 已安装官方 auto-deploy Skill：
  `https://gitcode.com/weixin_43883336/auto-deploy`
- 已配置华为云 AK/SK 环境变量；
- 已准备 RDS、Redis、OBS、MaaS，并填好 `.env`；
- 本机具备 Python 3.10+、Bash、Terraform 1.8+、Git、SSH/SCP。

## 输入变量

```text
APP_NAME=jiuyu-yundang-demo
REGION=cn-north-4
FLAVOR_TIER=small
PORT=3000
START_CMD=node apps/api/server.js
ENV_FILE=.env
```

## 指令

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

部署完成后依次检查：
- /api/health
- /api/status
- /api/heritages?pageSize=1
- /api/chat

输出公网访问地址、资源清单、.auto-deploy 产物列表和部署报告。
```

## 期望输出

- 公网访问地址；
- ECS、EIP、安全组、VPC/子网、KPS keypair 清单；
- `.auto-deploy/analysis.json`、`deployment-plan.md`、`deployment-test-report.md`；
- `/api/status` 截图说明；
- 可粘贴到答辩 PPT 的部署结果描述。

## 边界说明

auto-deploy 不创建 RDS、Redis、OBS、MaaS；这些外部服务需提前准备并通过 `.env` 注入。比赛材料提交前不要执行资源清理。
