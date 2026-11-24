#!/usr/bin/env python3
import os
import subprocess
import sys


HUAWEI_ENV_NAMES = [
    "HW_ACCESS_KEY",
    "HW_SECRET_KEY",
    "HW_SECURITY_TOKEN",
    "HW_REGION_NAME",
    "HUAWEICLOUD_ACCESS_KEY",
    "HUAWEICLOUD_SECRET_KEY",
    "HUAWEICLOUD_SECURITY_TOKEN",
]


def _windows_user_env(name: str) -> str | None:
    if os.name != "nt":
        return None
    try:
        result = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-Command",
                f"[Environment]::GetEnvironmentVariable('{name}', 'User')",
            ],
            check=False,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None
    value = result.stdout.strip()
    return value or None


def merged_env() -> dict:
    env = os.environ.copy()
    for name in HUAWEI_ENV_NAMES:
        if not env.get(name):
            value = _windows_user_env(name)
            if value:
                env[name] = value
    if not env.get("HW_ACCESS_KEY") and env.get("HUAWEICLOUD_ACCESS_KEY"):
        env["HW_ACCESS_KEY"] = env["HUAWEICLOUD_ACCESS_KEY"]
    if not env.get("HW_SECRET_KEY") and env.get("HUAWEICLOUD_SECRET_KEY"):
        env["HW_SECRET_KEY"] = env["HUAWEICLOUD_SECRET_KEY"]
    if not env.get("HW_SECURITY_TOKEN") and env.get("HUAWEICLOUD_SECURITY_TOKEN"):
        env["HW_SECURITY_TOKEN"] = env["HUAWEICLOUD_SECURITY_TOKEN"]
    return env


def has_credentials(env: dict | None = None) -> bool:
    active = env or merged_env()
    return bool(active.get("HW_ACCESS_KEY")) and bool(active.get("HW_SECRET_KEY"))


if __name__ == "__main__":
    env = merged_env()
    status = {name: bool(env.get(name)) for name in HUAWEI_ENV_NAMES}
    sys.stdout.write(str(status) + "\n")
