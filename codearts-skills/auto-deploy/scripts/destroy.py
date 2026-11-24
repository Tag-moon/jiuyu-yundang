#!/usr/bin/env python3
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from env_utils import merged_env


def terraform_env(workdir: Path) -> dict:
    env = merged_env()
    env["TF_CLI_CONFIG_FILE"] = str(workdir / ".tfrc")
    return env


def run(cmd: list[str], cwd: Path, env: dict) -> None:
    print(f"[auto-deploy] {' '.join(cmd)}", file=sys.stderr)
    subprocess.run(cmd, cwd=str(cwd), env=env, check=True, text=True, encoding="utf-8", errors="replace")


def main() -> int:
    parser = argparse.ArgumentParser(description="Destroy only Terraform state-managed resources created by auto-deploy.")
    parser.add_argument("--workdir", default=".auto-deploy/terraform")
    parser.add_argument("--plan-only", action="store_true")
    parser.add_argument("--auto-approve", action="store_true")
    args = parser.parse_args()

    workdir = Path(args.workdir).resolve()
    if shutil.which("terraform") is None:
        raise SystemExit("terraform not found in PATH")
    if not workdir.exists():
        raise SystemExit(f"terraform workdir not found: {workdir}")
    if not (workdir / "main.tf").exists():
        raise SystemExit(f"refusing destroy: no main.tf in {workdir}")
    if not (workdir / "terraform.tfstate").exists():
        raise SystemExit(f"refusing destroy: no terraform.tfstate in {workdir}; nothing state-managed to destroy")

    env = terraform_env(workdir)
    run(["terraform", "init"], cwd=workdir, env=env)
    run(["terraform", "plan", "-destroy", "-out", "destroy.tfplan"], cwd=workdir, env=env)

    if args.plan_only:
        print("[auto-deploy] destroy plan completed; no resources destroyed", file=sys.stderr)
        return 0

    if not args.auto_approve:
        answer = input("Destroy Terraform state-managed Huawei Cloud resources in this workdir? Type 'yes' to continue: ")
        if answer.strip().lower() != "yes":
            raise SystemExit("destroy cancelled")

    run(["terraform", "apply", "destroy.tfplan"], cwd=workdir, env=env)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        raise SystemExit(exc.returncode)
