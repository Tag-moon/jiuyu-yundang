#!/usr/bin/env python3
import argparse
import json
import re
import time
from pathlib import Path
from typing import Optional


FLAVOR_TIERS = {
    "small": "s6.large.2",         # 2 vCPU, 4 GB  — default for non-Java
    "standard": "s6.large.2",      # 2 vCPU, 4 GB  — same as small (alias)
    "performance": "s6.xlarge.2",  # 4 vCPU, 8 GB  — default for Java/Spring
}

# Target specs for default flavors (used by resolve_flavor for fallback matching)
FLAVOR_TARGETS = {
    "s6.large.2":   {"vcpus": 2, "ram_mb": 4096},   # 2C4G
    "s6.xlarge.2":  {"vcpus": 4, "ram_mb": 8192},   # 4C8G
}

# Minimum acceptable specs — reject flavors smaller than this
MIN_ACCEPTABLE_VCPUS = 2
MIN_ACCEPTABLE_RAM_MB = 2048  # 2 GB


def slug(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9-]+", "-", value.strip().lower()).strip("-") or "app"


def flavor_for(analysis: dict, tier: Optional[str] = None) -> str:
    """Return an ECS flavor name.

    When *tier* is given (minimal / small / standard / performance) it takes
    precedence over the automatic project-type-based selection so callers can
    honour user requests such as "最便宜" → minimal.
    """
    if tier and tier in FLAVOR_TIERS:
        return FLAVOR_TIERS[tier]

    modules = analysis.get("modules") or {}
    backend = modules.get("backend") or {}
    if (
        analysis.get("project_type") == "java"
        or str(analysis.get("framework", "")).startswith("spring")
        or backend.get("project_type") == "java"
        or str(backend.get("framework", "")).startswith("spring")
    ):
        return "s6.xlarge.2"
    if analysis.get("project_type") in {"nodejs", "python", "go", "dotnet", "rust"}:
        return "s6.large.2"
    return "s6.large.2"


def image_for(analysis: dict) -> str:
    strategy = str(analysis.get("deploy_strategy") or "")
    if strategy in {"docker", "docker-compose"}:
        return "^Ubuntu 22.04.*"
    return "Ubuntu 22.04 server 64bit"


def optional_resource_recommendations(args: argparse.Namespace) -> dict:
    return {}


def bandwidth_for(analysis: dict, explicit_bandwidth: Optional[int]) -> int:
    if explicit_bandwidth is not None:
        return explicit_bandwidth
    strategy = str(analysis.get("deploy_strategy") or "")
    if strategy in {"docker", "docker-compose"}:
        return 200
    return 5


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate Huawei Cloud resource requirements JSON.")
    parser.add_argument("--analysis", required=True)
    parser.add_argument("--plan", help="Accepted for workflow traceability; generation uses analysis JSON.")
    parser.add_argument("--app-name")
    parser.add_argument("--region", default="cn-north-4")
    parser.add_argument("--availability-zone")
    parser.add_argument("--bandwidth", type=int)
    parser.add_argument("--disk-size", type=int, default=40)
    parser.add_argument("--flavor-tier", choices=list(FLAVOR_TIERS), help="Override ECS flavor by tier: minimal/small/standard/performance.")
    parser.add_argument("--domain")
    parser.add_argument("--network-mode", choices=["create", "reuse"], default="create")
    parser.add_argument("--existing-vpc-id")
    parser.add_argument("--existing-subnet-id")
    parser.add_argument("--app-port", type=int)
    parser.add_argument("--no-http", action="store_true")
    parser.add_argument("--no-https", action="store_true")
    parser.add_argument("--public-cidr", default="0.0.0.0/0", help="CIDR allowed to reach the application port.")
    parser.add_argument("--ssh-cidr", default="auto-detected-public-ip/32")
    parser.add_argument("--node-version")
    parser.add_argument("--provided-env-key", action="append", default=[], help="Application env key supplied by --env or --env-file; values are never stored.")
    parser.add_argument("--allow-missing-env", action="store_true", help="Mark missing analyzed env vars as explicitly allowed.")
    parser.add_argument("--ssh-key-info", help="JSON from prepare_ssh_key.py; embeds keypair name and public key for bundled Terraform provisioning.")
    parser.add_argument("--output")
    args = parser.parse_args()

    if args.network_mode == "reuse" and (not args.existing_vpc_id or not args.existing_subnet_id):
        raise SystemExit("--network-mode reuse requires --existing-vpc-id and --existing-subnet-id")

    analysis = json.loads(Path(args.analysis).read_text(encoding="utf-8-sig"))
    ssh_key = json.loads(Path(args.ssh_key_info).read_text(encoding="utf-8-sig")) if args.ssh_key_info else {}
    app_name = slug(args.app_name or analysis.get("app_name") or Path(analysis.get("project_root", "app")).name)
    app_port = int(args.app_port or analysis.get("listen_port") or 8080)
    strategy = analysis.get("deploy_strategy")
    required_env = sorted({str(key) for key in analysis.get("required_env_vars") or [] if key})
    provided_env = sorted({str(key) for key in args.provided_env_key or [] if key})
    missing_env = sorted(key for key in required_env if key not in provided_env)
    bandwidth = bandwidth_for(analysis, args.bandwidth)
    uses_nginx_by_default = bool(args.domain or analysis.get("has_frontend_backend_split"))
    open_http = (not args.no_http) and uses_nginx_by_default
    open_https = (not args.no_https) and bool(args.domain)
    ingress_ports = [22]
    if open_http:
        ingress_ports.append(80)
    if open_https:
        ingress_ports.append(443)
    if app_port not in ingress_ports:
        ingress_ports.append(app_port)

    rules = [
        {"direction": "ingress", "protocol": "tcp", "port": 22, "source": args.ssh_cidr, "description": "SSH"},
    ]
    if open_http:
        rules.append({"direction": "ingress", "protocol": "tcp", "port": 80, "source": "0.0.0.0/0", "description": "HTTP"})
    if open_https:
        rules.append({"direction": "ingress", "protocol": "tcp", "port": 443, "source": "0.0.0.0/0", "description": "HTTPS"})
    if app_port not in (22, 80, 443):
        rules.append({"direction": "ingress", "protocol": "tcp", "port": app_port, "source": args.public_cidr, "description": "Application"})
    rules.append({"direction": "egress", "protocol": "all", "source": "0.0.0.0/0", "description": "Allow all egress"})

    vpc = {
        "mode": args.network_mode,
        "cidr": "10.254.0.0/16",
        "subnet_cidr": "10.254.1.0/24",
        "subnet_gateway_ip": "10.254.1.1",
    }
    if args.network_mode == "reuse":
        vpc.update(
            {
                "existing_vpc_id": args.existing_vpc_id,
                "existing_subnet_id": args.existing_subnet_id,
            }
        )

    spec = {
        "provider": "huaweicloud",
        "region": args.region,
        "network_mode": args.network_mode,
        "resources": {
            "ecs": {
                "count": 1,
                "flavor": flavor_for(analysis, args.flavor_tier),
                "flavor_validation": "validated by bundled Terraform plan against Huawei Cloud provider",
                "image": image_for(analysis),
                "image_validation": "resolved by bundled Terraform data.huaweicloud_images_image",
                "disk_size_gb": args.disk_size,
                "disk_type": "SSD",
                "availability_zone": args.availability_zone or f"{args.region}a",
                "availability_zone_validation": "resolved before Terraform when possible; validated by bundled Terraform plan",
                "eip": True,
                "bandwidth_size_mbps": bandwidth,
                "ssh_key_name": ssh_key.get("ssh_key_name") or f"auto-deploy-key-{int(time.time())}",
                "ssh_public_key": ssh_key.get("ssh_public_key"),
            },
            "security_group": {
                "name": f"auto-deploy-sg-{app_name}",
                "rules": rules,
                "open_http": open_http,
                "open_https": open_https,
                "app_public_cidr": args.public_cidr,
            },
            "vpc": vpc,
        },
        "optional_resources": optional_resource_recommendations(args),
        "deployment_context": {
            "app_name": app_name,
            "app_port": app_port,
            "deploy_strategy": strategy,
            "health_endpoint": analysis.get("health_endpoint", "/"),
            "node_version": args.node_version,
            "requires_post_apply_resource_info": True,
            "env": {
                "required_env_keys": required_env,
                "provided_env_keys": provided_env,
                "missing_env_keys": missing_env,
                "allow_missing_env": bool(args.allow_missing_env),
                "risk": bool(missing_env and args.allow_missing_env),
            },
        },
    }
    text = json.dumps(spec, ensure_ascii=False, indent=2)
    if args.output:
        Path(args.output).write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0


# ---------------------------------------------------------------------------
# Resource resolution: AZ and flavor fallback logic
# ---------------------------------------------------------------------------

def resolve_az(desired_az: str, available_azs: list[str]) -> tuple[str, str]:
    """Resolve availability zone against available list.

    Returns (resolved_az, reason).
    - Exact match → use it.
    - Not found but list non-empty → use first available.
    - Empty list → return desired (let Terraform error).
    """
    if not available_azs:
        return desired_az, "no_az_list_available"
    if desired_az in available_azs:
        return desired_az, "exact_match"
    return available_azs[0], f"fallback_from_{desired_az}"


def _flavor_score(target: dict, candidate: dict) -> float:
    """Distance score: lower is better. CPU weighted 2x, RAM by ratio."""
    vcpu_diff = abs(candidate["vcpus"] - target["vcpus"])
    ram_ratio = max(candidate["ram_mb"], 1) / max(target["ram_mb"], 1)
    ram_penalty = abs(ram_ratio - 1.0)
    return vcpu_diff * 2.0 + ram_penalty


def find_closest_flavor(target_vcpus: int, target_ram_mb: int, available: list[dict]) -> dict | None:
    """Find the closest acceptable flavor from available list.

    Rules:
    - Reject flavors below MIN_ACCEPTABLE_VCPUS or MIN_ACCEPTABLE_RAM_MB.
    - Prefer exact vcpus+ram match.
    - Otherwise pick lowest score (closest in CPU and RAM).
    - Tie-break: fewer vCPus (cheaper) wins.
    """
    candidates = [
        f for f in available
        if f["vcpus"] >= MIN_ACCEPTABLE_VCPUS and f["ram_mb"] >= MIN_ACCEPTABLE_RAM_MB
    ]
    if not candidates:
        return None

    target = {"vcpus": target_vcpus, "ram_mb": target_ram_mb}
    # Exact match first
    for f in candidates:
        if f["vcpus"] == target_vcpus and f["ram_mb"] == target_ram_mb:
            return f
    # Closest by score
    candidates.sort(key=lambda f: (_flavor_score(target, f), f["vcpus"]))
    return candidates[0]


def resolve_flavor(desired_flavor: str, available_flavors: list[dict]) -> tuple[str, str]:
    """Resolve ECS flavor against available list.

    Returns (resolved_flavor_name, reason).
    - Exact name match → use it.
    - Same vcpus+ram from another series → use it.
    - Closest acceptable flavor → use it.
    - Nothing acceptable → return desired (let Terraform error).
    """
    if not available_flavors:
        return desired_flavor, "no_flavor_list_available"

    # 1. Exact name match
    for f in available_flavors:
        if f["name"] == desired_flavor:
            return desired_flavor, "exact_match"

    # 2. Same specs from another series
    target = FLAVOR_TARGETS.get(desired_flavor)
    if target:
        for f in available_flavors:
            if f["vcpus"] == target["vcpus"] and f["ram_mb"] == target["ram_mb"]:
                return f["name"], f"same_spec_as_{desired_flavor}"

    # 3. Closest acceptable
    if target:
        closest = find_closest_flavor(target["vcpus"], target["ram_mb"], available_flavors)
        if closest:
            return closest["name"], f"closest_to_{desired_flavor}"

    # 4. Fallback — let Terraform handle it
    return desired_flavor, "no_acceptable_alternative"


if __name__ == "__main__":
    raise SystemExit(main())
