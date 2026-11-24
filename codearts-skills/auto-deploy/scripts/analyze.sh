#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
if [[ ! -d "$ROOT" ]]; then
  echo "{\"error\":\"repository path not found: $ROOT\"}" >&2
  exit 2
fi

python3 - "$ROOT" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()

def exists(*parts):
    return (root.joinpath(*parts)).exists()

def read_text(path):
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""

def find_files(names):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in {".git", "node_modules", ".venv", "venv", "target", "build", "dist", "__pycache__"}]
        for filename in filenames:
            if filename in names:
                found.append(Path(dirpath) / filename)
    return found

def find_files_by_suffix(suffixes, limit=35):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in {".git", "node_modules", ".venv", "venv", "target", "build", "dist", "__pycache__"}]
        for filename in filenames:
            if filename.endswith(tuple(suffixes)):
                found.append(Path(dirpath) / filename)
                if len(found) >= limit:
                    return found
    return found

def first_regex(patterns, text):
    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE | re.MULTILINE)
        if match:
            return match.group(1) if match.groups() else match.group(0)
    return None

def package_json_info(path):
    if not path.exists():
        return {}, {}, {}
    try:
        pkg = json.loads(read_text(path))
    except Exception:
        return {}, {}, {}
    scripts = pkg.get("scripts", {}) if isinstance(pkg, dict) else {}
    deps = {}
    if isinstance(pkg, dict):
        for key in ("dependencies", "devDependencies", "optionalDependencies"):
            value = pkg.get(key, {})
            if isinstance(value, dict):
                deps.update(value)
    return pkg, scripts, deps

def java_info(base):
    has_maven = (base / "pom.xml").exists()
    has_gradle = (base / "build.gradle").exists() or (base / "build.gradle.kts").exists()
    text = read_text(base / "pom.xml") + "\n" + read_text(base / "build.gradle") + "\n" + read_text(base / "build.gradle.kts")
    framework_name = "spring-boot" if "spring-boot" in text.lower() else ("spring-cloud" if "spring-cloud" in text.lower() else "java")
    return {
        "path": base.relative_to(root).as_posix() if base != root else ".",
        "project_type": "java",
        "framework": framework_name,
        "build_command": "mvn clean package -DskipTests" if has_maven else ("./gradlew build" if (base / "gradlew").exists() else "gradle build"),
        "start_command": "java -jar target/*.jar" if has_maven else "java -jar build/libs/*.jar",
        "artifacts_path": "target/" if has_maven else "build/libs/",
    }

def python_info(base):
    req = read_text(base / "requirements.txt") + "\n" + read_text(base / "pyproject.toml")
    low = req.lower()
    framework_name = "python"
    start = None
    if "fastapi" in low:
        framework_name = "fastapi"
        start = "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000}"
    elif "flask" in low:
        framework_name = "flask"
        start = "flask run --host 0.0.0.0 --port ${PORT:-5000}"
    elif "django" in low:
        framework_name = "django"
        start = "python manage.py runserver 0.0.0.0:${PORT:-8000}"
    return {
        "path": base.relative_to(root).as_posix() if base != root else ".",
        "project_type": "python",
        "framework": framework_name,
        "build_command": None,
        "start_command": start,
        "artifacts_path": ".",
    }

def node_info(base):
    pkg, scripts, deps = package_json_info(base / "package.json")
    dep_names = set(deps)
    framework_name = "nodejs"
    artifacts = None
    if "next" in dep_names:
        framework_name, artifacts = "next", ".next/"
    elif "nuxt" in dep_names or "nuxt3" in dep_names:
        framework_name, artifacts = "nuxt", ".output/"
    elif "vite" in dep_names or "@vitejs/plugin-react" in dep_names or "react" in dep_names or "vue" in dep_names:
        framework_name, artifacts = "vite", "dist/"
    elif "@nestjs/core" in dep_names:
        framework_name, artifacts = "nest", "dist/"
    elif "koa" in dep_names:
        framework_name = "koa"
    elif "express" in dep_names:
        framework_name = "express"
    return {
        "path": base.relative_to(root).as_posix() if base != root else ".",
        "project_type": "nodejs",
        "framework": framework_name,
        "build_command": "npm run build" if "build" in scripts else None,
        "start_command": "npm start" if "start" in scripts else ("node server.js" if (base / "server.js").exists() else None),
        "artifacts_path": artifacts,
    }

project_type = "unknown"
language = "unknown"
runtime = "unknown"
framework = "unknown"
build_command = None
start_command = None
artifacts_path = None
dependencies_count = 0
estimated = 60

package_json = root / "package.json"
if package_json.exists():
    project_type = "nodejs"
    language = "javascript"
    runtime = "nodejs@18.x"
    pkg, scripts, deps = package_json_info(package_json)
    dependencies_count = len(deps)
    if pkg.get("engines", {}).get("node"):
        runtime = f"nodejs@{pkg['engines']['node']}"
    dep_names = set(deps)
    if "next" in dep_names:
        framework, artifacts_path = "next", ".next/"
    elif "nuxt" in dep_names or "nuxt3" in dep_names:
        framework, artifacts_path = "nuxt", ".output/"
    elif "vite" in dep_names or "@vitejs/plugin-react" in dep_names:
        framework, artifacts_path = "vite", "dist/"
    elif "@nestjs/core" in dep_names:
        framework, artifacts_path = "nest", "dist/"
    elif "koa" in dep_names:
        framework = "koa"
    elif "express" in dep_names:
        framework = "express"
    build_command = "npm run build" if "build" in scripts else None
    start_command = "npm start" if "start" in scripts else ("node server.js" if exists("server.js") else None)
    estimated = 120 if build_command else 60

elif exists("requirements.txt") or exists("pyproject.toml"):
    project_type = "python"
    language = "python"
    runtime = "python@3.10+"
    req = read_text(root / "requirements.txt") + "\n" + read_text(root / "pyproject.toml")
    dependencies_count = len([line for line in req.splitlines() if line.strip() and not line.strip().startswith("#")])
    low = req.lower()
    if "fastapi" in low:
        framework = "fastapi"
        start_command = "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000}"
    elif "flask" in low:
        framework = "flask"
        start_command = "flask run --host 0.0.0.0 --port ${PORT:-5000}"
    elif "django" in low:
        framework = "django"
        start_command = "python manage.py runserver 0.0.0.0:${PORT:-8000}"
    elif "tornado" in low:
        framework = "tornado"
    build_command = None
    artifacts_path = "."
    estimated = 90

elif exists("pom.xml") or exists("build.gradle") or exists("build.gradle.kts"):
    project_type = "java"
    language = "java"
    runtime = "jdk@17"
    text = read_text(root / "pom.xml") + "\n" + read_text(root / "build.gradle")
    dependencies_count = len(re.findall(r"<dependency\b|implementation\s+['\"]|compileOnly\s+['\"]", text))
    if "spring-boot" in text.lower():
        framework = "spring-boot"
        start_command = "java -jar target/*.jar" if exists("pom.xml") else "java -jar build/libs/*.jar"
        artifacts_path = "target/" if exists("pom.xml") else "build/libs/"
    elif "spring-cloud" in text.lower():
        framework = "spring-cloud"
    build_command = "mvn clean package -DskipTests" if exists("pom.xml") else ("./gradlew build" if exists("gradlew") else "gradle build")
    estimated = 240

elif exists("go.mod"):
    project_type = "go"
    language = "go"
    runtime = "go@1.22+"
    dependencies_count = len(re.findall(r"^\s*[A-Za-z0-9_.\-/]+ v[0-9]", read_text(root / "go.mod"), re.M))
    build_command = "go build -o app ."
    start_command = "./app"
    artifacts_path = "app"

elif exists("Cargo.toml"):
    project_type = "rust"
    language = "rust"
    runtime = "rust@stable"
    cargo_text = read_text(root / "Cargo.toml")
    package_name = first_regex([r"^\s*name\s*=\s*[\"']([^\"']+)[\"']"], cargo_text) or "app"
    build_command = "cargo build --release"
    start_command = f"./target/release/{package_name}"
    artifacts_path = "target/release/"

else:
    csproj = list(root.glob("*.csproj")) or list(root.glob("*/*.csproj"))
    if csproj:
        rel_csproj = csproj[0].relative_to(root).as_posix()
        project_type = "dotnet"
        language = "csharp"
        runtime = "dotnet@8"
        build_command = f"dotnet publish {rel_csproj} -c Release -o publish"
        dll_name = csproj[0].stem
        start_command = f"dotnet publish/{dll_name}.dll"
        artifacts_path = "publish/"

has_compose = exists("docker-compose.yml") or exists("docker-compose.yaml") or exists("compose.yml") or exists("compose.yaml")
has_dockerfile = exists("Dockerfile")
if project_type == "unknown" and (has_compose or has_dockerfile):
    project_type = "docker"
    language = "container"
    runtime = "docker"
    framework = "container"

texts = []
for name in ["server.js", "app.js", "index.js", "main.py", "app.py", "application.yml", "application.yaml", "application.properties", "Dockerfile", "docker-compose.yml", "docker-compose.yaml"]:
    p = root / name
    if p.exists():
        texts.append(read_text(p))
for p in find_files({"server.js", "app.js", "index.js", "main.py", "app.py", "application.yml", "application.yaml", "application.properties"}):
    if len(texts) > 30:
        break
    texts.append(read_text(p))
for p in find_files_by_suffix({".java", ".go", ".rs", ".cs"}, limit=60):
    texts.append(read_text(p))
all_text = "\n".join(texts)

if has_compose:
    deploy_strategy = "docker-compose"
elif project_type == "unknown" and has_dockerfile:
    deploy_strategy = "docker"
else:
    deploy_strategy = "native"

modules = {}
backend_candidates = [root / "backend", root / "api", root / "server"]
frontend_candidates = [root / "frontend", root / "web", root / "client", root / "ui"]
for base in backend_candidates:
    if (base / "pom.xml").exists() or (base / "build.gradle").exists() or (base / "build.gradle.kts").exists():
        modules["backend"] = java_info(base)
        break
    if (base / "requirements.txt").exists() or (base / "pyproject.toml").exists():
        modules["backend"] = python_info(base)
        break
    if (base / "package.json").exists():
        modules["backend"] = node_info(base)
        break
for base in frontend_candidates:
    if (base / "package.json").exists():
        modules["frontend"] = node_info(base)
        break
if modules.get("backend") and modules.get("frontend"):
    project_type = "fullstack"
    language = "multi"
    runtime = f"{modules['backend'].get('project_type')} + nodejs"
    framework = f"{modules['backend'].get('framework')} + {modules['frontend'].get('framework')}"
    build_command = None
    start_command = modules["backend"].get("start_command")
    artifacts_path = None
    estimated = 360

compose_services = []
for compose_name in ("docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"):
    compose_path = root / compose_name
    if compose_path.exists():
        compose_text = read_text(compose_path)
        all_text += "\n" + compose_text
        in_services = False
        for line in compose_text.splitlines():
            if re.match(r"^services\s*:", line):
                in_services = True
                continue
            if in_services:
                match = re.match(r"^\s{2}([A-Za-z0-9_.-]+)\s*:", line)
                if match:
                    compose_services.append(match.group(1))

k8s_files = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in {".git", "node_modules", ".venv", "venv", "target", "build", "dist", "__pycache__"}]
    path = Path(dirpath)
    if path.name in {"helm", "charts"} or (path / "Chart.yaml").exists() or (path / "kustomization.yaml").exists() or (path / "skaffold.yaml").exists():
        k8s_files.append(path.relative_to(root).as_posix())
    for filename in filenames:
        if filename in {"kustomization.yaml", "skaffold.yaml", "Chart.yaml"} or filename.endswith((".k8s.yaml", ".k8s.yml")):
            k8s_files.append((path / filename).relative_to(root).as_posix())

static_asset_dirs = []
for dirname in ("uploads", "upload", "static", "public", "assets", "media"):
    if (root / dirname).exists():
        static_asset_dirs.append(dirname)
    for module_name, module in modules.items():
        module_path = root / module.get("path", ".")
        if (module_path / dirname).exists():
            static_asset_dirs.append(f"{module.get('path')}/{dirname}")

port = first_regex([
    r"server\.port\s*[:=]\s*([0-9]{2,5})",
    r"PORT\s*[:=]\s*['\"]?([0-9]{2,5})",
    r"listen\s*\(\s*(?:process\.env\.PORT\s*\|\|\s*)?([0-9]{2,5})",
    r"--port\s+\$?\{?PORT:?-?([0-9]{2,5})",
    r"EXPOSE\s+([0-9]{2,5})",
], all_text)
if port:
    listen_port = int(port)
elif framework in {"next", "nuxt", "express", "nest", "koa"}:
    listen_port = 3000
elif framework == "flask":
    listen_port = 5000
elif framework in {"fastapi", "django"}:
    listen_port = 8000
elif framework in {"spring-boot", "spring-cloud"}:
    listen_port = 8080
else:
    listen_port = 8080

context_path = first_regex([r"server\.servlet\.context-path\s*[:=]\s*[\"']?([^\"'\s]+)", r"(?m)^\s+context-path\s*[:=]\s*[\"']?([^\"'\s]+)"], all_text)

health_endpoint = None
root_health_patterns = [
    ("/health", r"\b(?:app|server|fastify)\.(?:get|route)\s*\(\s*['\"]\/health['\"]|http\.HandleFunc\s*\(\s*['\"]\/health['\"]|MapGet\s*\(\s*['\"]\/health['\"]|@GetMapping\s*\(\s*['\"]\/health['\"]"),
    ("/healthz", r"\b(?:app|server|fastify)\.(?:get|route)\s*\(\s*['\"]\/healthz['\"]|http\.HandleFunc\s*\(\s*['\"]\/healthz['\"]|MapGet\s*\(\s*['\"]\/healthz['\"]|@GetMapping\s*\(\s*['\"]\/healthz['\"]"),
    ("/ping", r"\b(?:app|server|fastify)\.(?:get|route)\s*\(\s*['\"]\/ping['\"]|http\.HandleFunc\s*\(\s*['\"]\/ping['\"]|MapGet\s*\(\s*['\"]\/ping['\"]|@GetMapping\s*\(\s*['\"]\/ping['\"]"),
]
for endpoint, pattern in root_health_patterns:
    if re.search(pattern, all_text, re.IGNORECASE):
        health_endpoint = endpoint
        break
if not health_endpoint and re.search(r"['\"]\/actuator\/health['\"]|@GetMapping\s*\(\s*['\"]\/actuator\/health['\"]", all_text, re.IGNORECASE):
    health_endpoint = "/actuator/health"
if not health_endpoint:
    api_router_bound = re.search(r"\bapp\.use\s*\(\s*['\"]\/api['\"]\s*,\s*\w*router", all_text, re.IGNORECASE)
    router_health = re.search(r"\brouter\.(?:get|route)\s*\(\s*['\"]\/health['\"]", all_text, re.IGNORECASE)
    if api_router_bound and router_health:
        health_endpoint = "/api/health"
if not health_endpoint and "/api/health" in all_text:
    health_endpoint = "/api/health"
if not health_endpoint:
    for candidate in ["/healthz", "/health", "/ping"]:
        if candidate in all_text:
            health_endpoint = candidate
            break
if not health_endpoint:
    health_endpoint = "/actuator/health" if framework in {"spring-boot", "spring-cloud"} else "/"

env_vars = set()
env_example = root / ".env.example"
if env_example.exists():
    for line in read_text(env_example).splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            env_vars.add(line.split("=", 1)[0].strip())
for match in re.findall(r"(?:process\.env\.|os\.environ\.get\(|getenv\(['\"])([A-Z][A-Z0-9_]{2,})", all_text):
    env_vars.add(match)

signals = {
    "database": bool(
        {"DATABASE_URL", "JDBC_URL", "SPRING_DATASOURCE_URL", "DB_HOST", "DB_URL"} & env_vars
        or re.search(r"spring\.datasource\.|jdbc:|DATABASE_URL", all_text, re.IGNORECASE)
    ),
    "object_storage": bool(re.search(r"\b(upload(?:s|_dir|Dir| path)?|object storage|obs bucket|obs endpoint|s3 bucket|s3 endpoint|aws-sdk|@aws-sdk/client-s3|huaweicloud-sdk|huaweicloudsdkobs|boto3)\b", all_text, re.IGNORECASE)),
    "kubernetes": bool(k8s_files),
    "high_availability": bool(re.search(r"\b(high availability|ha|multi[- ]?replica|replicas:\s*[2-9])\b", all_text, re.IGNORECASE)),
}

result = {
    "app_name": re.sub(r"[^a-z0-9-]+", "-", root.name.lower()).strip("-") or "app",
    "project_root": str(root),
    "project_type": project_type,
    "language": language,
    "runtime": runtime,
    "framework": framework,
    "deploy_strategy": deploy_strategy,
    "build_command": build_command,
    "start_command": start_command,
    "artifacts_path": artifacts_path,
    "listen_port": listen_port,
    "health_endpoint": health_endpoint,
    "context_path": context_path,
    "required_env_vars": sorted(env_vars),
    "has_dockerfile": has_dockerfile,
    "has_docker_compose": has_compose,
    "modules": modules,
    "has_frontend_backend_split": bool(modules.get("backend") and modules.get("frontend")),
    "docker_compose_services": sorted(set(compose_services)),
    "kubernetes": {"detected": bool(k8s_files), "paths": sorted(set(k8s_files))},
    "static_asset_dirs": sorted(set(static_asset_dirs)),
    "signals": signals,
    "dependencies_count": dependencies_count,
    "estimated_build_time_seconds": estimated,
}
print(json.dumps(result, ensure_ascii=False, indent=2))
PY
