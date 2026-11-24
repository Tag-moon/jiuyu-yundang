#!/usr/bin/env bash
set -euo pipefail

SSH_CIDR=""
WORKDIR="."
ANALYSIS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-cidr) SSH_CIDR="$2"; shift 2 ;;
    --analysis) ANALYSIS="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: preflight.sh [--ssh-cidr CIDR] [--analysis analysis.json] [repo-or-workdir]" >&2
      exit 0
      ;;
    *) WORKDIR="$1"; shift ;;
  esac
done

python3 - "$WORKDIR" "$SSH_CIDR" "$ANALYSIS" <<'PY'
import ipaddress
import json
import os
import urllib.request
import shutil
import socket
import subprocess
import sys
from pathlib import Path

workdir = Path(sys.argv[1]).resolve()
ssh_cidr = sys.argv[2] or ""
analysis_path = Path(sys.argv[3]).resolve() if sys.argv[3] else None

def windows_user_env(name):
    if os.name != "nt":
        return None
    try:
        result = subprocess.run(
            ["powershell", "-NoProfile", "-Command", f"[Environment]::GetEnvironmentVariable('{name}', 'User')"],
            check=False,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None
    return result.stdout.strip() or None

def env_get(name):
    return os.environ.get(name) or windows_user_env(name)

def check_tool(name):
    path = shutil.which(name)
    return {"status": "pass" if path else "fail", "detail": path or f"{name} not found in PATH"}

def check_disk(path):
    usage = shutil.disk_usage(path)
    free_gb = usage.free / (1024 ** 3)
    return {"status": "pass" if free_gb > 1 else "fail", "detail": f"{free_gb:.2f} GB free"}

def check_credentials():
    required_pair = bool(env_get("HW_ACCESS_KEY")) and bool(env_get("HW_SECRET_KEY"))
    provider_pair = bool(env_get("HUAWEICLOUD_ACCESS_KEY")) and bool(env_get("HUAWEICLOUD_SECRET_KEY"))
    aliases = ["HUAWEICLOUD_ACCESS_KEY", "HUAWEICLOUD_SECRET_KEY", "OS_ACCESS_KEY", "OS_SECRET_KEY"]
    found_aliases = [k for k in aliases if env_get(k)]
    config_paths = [
        Path.home() / ".huaweicloud" / "credentials",
        Path.home() / ".hwcloud" / "credentials",
    ]
    found_files = [str(p) for p in config_paths if p.exists()]
    ok = required_pair or provider_pair or bool(found_files)
    return {
        "status": "pass" if ok else "fail",
        "detail": "Huawei Cloud credential environment variables or credential config present"
        if ok
        else {
            "message": "Set HW_ACCESS_KEY/HW_SECRET_KEY or HUAWEICLOUD_ACCESS_KEY/HUAWEICLOUD_SECRET_KEY before Terraform provisioning",
            "detected_alias_variables": found_aliases,
        },
    }

def check_network(host, port=443, timeout=5):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return {"status": "pass", "detail": f"connected to {host}:{port}"}
    except OSError as exc:
        return {"status": "fail", "detail": f"{host}:{port} unreachable: {exc}"}

def current_public_ip():
    for url in ("https://api.ipify.org", "https://ifconfig.me/ip"):
        try:
            with urllib.request.urlopen(url, timeout=6) as response:
                value = response.read().decode("utf-8").strip()
            ipaddress.ip_address(value)
            return value
        except Exception:
            continue
    return None


def check_dns(hostname):
    try:
        import socket
        socket.getaddrinfo(hostname, None)
        return {"status": "pass", "detail": f"resolved {hostname}"}
    except socket.gaierror as exc:
        return {"status": "warn", "detail": f"cannot resolve {hostname}: {exc}", "severity": "warning", "recommended_action": "Check /etc/resolv.conf on target ECS; consider adding nameserver 100.125.1.250 (Huawei Cloud internal DNS) or 8.8.8.8"}

def check_ssh_cidr():
    if not ssh_cidr:
        return {"status": "pass", "detail": "ssh CIDR not explicitly specified"}
    detected = current_public_ip()
    if not detected:
        return {"status": "fail", "detail": "could not detect current public IP for ssh CIDR validation"}
    try:
        network = ipaddress.ip_network(ssh_cidr, strict=False)
    except ValueError as exc:
        return {"status": "fail", "detail": f"invalid ssh CIDR {ssh_cidr}: {exc}"}
    ok = ipaddress.ip_address(detected) in network
    return {
        "status": "pass" if ok else "fail",
        "detail": f"current public IP {detected} {'matches' if ok else 'does not match'} {network}",
    }

def load_analysis():
    if not analysis_path or not analysis_path.exists():
        return {}
    try:
        return json.loads(analysis_path.read_text(encoding="utf-8-sig"))
    except Exception:
        return {}

analysis = load_analysis()
deploy_strategy = str(analysis.get("deploy_strategy") or "")

checks = {
    "huaweicloud_credentials": check_credentials(),
    "terraform": check_tool("terraform"),
    "ssh_keygen": check_tool("ssh-keygen"),
    "ssh": check_tool("ssh"),
    "scp": check_tool("scp"),
    "git": check_tool("git"),
    "disk_space": check_disk(workdir),
    "huaweicloud_api_network": check_network("iam.myhuaweicloud.com"),
    "terraform_provider_mirror_network": check_network("mirrors.huaweicloud.com"),
    "ssh_cidr_matches_current_ip": check_ssh_cidr(),
}
optional_checks = {
    "rsync": check_tool("rsync"),
    "dns_huaweicloud": check_dns("repo.huaweicloud.com"),
}
if deploy_strategy in {"docker", "docker-compose"}:
    optional_checks.update(
        {
            "dns_dockerhub": check_dns("registry-1.docker.io"),
            "docker_hub_connectivity": check_network("registry-1.docker.io", 443, 5),
            "docker_mirror_daocloud_connectivity": check_network("docker.m.daocloud.io", 443, 5),
        }
    )
for key in optional_checks:
    optional_checks[key]["required"] = False

report = {
    "workdir": str(workdir),
    "checks": {**checks, **optional_checks},
}
report["status"] = "pass" if all(c["status"] == "pass" for c in checks.values()) else "fail"
print(json.dumps(report, ensure_ascii=False, indent=2))
if report["status"] != "pass":
    sys.exit(1)
PY
