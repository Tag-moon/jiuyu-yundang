#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path


def slug(value: str) -> str:
    value = re.sub(r"[^a-zA-Z0-9-]+", "-", value.strip().lower()).strip("-")
    return value or "app"


def load_json(path: str) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def recommendation(analysis: dict) -> tuple[str, str, str]:
    project_type = analysis.get("project_type")
    framework = analysis.get("framework")
    backend = (analysis.get("modules") or {}).get("backend") or {}
    if (
        project_type == "java"
        or str(framework).startswith("spring")
        or backend.get("project_type") == "java"
        or str(backend.get("framework", "")).startswith("spring")
    ):
        return "4C8G", "s6.xlarge.2", "Java/Spring applications typically need more memory."
    return "2C4G", "s6.large.2", "Default ECS application sizing."


def security_lines(spec: dict, fallback_port: int) -> tuple[list[str], dict]:
    sg = ((spec.get("resources") or {}).get("security_group") or {}) if spec else {}
    rules = sg.get("rules") or []
    if not rules:
        rules = [
            {"direction": "ingress", "protocol": "tcp", "port": 22, "source": "auto-detected-public-ip/32", "description": "SSH"},
            {"direction": "ingress", "protocol": "tcp", "port": 80, "source": "0.0.0.0/0", "description": "HTTP"},
            {"direction": "ingress", "protocol": "tcp", "port": 443, "source": "0.0.0.0/0", "description": "HTTPS"},
            {"direction": "ingress", "protocol": "tcp", "port": fallback_port, "source": "0.0.0.0/0", "description": "Application"},
        ]
    ingress = [r for r in rules if r.get("direction") == "ingress"]
    by_desc = {str(r.get("description", "")).lower(): r for r in ingress}
    http = by_desc.get("http")
    https = by_desc.get("https")
    app = by_desc.get("application")
    ssh = by_desc.get("ssh")
    lines = [
        f"- SSH CIDR: `{(ssh or {}).get('source', 'auto-detected-public-ip/32')}`",
        f"- HTTP 80 open: `{'yes' if http else 'no'}`",
        f"- HTTPS 443 open: `{'yes' if https else 'no'}`",
        f"- Application port: `{(app or {}).get('port', fallback_port)}` from `{(app or {}).get('source', '0.0.0.0/0')}`",
    ]
    summary = {
        "rules": rules,
        "ssh_cidr": (ssh or {}).get("source"),
        "http_open": bool(http),
        "https_open": bool(https),
        "app_port": (app or {}).get("port", fallback_port),
        "app_public_cidr": (app or {}).get("source", "0.0.0.0/0"),
    }
    return lines, summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate an auto-deploy plan from analysis JSON.")
    parser.add_argument("--analysis", required=True)
    parser.add_argument("--app-name")
    parser.add_argument("--domain")
    parser.add_argument("--region", default="cn-north-4")
    parser.add_argument("--resource-spec")
    parser.add_argument("--template", default="ecs-web")
    parser.add_argument("--app-port", type=int)
    parser.add_argument("--no-http", action="store_true")
    parser.add_argument("--no-https", action="store_true")
    parser.add_argument("--public-cidr", default="0.0.0.0/0")
    parser.add_argument("--ssh-cidr", default="auto-detected-public-ip/32")
    parser.add_argument("--network-mode", choices=["create", "reuse"], default="create")
    parser.add_argument("--existing-vpc-id")
    parser.add_argument("--existing-subnet-id")
    parser.add_argument("--provided-env-key", action="append", default=[])
    parser.add_argument("--allow-missing-env", action="store_true")
    parser.add_argument("--output")
    args = parser.parse_args()

    analysis = load_json(args.analysis)
    spec = load_json(args.resource_spec) if args.resource_spec else {}
    app_name = slug(args.app_name or Path(analysis.get("project_root", "app")).name)
    fallback_size, fallback_flavor, reason = recommendation(analysis)
    resources = spec.get("resources") or {}
    ecs = resources.get("ecs") or {}
    sg = resources.get("security_group") or {}
    vpc = resources.get("vpc") or {}
    context = spec.get("deployment_context") or {}
    env_report = context.get("env") or {
        "required_env_keys": sorted({str(key) for key in analysis.get("required_env_vars") or [] if key}),
        "provided_env_keys": sorted({str(key) for key in args.provided_env_key or [] if key}),
        "missing_env_keys": [],
        "allow_missing_env": bool(args.allow_missing_env),
        "risk": False,
    }
    env_report["missing_env_keys"] = sorted(
        key for key in env_report.get("required_env_keys", []) if key not in set(env_report.get("provided_env_keys", []))
    )
    env_report["risk"] = bool(env_report["missing_env_keys"] and env_report.get("allow_missing_env"))
    port = int(args.app_port or context.get("app_port") or analysis.get("listen_port") or 8080)
    strategy = context.get("deploy_strategy") or analysis.get("deploy_strategy", "native")
    needs_nginx = bool(args.domain) or port in (80, 443) or strategy == "docker-compose" or analysis.get("has_frontend_backend_split")
    env_vars = analysis.get("required_env_vars") or []
    security_text, security_summary = security_lines(spec, port)
    network_mode = spec.get("network_mode") or args.network_mode
    region = spec.get("region") or args.region
    disk_type = ecs.get("disk_type") or "SSD"
    disk_size = ecs.get("disk_size_gb") or 40
    bandwidth = ecs.get("bandwidth_size_mbps") or 5
    bandwidth_charge_mode = ecs.get("bandwidth_charge_mode") or "traffic"
    flavor = ecs.get("flavor") or fallback_flavor
    image = ecs.get("image") or "Ubuntu 22.04 server 64bit"
    availability_zone = ecs.get("availability_zone") or f"{region}a"
    ecs_size = f"{ecs.get('count', 1)} instance"

    resource_summary = {
        "provider": "huaweicloud",
        "region": region,
        "app_name": app_name,
        "template": args.template,
        "ecs": {
            "count": ecs.get("count", 1),
            "size": fallback_size if not ecs else "from resource-spec.json",
            "flavor": flavor,
            "image": image,
            "availability_zone": availability_zone,
            "system_disk_type": disk_type,
            "system_disk_gb": disk_size,
            "bandwidth_mbps": bandwidth,
            "bandwidth_charge_mode": bandwidth_charge_mode,
        },
        "network": {
            "mode": network_mode,
            "existing_vpc_id": vpc.get("existing_vpc_id") or args.existing_vpc_id,
            "existing_subnet_id": vpc.get("existing_subnet_id") or args.existing_subnet_id,
            "vpc_cidr": vpc.get("cidr"),
            "subnet_cidr": vpc.get("subnet_cidr"),
            "ingress_ports": sorted({int(r.get("port")) for r in security_summary["rules"] if r.get("direction") == "ingress" and str(r.get("port", "")).isdigit()}),
            "security": security_summary,
            "domain": args.domain,
            "nginx_reverse_proxy": needs_nginx,
        },
        "deployment": {
            "strategy": strategy,
            "build_command": analysis.get("build_command"),
            "start_command": analysis.get("start_command"),
            "health_endpoint": analysis.get("health_endpoint", "/"),
            "env": env_report,
        },
    }

    document = f"""# Deployment Plan: {app_name}

## Project Analysis

- Type: `{analysis.get('project_type')}` / `{analysis.get('framework')}`
- Runtime: `{analysis.get('runtime')}`
- Strategy: `{strategy}`
- Port: `{port}`
- Health endpoint: `{analysis.get('health_endpoint', '/')}`
- Required env vars: `{', '.join(env_vars) if env_vars else 'none detected'}`
- Provided env keys: `{', '.join(env_report.get('provided_env_keys') or []) or 'none'}`
- Missing env keys: `{', '.join(env_report.get('missing_env_keys') or []) or 'none'}`
- Missing env override: `{'enabled' if env_report.get('allow_missing_env') else 'disabled'}`

## Cloud Resource Recommendation

- Region: `{region}`
- Availability zone: `{availability_zone}`
- ECS: `{ecs_size}` (`{flavor}`)
- Image: `{image}`
- Reason: {reason}
- Disk: `{disk_size}GB {disk_type}`
- EIP bandwidth: `{bandwidth} Mbps`
- Bandwidth charge mode: `{bandwidth_charge_mode}`

## Network Plan

- Network mode: `{network_mode}`
- VPC/subnet create or reuse: `{'reuse existing' if network_mode == 'reuse' else 'create new'}`
- Existing VPC/Subnet: `{(vpc.get('existing_vpc_id') or args.existing_vpc_id or 'not used')}` / `{(vpc.get('existing_subnet_id') or args.existing_subnet_id or 'not used')}`
- Open ingress ports only: `{', '.join(map(str, resource_summary['network']['ingress_ports']))}`
{chr(10).join(security_text)}
- Security group ingress rules:

```json
{json.dumps([rule for rule in security_summary['rules'] if rule.get('direction') == 'ingress'], ensure_ascii=False, indent=2)}
```
- Nginx reverse proxy: `{'yes' if needs_nginx else 'no'}`
- Domain/HTTPS: `{args.domain or 'not requested'}`

## Persistence and Backup

- Application source is deployed under `/opt/auto-deploy/{app_name}`.
- Existing deployment directories are backed up before replacement.
- Database or upload volumes were not inferred unless present in compose files; confirm manually if required.

## Cost Drivers

- ECS flavor, EIP bandwidth, and system disk size.
- Exact pricing must be confirmed in Huawei Cloud for the selected region and billing mode.

## Risks and Mitigations

- Port conflict: verify with `ss -tlnp` before service start.
- Resource pressure: monitor memory and disk after launch; upgrade if usage exceeds 80%.
- Dependency install failure: retry with configured China mirrors and show install logs.
- Health check failure: collect recent logs and run rollback.

## Resource Summary JSON

```json
{json.dumps(resource_summary, ensure_ascii=False, indent=2)}
```

Proceed only after explicit user confirmation (`y`/`yes`).
"""
    if args.output:
        Path(args.output).write_text(document, encoding="utf-8")
    print(document)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
