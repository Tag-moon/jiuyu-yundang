#!/usr/bin/env python3
import argparse
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from env_utils import merged_env


SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
SENSITIVE_KEY_RE = re.compile(r"(AK|SK|SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY|JWT)", re.IGNORECASE)
DOTENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def find_bash() -> str:
    candidates = [
        shutil.which("bash"),
        r"C:\liboran\Git\bin\bash.exe",
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files\Git\usr\bin\bash.exe",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return str(candidate)
    raise SystemExit("bash not found. Install Git Bash, WSL, or run this skill in a POSIX shell environment.")


def redact(value: str | None) -> str:
    if not value:
        return ""
    text = value
    text = re.sub(r"(?i)(password|secret|token|jwt|private[_-]?key)\s*[:=]\s*[^ \n\r]+", r"\1=<redacted>", text)
    text = re.sub(r"AKIA[0-9A-Z]{12,}", "<redacted>", text)
    return text[-4000:]


def safe_cmd(cmd: list[str]) -> str:
    safe = []
    for part in cmd:
        safe.append("<redacted>" if SENSITIVE_KEY_RE.search(str(part)) else str(part))
    return " ".join(safe)


def current_public_ip() -> str | None:
    for url in ("https://api.ipify.org", "https://ifconfig.me/ip"):
        try:
            with urllib.request.urlopen(url, timeout=6) as response:
                value = response.read().decode("utf-8").strip()
            ipaddress.ip_address(value)
            return value
        except Exception:
            continue
    return None


def resolve_ssh_cidr(value: str | None) -> str:
    if value:
        return str(ipaddress.ip_network(value, strict=False))
    detected = current_public_ip()
    if detected:
        return f"{detected}/32"
    raise SystemExit(
        "Could not detect this control machine's public IP. Provide --ssh-cidr x.x.x.x/32. "
        "Use --ssh-cidr 0.0.0.0/0 only if you intentionally want SSH open to the internet."
    )


def normalize_region(value: str | None) -> str:
    aliases = {
        "华东2": "cn-east-2",
        "上海2": "cn-east-2",
        "北京4": "cn-north-4",
        "华北-北京4": "cn-north-4",
        "华南-广州": "cn-south-1",
        "广州": "cn-south-1",
    }
    raw = (value or "cn-north-4").strip()
    return aliases.get(raw, raw)


def safe_reason(value: str | None) -> str:
    text = redact(value or "deploy or verify failed")
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:500] or "deploy or verify failed"


def run(cmd: list[str], cwd: Path, env: dict | None = None, timeout: int | None = None) -> subprocess.CompletedProcess:
    print(f"[auto-deploy] {safe_cmd(cmd)}", file=sys.stderr)
    return subprocess.run(
        cmd,
        cwd=str(cwd),
        env=env or merged_env(),
        check=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )


def write_output(path: Path, result: subprocess.CompletedProcess) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(result.stdout, encoding="utf-8")


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def parse_dotenv_line(line: str, source: str, lineno: int) -> tuple[str, str] | None:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return None
    if stripped.startswith("export "):
        stripped = stripped[len("export ") :].strip()
    if "=" not in stripped:
        raise SystemExit(f"{source}:{lineno}: expected KEY=VALUE dotenv entry")
    key, value = stripped.split("=", 1)
    key = key.strip()
    if not DOTENV_KEY_RE.match(key):
        raise SystemExit(f"{source}:{lineno}: invalid environment variable name: {key}")
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        value = value[1:-1]
    return key, value


def load_env_file(path: str | None) -> dict[str, str]:
    if not path:
        return {}
    env_path = Path(path).expanduser().resolve()
    if not env_path.exists() or not env_path.is_file():
        raise SystemExit(f"--env-file not found: {env_path}")
    parsed: dict[str, str] = {}
    for lineno, line in enumerate(env_path.read_text(encoding="utf-8-sig").splitlines(), start=1):
        item = parse_dotenv_line(line, str(env_path), lineno)
        if item:
            parsed[item[0]] = item[1]
    return parsed


def parse_env_values(values: list[str] | None) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for index, item in enumerate(values or [], start=1):
        result = parse_dotenv_line(item, "--env", index)
        if result:
            parsed[result[0]] = result[1]
    return parsed


def merge_env_vars(env_file: str | None, cli_env: list[str] | None) -> dict[str, str]:
    merged = load_env_file(env_file)
    merged.update(parse_env_values(cli_env))
    return merged


def redact_env_values(env_vars: dict[str, str]) -> dict[str, str]:
    return {key: "<redacted>" for key in sorted(env_vars)}


def write_env_file(path: Path, env_vars: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{key}={value}" for key, value in sorted(env_vars.items())]
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def env_status(analysis: dict, env_vars: dict[str, str], allow_missing: bool) -> dict[str, Any]:
    required = sorted({str(key) for key in (analysis.get("required_env_vars") or []) if key})
    provided = sorted(env_vars)
    missing = sorted(key for key in required if key not in env_vars)
    return {
        "required_env_keys": required,
        "provided_env_keys": provided,
        "missing_env_keys": missing,
        "allow_missing_env": allow_missing,
        "risk": bool(missing and allow_missing),
    }


def validate_required_env(args: argparse.Namespace, analysis: dict, env_vars: dict[str, str]) -> dict[str, Any]:
    status = env_status(analysis, env_vars, bool(args.allow_missing_env))
    missing = status["missing_env_keys"]
    if not missing or args.allow_missing_env:
        return status
    message = (
        "Missing required environment variables detected by analysis: "
        + ", ".join(missing)
        + ". Provide them with --env KEY=VALUE or --env-file PATH, or pass --allow-missing-env to continue with risk."
    )
    if args.yes or args.plan_only or args.validate_only:
        raise SystemExit(message)
    print(message, file=sys.stderr)
    answer = input("Continue without these environment variables? Type 'yes' to continue: ")
    if answer.strip().lower() != "yes":
        raise SystemExit("deployment cancelled because required environment variables were missing")
    status["allow_missing_env"] = True
    status["risk"] = True
    return status


def archive_previous_attempt(workdir: Path, paths: dict[str, Path]) -> None:
    if not paths["timings"].exists() and not paths["summary"].exists():
        return
    existing = sorted(workdir.glob("timings-attempt-*.json"))
    attempt = len(existing) + 1
    archive_map = {
        "timings": f"timings-attempt-{attempt}.json",
        "summary": f"run-summary-attempt-{attempt}.json",
        "report": f"deployment-test-report-attempt-{attempt}.md",
        "deploy_events": f"deploy-events-attempt-{attempt}.jsonl",
        "deploy_result": f"deploy-result-attempt-{attempt}.json",
        "provision_timings": f"provision-timings-attempt-{attempt}.json",
    }
    for key, filename in archive_map.items():
        source = paths.get(key)
        if source and source.exists():
            shutil.copy2(source, workdir / filename)


class Recorder:
    def __init__(self, workdir: Path):
        self.workdir = workdir
        self.started = time.perf_counter()
        self.stages: list[dict] = []
        self.failure: dict | None = None

    @contextmanager
    def stage(self, name: str, command: list[str] | None = None):
        started = time.perf_counter()
        status = "success"
        message = ""
        try:
            yield
        except subprocess.CalledProcessError as exc:
            status = "failed"
            message = redact(exc.stderr or exc.stdout or str(exc))
            failure = {
                "failed_step": name,
                "command": safe_cmd(list(exc.cmd) if isinstance(exc.cmd, (list, tuple)) else [str(exc.cmd)]),
                "exit_code": exc.returncode,
                "original_error": message,
                "stderr_summary": message,
                **classify_failure(name, message),
            }
            if not self.failure:
                self.failure = failure
            raise
        except Exception as exc:
            status = "failed"
            message = redact(str(exc))
            failure = {
                "failed_step": name,
                "command": safe_cmd(command or []),
                "exit_code": None,
                "original_error": message,
                "stderr_summary": message,
                **classify_failure(name, message),
            }
            if not self.failure:
                self.failure = failure
            raise
        finally:
            self.stages.append(
                {
                    "step": name,
                    "status": status,
                    "duration_seconds": round(time.perf_counter() - started, 3),
                    "command": safe_cmd(command or []),
                    "message": message,
                }
            )
            self.write_timings()

    def add_event(self, event: dict) -> None:
        self.stages.append(
            {
                "step": event.get("step", "deploy"),
                "status": event.get("status", "unknown"),
                "duration_seconds": float(event.get("duration_seconds") or event.get("duration") or 0),
                "command": "",
                "message": redact(str(event.get("message", ""))),
            }
        )
        self.write_timings()

    def import_provision_timings(self, path: Path) -> None:
        data = load_json(path)
        for event in data.get("stages") or []:
            self.add_event(event)

    def import_deploy_events(self, path: Path) -> None:
        if not path.exists():
            return
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                self.add_event(json.loads(line))
            except json.JSONDecodeError:
                continue

    def write_timings(self) -> None:
        total = round(time.perf_counter() - self.started, 3)
        write_json(
            self.workdir / "timings.json",
            {
                "total_seconds": total,
                "failed_step": (self.failure or {}).get("failed_step"),
                "stages": self.stages,
            },
        )


def cleanup_hint(step: str, text: str) -> str:
    lowered = text.lower()
    if "vpc" in lowered and "conflict" in lowered:
        return "Retry with --network-mode reuse --existing-vpc-id <id> --existing-subnet-id <id>. If state exists, destroy only with scripts/destroy.py --workdir <terraform-workdir>."
    if "availability_zone" in lowered and "not exist" in lowered:
        return "Use an AZ that belongs to the selected region, or omit --availability-zone and let the default regional AZ be used."
    if "flavor" in lowered and ("abandoned" in lowered or "sold" in lowered or "not found" in lowered):
        return "Choose a currently available ECS flavor for the selected region/AZ, or omit --flavor and use the default recommendation."
    if "quota" in lowered and "exceed" in lowered:
        return "Request quota increase or select a smaller ECS/resource profile before retrying."
    if "docker" in lowered or "compose" in lowered:
        return "Check Docker install and image pull logs; configure --docker-registry-mirrors or allow native fallback."
    if step.startswith("terraform") or step == "provision":
        return "Inspect the Terraform workdir; cleanup must use scripts/destroy.py against the recorded state directory."
    return "Inspect the failed command output and retry after fixing the reported prerequisite."


def classify_failure(step: str, text: str) -> dict:
    lowered = text.lower()
    if "availability_zone" in lowered and "not exist" in lowered:
        reason = "The selected availability zone does not exist in the requested Huawei Cloud region."
        next_step = "Remove --availability-zone or choose one that belongs to the requested --region."
    elif "flavor" in lowered and "abandoned" in lowered:
        reason = "The selected ECS flavor has been abandoned in this region/AZ."
        next_step = "Omit --flavor or select another currently available ECS flavor."
    elif "flavor" in lowered and ("sold out" in lowered or "soldout" in lowered):
        reason = "The selected ECS flavor is sold out in this region/AZ."
        next_step = "Retry without --flavor so the resolver can choose another available flavor."
    elif "quota" in lowered and "exceed" in lowered:
        reason = "Huawei Cloud quota is insufficient for the requested resources."
        next_step = "Reduce the requested size or request a quota increase, then rerun with the same workdir."
    else:
        reason = "The workflow failed during this step; inspect the original error for the immediate cause."
        next_step = cleanup_hint(step, text)
    return {
        "human_reason": reason,
        "next_step": next_step,
        "cleanup_hint": cleanup_hint(step, text),
    }


def ssh_key_reusable(path: Path) -> bool:
    data = load_json(path)
    private_key = Path(str(data.get("ssh_private_key_path") or ""))
    public_key = Path(str(data.get("ssh_public_key_path") or ""))
    return bool(data.get("ssh_key_name") and data.get("ssh_public_key") and private_key.exists() and public_key.exists())


def require_confirmation(args: argparse.Namespace, plan_path: Path) -> None:
    if args.yes or args.plan_only or args.validate_only:
        return
    print(plan_path.read_text(encoding="utf-8"), file=sys.stderr)
    answer = input("Proceed with Terraform apply and application deployment? Type 'yes' to continue: ")
    if answer.strip().lower() != "yes":
        raise SystemExit("deployment cancelled")


def append_if(cmd: list[str], option: str, value) -> None:
    if value not in (None, ""):
        cmd.extend([option, str(value)])


def append_flag(cmd: list[str], option: str, enabled: bool) -> None:
    if enabled:
        cmd.append(option)


def deploy_strategy_from_result(path: Path, analysis: dict) -> str:
    result = load_json(path)
    return result.get("strategy") or analysis.get("deploy_strategy") or "native"


def security_rules(spec: dict) -> list[dict]:
    return (((spec.get("resources") or {}).get("security_group") or {}).get("rules") or [])


def generate_report(path: Path, summary: dict, timings: dict, analysis: dict, spec: dict, verify_text: str) -> None:
    stages = timings.get("stages") or []
    slowest = sorted(stages, key=lambda item: float(item.get("duration_seconds") or 0), reverse=True)[:5]
    rules = security_rules(spec)
    optional = spec.get("optional_resources") or {}
    resource_info = summary.get("resource_info_data") or {}
    resource_resolution = spec.get("resource_resolution") or {}
    recovery = summary.get("recovery") or {}
    raw_failure = summary.get("failure") or {}
    failure_summary = {k: v for k, v in raw_failure.items() if k != "remote_diagnostics"}
    env_report = summary.get("env") or {}
    diag_text = ""
    if raw_failure.get("remote_diagnostics"):
        diag_text = "### Remote Diagnostics\n\n```text\n" + str(raw_failure["remote_diagnostics"])[:2000] + "\n```\n"


    def table(rows):
        if not rows:
            return "No timing data recorded."
        lines = ["| Step | Status | Seconds |", "| --- | --- | ---: |"]
        for row in rows:
            lines.append(f"| `{row.get('step')}` | `{row.get('status')}` | {row.get('duration_seconds', 0)} |")
        return "\n".join(lines)

    def required_timing_rows() -> list[dict]:
        required = [
            "terraform",
            "ssh_wait",
            "upload_source",
            "install_runtime",
            "npm_install",
            "build",
            "start_service",
            "verify",
        ]
        aliases = {
            "terraform_init_validate_plan": "terraform",
            "terraform_apply": "terraform",
            "provision": "terraform",
        }
        buckets = {name: {"step": name, "status": "not_run", "duration_seconds": 0.0} for name in required}
        for stage in stages:
            step = str(stage.get("step") or "")
            bucket = aliases.get(step, step if step in buckets else "")
            if not bucket:
                continue
            buckets[bucket]["duration_seconds"] = round(float(buckets[bucket]["duration_seconds"]) + float(stage.get("duration_seconds") or 0), 3)
            if stage.get("status") == "failed":
                buckets[bucket]["status"] = "failed"
            elif buckets[bucket]["status"] == "not_run":
                buckets[bucket]["status"] = str(stage.get("status") or "success")
        return [buckets[name] for name in required]

    report = f"""# Auto Deploy Report: {summary.get('app_name', 'app')}

## Project

- Status: `{summary.get('status')}`
- Recovery: `{json.dumps(recovery, ensure_ascii=False) if recovery else 'none'}`
- Type: `{analysis.get('project_type')}` / `{analysis.get('framework')}`
- Strategy: `{summary.get('deploy_strategy') or analysis.get('deploy_strategy')}`
- Port: `{((spec.get('deployment_context') or {}).get('app_port') or analysis.get('listen_port'))}`
- Workdir: `{summary.get('workdir')}`

## Environment

- Required env keys: `{', '.join(env_report.get('required_env_keys') or []) or 'none detected'}`
- Provided env keys: `{', '.join(env_report.get('provided_env_keys') or []) or 'none'}`
- Missing env keys: `{', '.join(env_report.get('missing_env_keys') or []) or 'none'}`
- Missing env override: `{'enabled' if env_report.get('allow_missing_env') else 'disabled'}`

## Cloud Resources

- Region: `{spec.get('region') or summary.get('region')}`
- Template: `{summary.get('template')}`
- Instance: `{resource_info.get('instance_id', 'not created')}`
- Public IP: `{resource_info.get('public_ip', 'not created')}`
- VPC/Subnet: `{resource_info.get('vpc_id', ((spec.get('resources') or {}).get('vpc') or {}).get('existing_vpc_id', 'pending'))}` / `{resource_info.get('subnet_id', ((spec.get('resources') or {}).get('vpc') or {}).get('existing_subnet_id', 'pending'))}`

## Security Group

```json
{json.dumps(rules, ensure_ascii=False, indent=2)}
```

## Timings

### Required Stage Split

{table(required_timing_rows())}

### Raw Events

{table(stages)}

## Slowest Stages

{table(slowest)}

## Verification

```text
{redact(verify_text) or 'not run'}
```

## Failure Diagnosis

```json
{json.dumps(failure_summary, ensure_ascii=False, indent=2)}
```

{diag_text}

## Next Optimizations

- Prefer `native` over Docker when the repo has a clear runtime/start path.
- Configure Docker registry mirrors when Docker image pull or build is slow.
- Use `--network-mode reuse` with existing VPC/subnet IDs after VPC conflict errors.
"""
    if optional:
        report += f"""

## Optional Resource Recommendations

```json
{json.dumps(optional, ensure_ascii=False, indent=2)}
```
"""
    if resource_resolution:
        report += f"""

## Resource Resolution

```json
{json.dumps(resource_resolution, ensure_ascii=False, indent=2)}
```
"""
    path.write_text(report, encoding="utf-8")

def collect_remote_diagnostics(
    paths: dict[str, Path],
    analysis: dict,
    strategy: str,
    app_name: str,
) -> str | None:
    """SSH into the remote server and collect failure diagnostic logs.

    Returns the log text, or None if SSH info is unavailable or connection fails.
    """
    resource_info_path = paths.get("resource_info")
    if not resource_info_path or not resource_info_path.exists():
        return None

    try:
        ri = json.loads(resource_info_path.read_text(encoding="utf-8-sig"))
    except (json.JSONDecodeError, OSError):
        return None

    host = ri.get("public_ip")
    user = ri.get("ssh_user")
    key_path = ri.get("ssh_key_path")
    if not host or not user or not key_path:
        return None

    key = Path(key_path)
    if not key.exists():
        return None

    known_hosts = Path(str(key) + ".known_hosts")
    ssh_base = [
        "ssh",
        "-i", str(key),
        "-o", f"UserKnownHostsFile={known_hosts}",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=10",
        f"{user}@{host}",
    ]

    remote_dir = f"/opt/auto-deploy/{app_name}"

    commands: list[str] = []
    if strategy in ("docker-compose", "docker"):
        # Determine compose file name
        compose_candidates = [
            f"{remote_dir}/current/docker-compose.yml",
            f"{remote_dir}/current/docker-compose.yaml",
            f"{remote_dir}/current/compose.yml",
            f"{remote_dir}/current/compose.yaml",
        ]
        compose_test = " || ".join(
            f'[ -f "{c}" ]' for c in compose_candidates
        )
        compose_file_var = (
            f'COMPOSE_FILE=$(for f in {" ".join(compose_candidates)}; do [ -f "$f" ] && echo "$f" && break; done)'
        )
        commands = [
            compose_file_var,
            'if [ -n "$COMPOSE_FILE" ]; then '
            'sudo docker compose -f "$COMPOSE_FILE" logs --tail=100 --no-color 2>&1; '
            'sudo docker compose -f "$COMPOSE_FILE" ps -a 2>&1; '
            "fi",
        ]
    elif strategy == "native":
        commands = [
            f"sudo systemctl status {app_name}.service --no-pager 2>&1 || true",
            f"sudo journalctl -u {app_name} --no-pager -n 50 2>&1 || true",
        ]

    # Always include system resource info
    commands.append("df -h 2>&1")
    commands.append("free -h 2>&1")

    script = "set -e\n" + "\n".join(commands)
    cmd = ssh_base + [script]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
        )
        output = (result.stdout or "") + "\n" + (result.stderr or "")
        return output.strip() or None
    except (subprocess.TimeoutExpired, OSError) as exc:
        return f"[auto-deploy] remote diagnostics collection failed: {exc}"


def finalize(
    *,
    status: str,
    args: argparse.Namespace,
    recorder: Recorder,
    paths: dict[str, Path],
    analysis: dict | None = None,
    spec: dict | None = None,
    verify_text: str = "",
    rollback_status: str | None = None,
    template: str | None = None,
) -> dict:
    analysis = analysis or load_json(paths["analysis"])
    spec = spec or load_json(paths["resource_spec"])
    previous_summary = load_json(paths["summary"])
    resource_info = load_json(paths["resource_info"])
    deploy_result = load_json(paths["deploy_result"])
    timings = load_json(paths["timings"])
    failure = recorder.failure or {}
    if rollback_status:
        failure["rollback_status"] = rollback_status
    env_status_data = getattr(args, "_env_status", None) or (spec.get("deployment_context") or {}).get("env") or {}
    app_env_path = paths.get("app_env")
    if app_env_path and app_env_path.exists():
        app_env_path.unlink()
    final_status = status
    recovery = {}
    if status == "deployed":
        failed_events = [stage for stage in timings.get("stages", []) if stage.get("status") == "failed"]
        prior_failure = (previous_summary.get("status") == "failed")
        if deploy_result.get("fallback_from") or failed_events or prior_failure:
            final_status = "recovered"
            original_failures = list(failed_events)
            if prior_failure and previous_summary.get("failure"):
                original_failures.append(previous_summary["failure"])
            recovery = {
                "original_failures": original_failures,
                "retry_action": deploy_result.get("message") or "workflow retried and final verify succeeded",
                "final_verify": "success",
            }
    summary = {
        "status": final_status,
        "app_name": args.app_name,
        "region": spec.get("region") or args.region,
        "template": template or ("ecs-web-existing-network" if args.network_mode == "reuse" else "ecs-web"),
        "workdir": str(paths["workdir"]),
        "terraform_workdir": str(paths["terraform_workdir"]),
        "analysis": str(paths["analysis"]),
        "plan": str(paths["plan"]),
        "resource_spec": str(paths["resource_spec"]),
        "resource_info": str(paths["resource_info"]) if paths["resource_info"].exists() else None,
        "resource_info_data": resource_info,
        "deploy_result": deploy_result,
        "deploy_strategy": deploy_result.get("strategy") or analysis.get("deploy_strategy"),
        "security_group_rules": security_rules(spec),
        "optional_resources": spec.get("optional_resources") or {},
        "resource_resolution": spec.get("resource_resolution") or {},
        "env": env_status_data,
        "timings": timings,
        "verify": redact(verify_text),
        "failure": failure,
        "recovery": recovery,
        "network_recovery": load_json(paths["workdir"] / "network-recovery.json") if (paths["workdir"] / "network-recovery.json").exists() else None,
    }
    write_json(paths["summary"], summary)
    generate_report(paths["report"], summary, timings, analysis, spec, verify_text)
    print(json.dumps(summary, ensure_ascii=True, indent=2))
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the full auto-deploy workflow with one command.")
    parser.add_argument("--repo", "--project", dest="repo", required=True, help="Application repository path.")
    parser.add_argument("--app-name", required=True)
    parser.add_argument("--region", default="cn-north-4")
    parser.add_argument("--availability-zone")
    parser.add_argument("--domain")
    parser.add_argument("--workdir", help="Workflow output directory. Defaults to <repo>/.auto-deploy.")
    parser.add_argument("--terraform-workdir", help="Terraform state directory. Defaults to <workdir>/terraform.")
    parser.add_argument("--ssh-cidr", help="CIDR allowed to SSH. Defaults to detected public IP /32.")
    parser.add_argument("--public-cidr", default="0.0.0.0/0", help="CIDR allowed to reach the application port.")
    parser.add_argument("--app-port", type=int)
    parser.add_argument("--no-http", action="store_true")
    parser.add_argument("--no-https", action="store_true")
    parser.add_argument("--node-version")
    parser.add_argument("--flavor", help="Override analyzed ECS flavor recommendation.")
    parser.add_argument("--flavor-tier", choices=["minimal", "small", "standard", "performance"], help="Select ECS flavor by tier: minimal(1C1G)/small(2C4G)/standard(2C4G)/performance(4C8G).")
    parser.add_argument("--image", help="Override ECS image name.")
    parser.add_argument("--disk-size", type=int)
    parser.add_argument("--bandwidth", type=int)
    parser.add_argument("--network-mode", choices=["create", "reuse"], default="create")
    parser.add_argument("--existing-vpc-id")
    parser.add_argument("--existing-subnet-id")
    parser.add_argument("--docker-registry-mirrors", help="Comma-separated Docker registry mirrors for remote Docker installs.")
    parser.add_argument("--image-registry-prefix", help="Optional image registry prefix for SWR or private registry workflows.")
    parser.add_argument("--docker-build-timeout", type=int, help="Docker build timeout in seconds. Defaults to 2400 for Docker paths.")
    parser.add_argument("--env", action="append", default=[], metavar="KEY=VALUE", help="Inject an application environment variable. Repeat for multiple keys.")
    parser.add_argument("--env-file", help="Read application environment variables from a dotenv-format file.")
    parser.add_argument("--allow-missing-env", action="store_true", help="Continue even when analyzed required env vars were not provided; reports the risk.")
    parser.add_argument("--allow-native-fullstack", action="store_true", help="Explicitly allow native deployment for frontend/backend split apps without Docker Compose.")
    parser.add_argument("--plan-only", action="store_true", help="Stop after analysis, plan, SSH key, and resource spec.")
    parser.add_argument("--validate-only", action="store_true", help="Render and validate Terraform without planning/applying cloud resources.")
    parser.add_argument("--resume-from", choices=["analyze", "plan", "provision", "deploy", "verify"], default="analyze")
    parser.add_argument("--skip-upload", action="store_true", help="Skip source upload when resuming a failed deploy against an unchanged remote checkout.")
    parser.add_argument("--skip-prepare", action="store_true", help="Skip remote backup/current directory preparation when resuming a failed deploy.")
    parser.add_argument("--yes", action="store_true", help="Proceed without interactive confirmation after the plan.")
    parser.add_argument("--skip-preflight", action="store_true")
    args = parser.parse_args()
    args.region = normalize_region(args.region)
    args.ssh_cidr = resolve_ssh_cidr(args.ssh_cidr)

    if args.network_mode == "reuse" and (not args.existing_vpc_id or not args.existing_subnet_id):
        raise SystemExit("--network-mode reuse requires --existing-vpc-id and --existing-subnet-id")

    repo = Path(args.repo).resolve()
    if not repo.exists() or not repo.is_dir():
        raise SystemExit(f"repo not found: {repo}")
    app_env_vars = merge_env_vars(args.env_file, args.env)

    bash = find_bash()
    workdir = Path(args.workdir).resolve() if args.workdir else repo / ".auto-deploy"
    terraform_workdir = Path(args.terraform_workdir).resolve() if args.terraform_workdir else workdir / "terraform"
    workdir.mkdir(parents=True, exist_ok=True)

    paths = {
        "workdir": workdir,
        "terraform_workdir": terraform_workdir,
        "analysis": workdir / "analysis.json",
        "plan": workdir / "deployment-plan.md",
        "ssh_key": workdir / "ssh-key-info.json",
        "resource_spec": workdir / "resource-spec.json",
        "resource_info": workdir / "resource-info.json",
        "summary": workdir / "run-summary.json",
        "timings": workdir / "timings.json",
        "report": workdir / "deployment-test-report.md",
        "provision_timings": workdir / "provision-timings.json",
        "deploy_events": workdir / "deploy-events.jsonl",
        "deploy_result": workdir / "deploy-result.json",
        "app_env": workdir / "app-env.private",
    }
    archive_previous_attempt(workdir, paths)
    for transient in (paths["deploy_events"], paths["deploy_result"], paths["provision_timings"]):
        if transient.exists():
            transient.unlink()

    recorder = Recorder(workdir)
    analysis: dict = {}
    spec: dict = {}
    verify_text = ""
    selected_template = "ecs-web-existing-network" if args.network_mode == "reuse" else "ecs-web"
    resume_order = {"analyze": 0, "plan": 1, "provision": 2, "deploy": 3, "verify": 4}

    try:
        if resume_order[args.resume_from] <= resume_order["analyze"]:
            analyze_cmd = [bash, str(SCRIPT_DIR / "analyze.sh"), str(repo)]
            with recorder.stage("analyze", analyze_cmd):
                result = run(analyze_cmd, cwd=SKILL_DIR)
                write_output(paths["analysis"], result)
        elif not paths["analysis"].exists():
            raise SystemExit(f"--resume-from {args.resume_from} requires existing analysis.json in {paths['workdir']}")
        analysis = load_json(paths["analysis"])
        if (
            analysis.get("has_frontend_backend_split")
            and not analysis.get("has_docker_compose")
            and analysis.get("deploy_strategy") == "native"
            and not args.allow_native_fullstack
        ):
            raise SystemExit(
                "当前 skill 只稳定支持单体 native 或 Docker Compose。"
                "前后端分离项目请提供 docker-compose.yml，或显式使用 --allow-native-fullstack。"
            )
        args._env_status = validate_required_env(args, analysis, app_env_vars)

        if not args.skip_preflight and resume_order[args.resume_from] <= resume_order["analyze"]:
            preflight_cmd = [bash, str(SCRIPT_DIR / "preflight.sh")]
            append_if(preflight_cmd, "--ssh-cidr", args.ssh_cidr)
            append_if(preflight_cmd, "--analysis", paths["analysis"])
            preflight_cmd.append(str(repo))
            with recorder.stage("preflight", preflight_cmd):
                run(preflight_cmd, cwd=SKILL_DIR)

        ssh_cmd = [
            sys.executable,
            str(SCRIPT_DIR / "prepare_ssh_key.py"),
            "--analysis",
            str(paths["analysis"]),
            "--app-name",
            args.app_name,
            "--key-dir",
            str(workdir / "keys"),
            "--output",
            str(paths["ssh_key"]),
        ]
        if resume_order[args.resume_from] <= resume_order["plan"]:
            with recorder.stage("prepare_ssh_key", ssh_cmd):
                if ssh_key_reusable(paths["ssh_key"]):
                    print(f"[auto-deploy] reusing existing SSH key info: {paths['ssh_key']}", file=sys.stderr)
                else:
                    run(ssh_cmd, cwd=SKILL_DIR)
        elif not paths["ssh_key"].exists():
            raise SystemExit(f"--resume-from {args.resume_from} requires existing ssh-key-info.json in {paths['workdir']}")

        spec_cmd = [
            sys.executable,
            str(SCRIPT_DIR / "resource_spec.py"),
            "--analysis",
            str(paths["analysis"]),
            "--ssh-key-info",
            str(paths["ssh_key"]),
            "--app-name",
            args.app_name,
            "--region",
            args.region,
            "--network-mode",
            args.network_mode,
            "--public-cidr",
            args.public_cidr,
            "--output",
            str(paths["resource_spec"]),
        ]
        for option, value in [
            ("--availability-zone", args.availability_zone),
            ("--disk-size", args.disk_size),
            ("--bandwidth", args.bandwidth),
            ("--flavor-tier", args.flavor_tier),
            ("--domain", args.domain),
            ("--existing-vpc-id", args.existing_vpc_id),
            ("--existing-subnet-id", args.existing_subnet_id),
            ("--app-port", args.app_port),
            ("--ssh-cidr", args.ssh_cidr),
            ("--node-version", args.node_version),
        ]:
            append_if(spec_cmd, option, value)
        append_flag(spec_cmd, "--no-http", args.no_http)
        append_flag(spec_cmd, "--no-https", args.no_https)
        for key in (args._env_status or {}).get("provided_env_keys", []):
            spec_cmd.extend(["--provided-env-key", key])
        if args.allow_missing_env:
            spec_cmd.append("--allow-missing-env")
        if resume_order[args.resume_from] <= resume_order["plan"]:
            with recorder.stage("resource_spec", spec_cmd):
                run(spec_cmd, cwd=SKILL_DIR)
        elif not paths["resource_spec"].exists():
            raise SystemExit(f"--resume-from {args.resume_from} requires existing resource-spec.json in {paths['workdir']}")
        spec = load_json(paths["resource_spec"])

        plan_cmd = [
            sys.executable,
            str(SCRIPT_DIR / "plan.py"),
            "--analysis",
            str(paths["analysis"]),
            "--resource-spec",
            str(paths["resource_spec"]),
            "--app-name",
            args.app_name,
            "--region",
            args.region,
            "--template",
            selected_template,
            "--network-mode",
            args.network_mode,
            "--public-cidr",
            args.public_cidr,
            "--output",
            str(paths["plan"]),
        ]
        for option, value in [
            ("--domain", args.domain),
            ("--existing-vpc-id", args.existing_vpc_id),
            ("--existing-subnet-id", args.existing_subnet_id),
            ("--app-port", args.app_port),
            ("--ssh-cidr", args.ssh_cidr),
        ]:
            append_if(plan_cmd, option, value)
        append_flag(plan_cmd, "--no-http", args.no_http)
        append_flag(plan_cmd, "--no-https", args.no_https)
        for key in (args._env_status or {}).get("provided_env_keys", []):
            plan_cmd.extend(["--provided-env-key", key])
        if args.allow_missing_env:
            plan_cmd.append("--allow-missing-env")
        if resume_order[args.resume_from] <= resume_order["plan"]:
            with recorder.stage("plan", plan_cmd):
                run(plan_cmd, cwd=SKILL_DIR)
        elif not paths["plan"].exists():
            raise SystemExit(f"--resume-from {args.resume_from} requires existing deployment-plan.md in {paths['workdir']}")

        if args.plan_only:
            finalize(status="planned", args=args, recorder=recorder, paths=paths, analysis=analysis, spec=spec, template=selected_template)
            return 0

        k8s = analysis.get("kubernetes") or {}
        if k8s.get("detected"):
            raise SystemExit("Kubernetes manifests detected. This simplified skill only supports single ECS web application deployment.")

        if resume_order[args.resume_from] <= resume_order["provision"]:
            require_confirmation(args, paths["plan"])

        provision_cmd = [
            sys.executable,
            str(SCRIPT_DIR / "provision.py"),
            "--analysis",
            str(paths["analysis"]),
            "--resource-spec",
            str(paths["resource_spec"]),
            "--ssh-key-info",
            str(paths["ssh_key"]),
            "--workdir",
            str(terraform_workdir),
            "--output-resource-info",
            str(paths["resource_info"]),
            "--public-cidr",
            args.public_cidr,
            "--timings",
            str(paths["provision_timings"]),
        ]
        if args.validate_only:
            provision_cmd.append("--validate-only")
        else:
            provision_cmd.append("--apply")
            if args.yes:
                provision_cmd.append("--auto-approve")
        for option, value in [
            ("--availability-zone", args.availability_zone),
            ("--ssh-cidr", args.ssh_cidr),
            ("--flavor", args.flavor),
            ("--image", args.image),
            ("--disk-size", args.disk_size),
            ("--bandwidth", args.bandwidth),
            ("--app-port", args.app_port),
            ("--network-mode", args.network_mode),
            ("--existing-vpc-id", args.existing_vpc_id),
            ("--existing-subnet-id", args.existing_subnet_id),
        ]:
            append_if(provision_cmd, option, value)
        append_flag(provision_cmd, "--no-http", args.no_http)
        append_flag(provision_cmd, "--no-https", args.no_https)
        if resume_order[args.resume_from] <= resume_order["provision"]:
            try:
                with recorder.stage("provision", provision_cmd):
                    run(provision_cmd, cwd=SKILL_DIR)
            finally:
                recorder.import_provision_timings(paths["provision_timings"])
        elif not paths["resource_info"].exists():
            raise SystemExit(f"--resume-from {args.resume_from} requires existing resource-info.json in {paths['workdir']}")

        if args.validate_only:
            finalize(status="terraform_validated", args=args, recorder=recorder, paths=paths, analysis=analysis, spec=spec, template=selected_template)
            return 0

        write_env_file(paths["app_env"], app_env_vars)
        deploy_cmd = [
            bash,
            str(SCRIPT_DIR / "deploy.sh"),
            "--project",
            str(repo),
            "--analysis",
            str(paths["analysis"]),
            "--resources",
            str(paths["resource_info"]),
            "--app-name",
            args.app_name,
            "--region",
            args.region,
            "--events",
            str(paths["deploy_events"]),
            "--result",
            str(paths["deploy_result"]),
        ]
        for option, value in [
            ("--node-version", args.node_version),
            ("--docker-registry-mirrors", args.docker_registry_mirrors),
            ("--image-registry-prefix", args.image_registry_prefix),
            ("--docker-build-timeout", args.docker_build_timeout),
            ("--env-file", paths["app_env"]),
        ]:
            append_if(deploy_cmd, option, value)
        append_flag(deploy_cmd, "--skip-upload", args.skip_upload)
        append_flag(deploy_cmd, "--skip-prepare", args.skip_prepare)
        append_flag(deploy_cmd, "--allow-native-fullstack", args.allow_native_fullstack)

        if resume_order[args.resume_from] <= resume_order["deploy"]:
            try:
                with recorder.stage("deploy", deploy_cmd):
                    run(deploy_cmd, cwd=SKILL_DIR)
            finally:
                recorder.import_deploy_events(paths["deploy_events"])

        actual_strategy = deploy_strategy_from_result(paths["deploy_result"], analysis)
        verify_cmd = [
            bash,
            str(SCRIPT_DIR / "verify.sh"),
            "--analysis",
            str(paths["analysis"]),
            "--resources",
            str(paths["resource_info"]),
            "--app-name",
            args.app_name,
            "--strategy",
            actual_strategy,
            "--app-port",
            str(args.app_port or (spec.get("deployment_context") or {}).get("app_port") or analysis.get("listen_port") or 8080),
        ]
        with recorder.stage("verify", verify_cmd):
            verify = run(verify_cmd, cwd=SKILL_DIR)
            verify_text = verify.stdout.strip()

        finalize(status="deployed", args=args, recorder=recorder, paths=paths, analysis=analysis, spec=spec, verify_text=verify_text, template=selected_template)
        return 0

    except subprocess.CalledProcessError as exc:
        rollback_status = None
        failed_step = (recorder.failure or {}).get("failed_step")
        should_rollback = failed_step == "deploy"
        if should_rollback and paths["resource_info"].exists():
            rollback_cmd = [
                bash,
                str(SCRIPT_DIR / "rollback.sh"),
                "--resources",
                str(paths["resource_info"]),
                "--app-name",
                args.app_name,
                "--reason",
                safe_reason(recorder.failure.get("stderr_summary", "deploy or verify failed") if recorder.failure else "deploy or verify failed"),
            ]
            try:
                with recorder.stage("rollback", rollback_cmd):
                    run(rollback_cmd, cwd=SKILL_DIR)
                rollback_status = "completed"
            except subprocess.CalledProcessError as rollback_exc:
                rollback_status = f"failed: {rollback_exc.returncode}"
        elif paths["resource_info"].exists():
            rollback_status = "skipped: failure happened after deploy; leaving running resources in place for inspection"
        if exc.stdout:
            print(redact(exc.stdout), file=sys.stderr)
        if exc.stderr:
            print(redact(exc.stderr), file=sys.stderr)
        # Collect remote diagnostics before finalizing
        actual_strategy = deploy_strategy_from_result(paths["deploy_result"], analysis) if paths["deploy_result"].exists() else analysis.get("deploy_strategy", "native")
        remote_diag = collect_remote_diagnostics(paths, analysis, actual_strategy, args.app_name)
        if remote_diag:
            diag_file = paths["workdir"] / "deploy-failure-logs.txt"
            diag_file.write_text(remote_diag, encoding="utf-8")
            if recorder.failure:
                recorder.failure["remote_diagnostics"] = remote_diag[:2000]
        finalize(status="failed", args=args, recorder=recorder, paths=paths, analysis=analysis, spec=spec, verify_text=verify_text, rollback_status=rollback_status, template=selected_template)
        return exc.returncode
    except SystemExit as exc:
        if not recorder.failure:
            recorder.failure = {
                "failed_step": "workflow",
                "command": "",
                "exit_code": exc.code if isinstance(exc.code, int) else None,
                "original_error": redact(str(exc)),
                "stderr_summary": redact(str(exc)),
                **classify_failure("workflow", str(exc)),
            }
        finalize(status="failed", args=args, recorder=recorder, paths=paths, analysis=analysis, spec=spec, verify_text=verify_text, template=selected_template)
        return exc.code if isinstance(exc.code, int) else 1


if __name__ == "__main__":
    raise SystemExit(main())
