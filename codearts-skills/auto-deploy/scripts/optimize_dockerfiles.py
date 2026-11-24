#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def cache_mount_for(command: str) -> str:
    lowered = command.lower()
    if "mvn " in lowered or lowered.startswith("mvn") or " mvn" in lowered:
        return "--mount=type=cache,target=/root/.m2/repository"
    if "gradle " in lowered or "./gradlew" in lowered or lowered.startswith("gradle"):
        return "--mount=type=cache,target=/root/.gradle/caches"
    if any(token in lowered for token in ("npm ci", "npm install")):
        return "--mount=type=cache,target=/root/.npm"
    if "yarn " in lowered:
        return "--mount=type=cache,target=/usr/local/share/.cache/yarn"
    if "pnpm " in lowered:
        return "--mount=type=cache,target=/root/.local/share/pnpm/store"
    return ""


def dockerfiles_under(root: Path) -> list[Path]:
    return [
        path
        for path in root.rglob("Dockerfile")
        if ".git" not in path.parts and path.is_file()
    ]


def optimize(path: Path) -> bool:
    text = path.read_text(encoding="utf-8-sig", errors="ignore")
    if "--mount=type=cache" in text:
        return False

    lines = text.splitlines()
    from_indexes = [i for i, line in enumerate(lines) if line.strip().lower().startswith("from ")]
    last_from = from_indexes[-1] if from_indexes else len(lines)
    changed = False
    output: list[str] = []
    has_syntax = any(line.strip().startswith("# syntax=") for line in lines[:5])
    if not has_syntax:
        output.append("# syntax=docker/dockerfile:1")

    for idx, line in enumerate(lines):
        stripped = line.strip()
        lowered = stripped.lower()
        should_optimize_run = lowered.startswith("run ") and (len(from_indexes) <= 1 or idx < last_from)
        if should_optimize_run:
            command = stripped[4:].strip()
            mount = cache_mount_for(command)
            if mount and "--mount=type=cache" not in lowered:
                indent = line[: len(line) - len(line.lstrip())]
                output.append(f"{indent}RUN {mount} {command}")
                changed = True
                continue
        output.append(line)

    if not changed:
        return False

    backup = path.with_name(path.name + ".auto-deploy.bak")
    if not backup.exists():
        backup.write_text(text, encoding="utf-8")
    path.write_text("\n".join(output) + "\n", encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Conservatively add BuildKit cache mounts to Dockerfiles.")
    parser.add_argument("root", nargs="?", default=".")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    changed = []
    for dockerfile in dockerfiles_under(root):
        try:
            if optimize(dockerfile):
                changed.append(str(dockerfile.relative_to(root)))
        except Exception as exc:
            print(f"[auto-deploy] Dockerfile cache optimization skipped for {dockerfile}: {exc}")

    if changed:
        print("[auto-deploy] optimized Dockerfile cache mounts: " + ", ".join(changed))
    else:
        print("[auto-deploy] no Dockerfile cache optimization needed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
