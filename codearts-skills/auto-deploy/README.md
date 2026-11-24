# auto-deploy

> 🇨🇳 中文 | 🇬🇧 [English (展开查看)](#english)

---

`auto-deploy` 是华为云单机 ECS Web 应用一键部署技能。专注于一台机器的部署场景，集群、高可用、多资源生产架构不在范围内。

核心流程极简：

1. 分析代码仓库
2. 生成部署计划
3. 用内置 Terraform 创建一台 ECS
4. 通过 SSH 上传源码
5. 启动应用并验证健康

## 主命令

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --region cn-north-4 --yes
```

## 常用变体

仅生成计划（不实际部署）：

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --region cn-north-4 --plan-only
```

仅校验 Terraform：

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --region cn-north-4 --validate-only --skip-preflight
```

复用已有 VPC/子网：

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --network-mode reuse --existing-vpc-id <vpc-id> --existing-subnet-id <subnet-id> --yes
```

限制端口：

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --app-port 8081 --no-http --no-https --public-cidr 203.0.113.10/32 --ssh-cidr 198.51.100.7/32 --yes
```

基础设施已存在，从失败处恢复部署：

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --workdir /path/to/app/.auto-deploy --resume-from deploy --skip-prepare --skip-upload
```

Docker 冷构建首次较慢（大镜像通过 EIP 拉取）。Docker / Docker Compose 部署默认 `200 Mbps` EIP 带宽，原生部署保持 `5 Mbps`。Docker 构建超时默认 `2400` 秒，可覆盖：

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --docker-build-timeout 3600 --yes
```

注入应用配置（不上传 `.env` 文件）：

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --env DATABASE_URL=postgres://... --env JWT_SECRET=... --yes
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --env-file ./deploy.env --yes
```

如果分析检测到必需变量且使用了 `--yes`，缺失的变量会快速失败。仅在确认接受风险时使用 `--allow-missing-env`。

## 支持的部署路径

- `native`：Node.js、Python、Java、Go、Rust、.NET 等可识别的原生 Web 应用优先使用。
- `docker-compose`：仓库自带 Compose 文件时使用。
- `docker`：仅容器优先且无明确原生运行时检测到时使用。

前后端分离项目应使用 Docker Compose。原生分离部署默认阻止，需显式 `--allow-native-fullstack` 覆盖。

以下已从主路径移除：

- 制品原生降级
- 纯静态专用部署器
- Kubernetes 部署器
- 集群或多 ECS 部署
- RDS/Redis/OBS/MQ/ELB/CCE/Kubernetes 技栈

外部数据库、Redis、队列、对象存储等请单独准备，然后通过 `--env` 或 `--env-file` 注入连接信息。报告和摘要文件只显示环境变量名，不显示值。

SSH 入场默认限定检测到的控制机公网 IP `/32`。若公网 IP 检测失败，需显式提供 `--ssh-cidr x.x.x.x/32`；仅在有意开放 SSH 到公网时使用 `--ssh-cidr 0.0.0.0/0`。

## ECS 规格 Tiers

技能根据项目类型自动选择 ECS 规格（Java/Spring → 4C8G，其他 → 2C4G）。可用 `--flavor-tier` 覆盖：

| Tier | Flavor | 配置 | 适用场景 |
|------|--------|------|----------|
| `small` | `s6.large.2` | 2 vCPU, 4 GB | 非Java应用默认 |
| `standard` | `s6.large.2` | 2 vCPU, 4 GB | small 别名 |
| `performance` | `s6.xlarge.2` | 4 vCPU, 8 GB | Java/Spring 默认；重负载 |

### 资源可用性预检

Terraform apply 之前，技能会查询目标区域的可用可用区（AZ）和 ECS 规格：

1. **AZ 降级**：默认 AZ（`{region}a`）不可用时，自动降级到第一个可用 AZ。
2. **规格降级**：默认规格在选定 AZ 不可用时：
   - 先尝试同 CPU/RAM 的其他系列（如 `s6.large.2` → `s7.large.2`）。
   - 无精确匹配时，按加权距离评分（CPU × 2 + RAM 比率惩罚）选最近的可用规格。
   - 拒绝 2 vCPU / 2 GB RAM 以下的规格。
3. **优雅降级**：API 查询失败时不阻塞，继续用默认值，由 Terraform 报错。
4. 降级结果写入工作目录的 `resource-resolution.json`。

## 性能优化

- 预检在分析之后运行，原生部署跳过 Docker Hub 连通性检查。
- SSH 密钥按应用复用，使用 `ed25519` 算法，不再每次生成 `RSA 4096`。
- 区域/规格/镜像解析不再作为独立工作流阶段。
- VPC 冲突检测使用华为云 API 预检，不依赖 Terraform 报错。
- AZ 和规格可用性预检在 Terraform apply 前运行，自动降级到最近的可用规格。
- 部署不再做重复的 Docker 预装和降级编排。
- 失败恢复可从 `deploy` 或 `verify` 继续，无需重跑 Terraform。
- Docker 构建超时重试一次，复用已下载的层。
- 恢复/重试前将上次产物归档为 `*-attempt-N.*`，再覆盖标准输出。

## 输出产物

每次运行写入 `<repo>/.auto-deploy` 目录下：

- `analysis.json` — 项目分析结果
- `resource-spec.json` — 资源规格
- `resource-resolution.json` — AZ/规格降级记录
- `deployment-plan.md` — 部署计划
- `timings.json` — 各阶段耗时
- `run-summary.json` — 运行摘要
- `deployment-test-report.md` — 部署测试报告

## 清理

```bash
python scripts/destroy.py --workdir .auto-deploy/terraform
```

仅通过记录的 Terraform 工作目录销毁资源。

---

<details>
<summary><h2 id="english">🇬🇧 English</h2></summary>

`auto-deploy` is a simplified Huawei Cloud single-ECS web app deployment skill.
It is scoped to one-machine deployments. Clustered, high-availability, and
multi-resource production architectures are intentionally outside this skill.

It is intentionally optimized for the shortest successful path:

1. Analyze the repo.
2. Generate a small deployment plan.
3. Provision one ECS with bundled Terraform.
4. Upload source code over SSH.
5. Start the app and verify health.

## Main Command

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --region cn-north-4 --yes
```

## Common Variants

Plan only:

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --region cn-north-4 --plan-only
```

Validate Terraform only:

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --region cn-north-4 --validate-only --skip-preflight
```

Reuse an existing VPC/subnet:

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --network-mode reuse --existing-vpc-id <vpc-id> --existing-subnet-id <subnet-id> --yes
```

Restrict ports:

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --app-port 8081 --no-http --no-https --public-cidr 203.0.113.10/32 --ssh-cidr 198.51.100.7/32 --yes
```

Resume a failed deploy after infrastructure already exists:

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --workdir /path/to/app/.auto-deploy --resume-from deploy --skip-prepare --skip-upload
```

Docker cold builds can take longer on first deploy because large base images are
pulled through the ECS EIP. Docker and Docker Compose deployments default to a
`200 Mbps` EIP bandwidth recommendation, while native deployments keep the
lighter `5 Mbps` default. Docker build timeout defaults to `2400` seconds and can
be overridden:

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --docker-build-timeout 3600 --yes
```

Inject application configuration without uploading `.env`:

```bash
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --env DATABASE_URL=postgres://... --env JWT_SECRET=... --yes
python scripts/auto_deploy.py --repo /path/to/app --app-name demo-api --env-file ./deploy.env --yes
```

If analysis detects required variables and `--yes` is used, missing keys fail
fast. Use `--allow-missing-env` only when you accept the deployment risk.

## Supported Deploy Paths

- `native`: preferred for recognizable Node.js, Python, Java, Go, Rust, and .NET web apps.
- `docker-compose`: used when the repo explicitly ships a Compose app.
- `docker`: used only when the repo is container-first and no clear native runtime was detected.

Frontend/backend split projects should use Docker Compose. Native split
deployment is blocked by default; `--allow-native-fullstack` is an explicit
override for simple projects.

Removed from the main path:

- Artifact-native fallback
- Static-only special deployer
- Kubernetes deployer
- Clustered or multi-ECS deployment
- RDS/Redis/OBS/MQ/ELB/CCE/Kubernetes stacks

Prepare external databases, Redis, queues, or object storage separately, then
inject their connection values with `--env` or `--env-file`. Reports and summary
files show env key names only, never values.

SSH ingress defaults to the detected control-machine public IP `/32`. If public
IP detection fails, provide `--ssh-cidr x.x.x.x/32`; use
`--ssh-cidr 0.0.0.0/0` only when intentionally opening SSH to the internet.

## ECS Flavor Tiers

The skill automatically selects an ECS flavor based on project type (Java/Spring → 4C8G, others → 2C4G). Override with `--flavor-tier`:

| Tier | Flavor | Spec | Use case |
|------|--------|------|----------|
| `small` | `s6.large.2` | 2 vCPU, 4 GB | Default for non-Java apps |
| `standard` | `s6.large.2` | 2 vCPU, 4 GB | Alias of `small` |
| `performance` | `s6.xlarge.2` | 4 vCPU, 8 GB | Default for Java/Spring; heavier workloads |

### Resource availability pre-check

Before Terraform apply, the skill queries the target region for available availability zones and ECS flavors:

1. **AZ resolution**: If the default AZ (`{region}a`) is unavailable, falls back to the first available AZ.
2. **Flavor resolution**: If the default flavor is unavailable in the selected AZ:
   - Tries the same CPU/RAM spec from another flavor series (e.g. `s6.large.2` → `s7.large.2`).
   - If no exact match, picks the closest acceptable flavor by a weighted distance score (CPU × 2 + RAM ratio penalty).
   - Rejects any flavor below 2 vCPU or 2 GB RAM.
3. **Graceful degradation**: If the API query fails, proceeds with defaults and lets Terraform report the error.
4. Resolution results are written to `resource-resolution.json` in the work directory.

## Why It Is Faster Now

- Preflight runs after analysis and skips Docker Hub checks for native apps.
- SSH keys are reused and generated as `ed25519`, not regenerated as timestamped `RSA 4096`.
- Region/flavor/image resolution no longer runs as a separate workflow stage.
- VPC conflict handling uses a direct Huawei Cloud API precheck before apply.
- AZ and flavor availability precheck runs before Terraform apply, automatically falling back to the closest available spec.
- Deploy no longer does duplicate Docker pre-install plus fallback orchestration.
- Failed deploy recovery can resume from `deploy` or `verify` without rerunning Terraform.
- Docker build timeouts retry once to reuse partially downloaded layers.
- Previous timing/report files are archived as `*-attempt-N.*` before a resume overwrites canonical outputs.

## Outputs

Each run writes under `<repo>/.auto-deploy`:

- `analysis.json` — project analysis result
- `resource-spec.json` — resource specification
- `resource-resolution.json` — AZ/flavor resolution record
- `deployment-plan.md` — deployment plan
- `timings.json` — per-stage timing
- `run-summary.json` — run summary
- `deployment-test-report.md` — deployment test report

## Cleanup

```bash
python scripts/destroy.py --workdir .auto-deploy/terraform
```

Destroy only through the recorded Terraform workdir.

</details>
