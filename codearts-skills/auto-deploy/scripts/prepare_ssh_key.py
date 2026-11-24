#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path


def slug(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9-]+", "-", value.strip().lower()).strip("-") or "app"


def load_analysis(path: str | None) -> dict:
    if not path:
        return {}
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare a local SSH key pair for auto-deploy provisioning.")
    parser.add_argument("--analysis", help="Optional analysis JSON used to infer the app name.")
    parser.add_argument("--app-name")
    parser.add_argument("--key-dir", default=None, help="Directory for generated key files. Defaults to .auto-deploy/keys under cwd.")
    parser.add_argument("--output", default="ssh-key-info.json")
    parser.add_argument("--force", action="store_true", help="Overwrite existing key files for the same name.")
    args = parser.parse_args()

    analysis = load_analysis(args.analysis)
    app_name = slug(args.app_name or analysis.get("app_name") or Path(analysis.get("project_root", "app")).name)
    key_dir = Path(args.key_dir or Path.cwd() / ".auto-deploy" / "keys").resolve()
    key_dir.mkdir(parents=True, exist_ok=True)

    key_name = f"auto-deploy-key-{app_name}"
    private_key = key_dir / key_name
    public_key = key_dir / f"{key_name}.pub"

    if private_key.exists() and public_key.exists() and not args.force:
        public_key_text = public_key.read_text(encoding="utf-8").strip()
        result = {
            "app_name": app_name,
            "ssh_key_name": key_name,
            "ssh_private_key_path": str(private_key),
            "ssh_public_key_path": str(public_key),
            "ssh_public_key": public_key_text,
            "ssh_user": "root",
        }
        Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    if (private_key.exists() or public_key.exists()) and not args.force:
        raise SystemExit(f"key already exists: {private_key}; use --force to regenerate it")

    if shutil.which("ssh-keygen") is None:
        raise SystemExit("ssh-keygen not found in PATH; install OpenSSH client before provisioning")

    cmd = [
        "ssh-keygen",
        "-t",
        "ed25519",
        "-a",
        "64",
        "-N",
        "",
        "-C",
        f"auto-deploy:{app_name}",
        "-f",
        str(private_key),
    ]
    subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")

    if os.name != "nt":
        private_key.chmod(stat.S_IRUSR | stat.S_IWUSR)

    public_key_text = public_key.read_text(encoding="utf-8").strip()
    result = {
        "app_name": app_name,
        "ssh_key_name": key_name,
        "ssh_private_key_path": str(private_key),
        "ssh_public_key_path": str(public_key),
        "ssh_public_key": public_key_text,
        "ssh_user": "root",
    }
    output = Path(args.output)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        print(exc.stderr or str(exc), file=sys.stderr)
        raise SystemExit(exc.returncode)
