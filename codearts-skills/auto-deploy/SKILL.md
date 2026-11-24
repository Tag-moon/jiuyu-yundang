---
name: auto-deploy
description: Analyze a web application repository, provision one Huawei Cloud ECS with bundled Terraform, copy the code over SSH, start the app, verify health, and destroy only Terraform state-managed resources when cleanup is requested. Use when the user wants the shortest path to a single-machine web app deployment on ECS.
---

# Auto Deploy

Use this skill for a fast single-ECS deployment. The workflow is intentionally narrow:

1. Analyze the repo.
2. Generate a plan.
3. Provision one ECS.
4. Upload code.
5. Start the app.
6. Verify health.

Primary entry point:

```bash
python scripts/auto_deploy.py --repo <repo> --app-name <name> --region cn-north-4 --yes
```

## Scope

This skill now targets only single-machine ECS web app deployment.
It is not a general cloud architecture deployer. Complex multi-node, clustered,
or multi-service production topologies should be handled by a separate plan/tool.

In scope:

- Native deployment for recognizable Node.js, Python, Java, Go, Rust, and .NET apps.
- Docker Compose deployment when the repo explicitly depends on Compose.
- Dockerfile deployment only for container-first repos without a clear native runtime.
- ECS with either a new VPC/subnet or a reused existing VPC/subnet.

Out of scope:

- Kubernetes deployment
- CCE or any clustered deployment
- Multi-ECS, load-balanced, or high-availability topology
- Complex projects that require coordinated database, queue, cache, object storage, or private network architecture
- Artifact-native fallback
- Static-only special deployers
- RDS/Redis/OBS/MQ/ELB/CCE/Kubernetes stacks

## Safety Rules

- Never write AK/SK, SSH private keys, secrets, or real `.env` values into generated files.
- Read credentials from `HW_ACCESS_KEY`/`HW_SECRET_KEY` or `HUAWEICLOUD_ACCESS_KEY`/`HUAWEICLOUD_SECRET_KEY`.
- Provision only through bundled Terraform under `templates/terraform/ecs-web` and `templates/terraform/ecs-web-existing-network`.
- Open only required ingress ports.
- Destroy resources only with `python scripts/destroy.py --workdir <terraform-workdir>`.

## Main Commands

```bash
python scripts/auto_deploy.py --repo <repo> --app-name <name> --region cn-north-4 --plan-only
python scripts/auto_deploy.py --repo <repo> --app-name <name> --region cn-north-4 --validate-only --skip-preflight
python scripts/auto_deploy.py --repo <repo> --app-name <name> --workdir <repo>/.auto-deploy --resume-from deploy --skip-prepare --skip-upload
python scripts/auto_deploy.py --repo <repo> --app-name <name> --docker-build-timeout 3600 --yes
python scripts/auto_deploy.py --repo <repo> --app-name <name> --env DATABASE_URL=... --env-file ./deploy.env --yes
python scripts/self_check.py
```

## Key Behavior

- Preflight runs after analysis, so native deployments skip Docker Hub connectivity checks.
- SSH keys are reused per app and generated as `ed25519`.
- SSH port 22 defaults to the detected control-machine public IP `/32`; if detection fails, require explicit `--ssh-cidr`.
- Explicit `--ssh-cidr 0.0.0.0/0` is required for intentionally internet-open SSH.
- Application config is injected with `--env KEY=VALUE` and/or `--env-file PATH`; `.env` files are not uploaded by default.
- Reports show configured env key names only, never values.
- Native deployment is preferred whenever a clear runtime/start path is detected.
- Frontend/backend split projects should use Docker Compose. Native split deployment is blocked by default unless `--allow-native-fullstack` is explicitly supplied.
- VPC conflict avoidance uses a direct Huawei Cloud API precheck before Terraform apply.
- The deploy step no longer chains fallback strategies.
- A failed deploy can resume from `deploy` or `verify` without re-running Terraform.
- Docker and Docker Compose deployments default to `200 Mbps` EIP bandwidth; native deployments keep the lighter default.
- Docker build timeout defaults to `2400` seconds and retries once after timeout to reuse partially pulled layers.
- Previous run artifacts are archived as attempt files before retry or resume overwrites canonical outputs.

## ECS Flavor Tiers

The skill automatically selects an ECS flavor based on project type (Java/Spring → 4C8G, others → 2C4G). You can override this with `--flavor-tier`:

| Tier | Flavor | Spec | Use case |
|------|--------|------|----------|
| `small` | `s6.large.2` | 2 vCPU, 4 GB | Default for non-Java apps |
| `standard` | `s6.large.2` | 2 vCPU, 4 GB | Alias of `small` |
| `performance` | `s6.xlarge.2` | 4 vCPU, 8 GB | Default for Java/Spring; heavier workloads |

### Resource availability pre-check

Before Terraform apply, the skill queries the target region for available availability zones and ECS flavors:

1. **AZ resolution**: If the default AZ (`{region}a`) is not available, automatically falls back to the first available AZ.
2. **Flavor resolution**: If the default flavor is not available in the selected AZ:
   - First tries the same CPU/RAM spec from another flavor series (e.g. `s6.large.2` → `s7.large.2`).
   - If no exact match, picks the closest acceptable flavor by a weighted distance score (CPU × 2 + RAM ratio penalty).
   - Rejects any flavor below 2 vCPU or 2 GB RAM.
3. **Graceful degradation**: If the API query fails, proceeds with defaults and lets Terraform report the error.
4. Resolution results are written to `resource-resolution.json` in the work directory.

### Natural-language keyword mapping

When the user mentions "性能" / "高配" / "performance" / "production" / "heavy", pass `--flavor-tier performance`.

`--flavor` (exact flavor name) takes precedence over `--flavor-tier` if both are given.

## Workflow

1. `analyze.sh` writes `analysis.json`.
2. `prepare_ssh_key.py` writes reusable SSH key metadata.
3. `resource_spec.py` writes `resource-spec.json`.
4. `plan.py` writes `deployment-plan.md`.
5. `provision.py` runs `terraform fmt`, `init`, `validate`, `plan`, and optional `apply`.
6. `deploy.sh` waits for SSH, uploads code, and calls one deployer.
7. `verify.sh` checks process/container state, listening port, and HTTP health.
8. Reports are written to `.auto-deploy`.

## Application Environment

- Use `--env KEY=VALUE` for individual application settings; repeat it for multiple keys.
- Use `--env-file PATH` for dotenv-format configuration.
- If analysis detects required keys such as `DATABASE_URL`, `REDIS_URL`, `JWT_SECRET`, or `SPRING_DATASOURCE_URL`, provide them before plan/deploy.
- With `--yes`, missing required env keys fail fast unless `--allow-missing-env` is set.
- Native deployments write `/etc/auto-deploy/<app-name>.env` as root-owned mode `600` and reference it from systemd.
- Dockerfile deployments run containers with `--env-file`; Docker Compose deployments merge keys into remote `.env` without overwriting existing keys.

## External Dependencies

This skill does not create RDS, Redis, OBS, MQ, CCE, Kubernetes, ELB, or other supporting cloud services. Prepare required databases, caches, queues, or object storage separately and inject connection details through the environment mechanism above.

## Validation

```bash
python scripts/self_check.py
terraform fmt -check -recursive templates/terraform
```
