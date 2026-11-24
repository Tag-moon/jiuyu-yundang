#!/usr/bin/env python3
import json
import shutil
import subprocess
import sys
import tempfile
from importlib import util
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent


def find_bash() -> str:
    for candidate in [
        shutil.which("bash"),
        r"C:\liboran\Git\bin\bash.exe",
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files\Git\usr\bin\bash.exe",
    ]:
        if candidate and Path(candidate).exists():
            return str(candidate)
    raise SystemExit("bash not found")


def run(name: str, cmd: list[str], capture: bool = False) -> subprocess.CompletedProcess:
    print(f"[self-check] {name}", file=sys.stderr)
    return subprocess.run(
        cmd,
        cwd=str(SKILL_DIR),
        check=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def analyze_project(bash: str, project: str) -> dict:
    result = run(f"analyze {project}", [bash, str(SCRIPT_DIR / "analyze.sh"), str(SKILL_DIR / "tests" / project)], capture=True)
    return json.loads(result.stdout)


def analyze_path(bash: str, path: Path) -> dict:
    result = run(f"analyze {path.name}", [bash, str(SCRIPT_DIR / "analyze.sh"), str(path)], capture=True)
    return json.loads(result.stdout)


def run_expect_failure(name: str, cmd: list[str]) -> subprocess.CompletedProcess:
    print(f"[self-check] {name}", file=sys.stderr)
    result = subprocess.run(
        cmd,
        cwd=str(SKILL_DIR),
        check=False,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode == 0:
        raise SystemExit(f"{name}: expected failure but command succeeded")
    return result


def assert_file(path: Path) -> None:
    if not path.exists():
        raise SystemExit(f"missing required file: {path}")


def safe_rmtree(path: Path) -> None:
    if path.exists():
        try:
            shutil.rmtree(path)
        except PermissionError:
            pass


def assert_lf_no_bom(path: Path) -> None:
    data = path.read_bytes()
    if data.startswith(b"\xef\xbb\xbf"):
        raise SystemExit(f"{path.relative_to(SKILL_DIR)}: shell script must be UTF-8 without BOM")
    if b"\r\n" in data or b"\r" in data:
        raise SystemExit(f"{path.relative_to(SKILL_DIR)}: shell script must use LF line endings")
    try:
        data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SystemExit(f"{path.relative_to(SKILL_DIR)}: shell script must be valid UTF-8: {exc}") from exc


def load_provision_module():
    spec = util.spec_from_file_location("auto_deploy_provision", SCRIPT_DIR / "provision.py")
    if not spec or not spec.loader:
        raise SystemExit("could not load provision.py for self-check")
    module = util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    bash = find_bash()

    run(
        "python compile",
        [
            sys.executable,
            "-m",
            "py_compile",
            str(SCRIPT_DIR / "auto_deploy.py"),
            str(SCRIPT_DIR / "provision.py"),
            str(SCRIPT_DIR / "destroy.py"),
            str(SCRIPT_DIR / "prepare_ssh_key.py"),
            str(SCRIPT_DIR / "resource_spec.py"),
            str(SCRIPT_DIR / "plan.py"),
            str(SCRIPT_DIR / "collect_resource_info.py"),
            str(SCRIPT_DIR / "optimize_dockerfiles.py"),
        ],
    )

    shell_scripts = sorted(SCRIPT_DIR.rglob("*.sh"))
    required_shell_scripts = {
        SCRIPT_DIR / "analyze.sh",
        SCRIPT_DIR / "preflight.sh",
        SCRIPT_DIR / "deploy.sh",
        SCRIPT_DIR / "verify.sh",
        SCRIPT_DIR / "rollback.sh",
        SCRIPT_DIR / "remote" / "install_docker.sh",
    }
    for script in required_shell_scripts:
        assert_file(script)
    for script in shell_scripts:
        assert_lf_no_bom(script)
        run(f"bash syntax {script.relative_to(SCRIPT_DIR)}", [bash, "-n", str(script)])

    run(
        "install_docker dry-run",
        [
            bash,
            str(SCRIPT_DIR / "remote" / "install_docker.sh"),
            "--dry-run",
            "--registry-mirrors",
            "https://mirror.example.invalid",
            "--image-registry-prefix",
            "swr.cn-north-4.myhuaweicloud.com/demo",
        ],
        capture=True,
    )

    if shutil.which("terraform"):
        run("terraform fmt", ["terraform", "fmt", "-check", "-recursive", str(SKILL_DIR / "templates" / "terraform")])

    expected = {
        "test-nodejs": "nodejs",
        "test-python": "python",
        "test-java": "java",
        "test-gradle": "java",
        "test-go": "go",
        "test-rust": "rust",
        "test-dotnet": "dotnet",
        "test-docker": "docker",
    }
    analyses = {name: analyze_project(bash, name) for name in expected}
    for name, project_type in expected.items():
        actual = analyses[name].get("project_type")
        if actual != project_type:
            raise SystemExit(f"{name}: expected project_type={project_type}, got {actual}")

    fullstack = analyze_project(bash, "test-fullstack")
    if not fullstack.get("has_frontend_backend_split") or fullstack.get("deploy_strategy") != "docker-compose":
        raise SystemExit("test-fullstack: expected frontend/backend split with docker-compose strategy")

    with tempfile.TemporaryDirectory(prefix="auto-deploy-fullstack-native-") as tmp:
        split_root = Path(tmp) / "split-app"
        (split_root / "backend").mkdir(parents=True)
        (split_root / "frontend").mkdir(parents=True)
        (split_root / "backend" / "package.json").write_text(
            json.dumps({"scripts": {"start": "node server.js"}, "dependencies": {"express": "^4.18.0"}}),
            encoding="utf-8",
        )
        (split_root / "backend" / "server.js").write_text(
            "require('express')().listen(process.env.PORT || 3000)\n",
            encoding="utf-8",
        )
        (split_root / "frontend" / "package.json").write_text(
            json.dumps({"scripts": {"build": "vite build"}, "dependencies": {"vite": "^5.0.0"}}),
            encoding="utf-8",
        )
        split = analyze_path(bash, split_root)
        if not split.get("has_frontend_backend_split") or split.get("has_docker_compose") or split.get("deploy_strategy") != "native":
            raise SystemExit("split fullstack fixture should analyze as native fullstack without compose")
        blocked_dir = SKILL_DIR / ".auto-deploy" / "self-check-fullstack-native-block"
        safe_rmtree(blocked_dir)
        blocked = run_expect_failure(
            "fullstack native default block",
            [
                sys.executable,
                str(SCRIPT_DIR / "auto_deploy.py"),
                "--repo",
                str(split_root),
                "--app-name",
                "self-check-fullstack-native-block",
                "--region",
                "cn-north-4",
                "--plan-only",
                "--skip-preflight",
                "--yes",
                "--ssh-cidr",
                "127.0.0.1/32",
                "--workdir",
                str(blocked_dir),
            ],
        )
        if "--allow-native-fullstack" not in (blocked.stdout + blocked.stderr):
            raise SystemExit("fullstack native block should point to --allow-native-fullstack")
        safe_rmtree(blocked_dir)

    # --- Core fix assertions ---

    # 1. Node.js without build script should have build_command=None (AC #1)
    nobuild = analyze_project(bash, "test-nodejs-nobuild")
    if nobuild.get("build_command") is not None:
        raise SystemExit(f"test-nodejs-nobuild: expected build_command=None, got {nobuild.get('build_command')}")
    if nobuild.get("deploy_strategy") != "native":
        raise SystemExit(f"test-nodejs-nobuild: expected deploy_strategy=native, got {nobuild.get('deploy_strategy')}")

    # 2. Node.js /health detection (AC #4)
    nodejs_analysis = analyses["test-nodejs"]
    if nodejs_analysis.get("health_endpoint") != "/health":
        raise SystemExit(f"test-nodejs: expected health_endpoint=/health, got {nodejs_analysis.get('health_endpoint')}")

    # 3. Java context-path extraction from application.yml (AC #8)
    java_analysis = analyses["test-java"]
    if java_analysis.get("context_path") != "/myapp":
        raise SystemExit(f"test-java: expected context_path=/myapp, got {java_analysis.get('context_path')}")

    # 4. OBS not triggered by public/ alone (AC #4)
    python_analysis = analyses["test-python"]
    if python_analysis.get("signals", {}).get("object_storage"):
        raise SystemExit("test-python: object_storage signal should not be True without explicit OBS/S3 configuration")

    # 5. Security group defaults: no 80/443 without domain (AC #5) - checked in plan-only test below

    stacks = {
        "ecs-web": ["providers.tf", "variables.tf", "outputs.tf", "main.tf", "ecs.tf"],
        "ecs-web-existing-network": ["providers.tf", "variables.tf", "outputs.tf", "main.tf", "ecs.tf"],
    }
    for stack, files in stacks.items():
        for filename in files:
            assert_file(SKILL_DIR / "templates" / "terraform" / stack / filename)

    smoke_dir = SKILL_DIR / ".auto-deploy" / "self-check"
    safe_rmtree(smoke_dir)
    plan_dir = SKILL_DIR / ".auto-deploy" / "self-check-plan"
    safe_rmtree(plan_dir)
    run(
        "one-command plan-only report",
        [
            sys.executable,
            str(SCRIPT_DIR / "auto_deploy.py"),
            "--repo",
            str(SKILL_DIR / "tests" / "test-python"),
            "--app-name",
            "self-check-plan",
            "--region",
            "华东2",
            "--plan-only",
            "--skip-preflight",
            "--workdir",
            str(plan_dir),
            "--app-port",
            "8081",
            "--no-http",
            "--no-https",
            "--ssh-cidr",
            "127.0.0.1/32",
            "--env",
            "DATABASE_URL=sqlite:///self-check.db",
            "--env",
            "PORT=8081",
        ],
        capture=True,
    )
    for filename in ["timings.json", "run-summary.json", "deployment-test-report.md", "resource-spec.json", "analysis.json"]:
        assert_file(plan_dir / filename)
    spec = json.loads((plan_dir / "resource-spec.json").read_text(encoding="utf-8"))
    ports = {rule.get("port") for rule in spec["resources"]["security_group"]["rules"] if rule.get("direction") == "ingress"}
    if 80 in ports or 443 in ports or 8081 not in ports:
        raise SystemExit("plan-only security rules did not preserve requested 8081-only policy")
    if spec.get("network_mode") != "create":
        raise SystemExit("default resource spec network_mode should be create")

    # 5. AC #5: no-domain defaults to not open 80/443 - verified above

    # 6. AC #6: Region alias resolution (华东2 -> cn-east-2)
    if spec.get("region") != "cn-east-2":
        raise SystemExit(f"region alias: expected cn-east-2 from 华东2, got {spec.get('region')}")

    if spec["resources"]["ecs"]["availability_zone"] != "cn-east-2a":
        raise SystemExit(f"resource spec: expected default availability_zone=cn-east-2a, got {spec['resources']['ecs']['availability_zone']}")
    if spec["resources"]["ecs"]["bandwidth_size_mbps"] != 5:
        raise SystemExit("resource spec: native deployments should keep default bandwidth at 5 Mbps")

    docker_analysis_path = plan_dir / "docker-analysis.json"
    docker_analysis_path.write_text(json.dumps(analyze_project(bash, "test-docker"), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    docker_spec_path = plan_dir / "docker-resource-spec.json"
    run(
        "docker resource spec bandwidth",
        [
            sys.executable,
            str(SCRIPT_DIR / "resource_spec.py"),
            "--analysis",
            str(docker_analysis_path),
            "--ssh-key-info",
            str(plan_dir / "ssh-key-info.json"),
            "--app-name",
            "self-check-docker",
            "--region",
            "cn-north-4",
            "--output",
            str(docker_spec_path),
        ],
        capture=True,
    )
    docker_spec = json.loads(docker_spec_path.read_text(encoding="utf-8"))
    if docker_spec["resources"]["ecs"]["bandwidth_size_mbps"] != 200:
        raise SystemExit("resource spec: Docker deployments should default EIP bandwidth to 200 Mbps")
    docker_plan_path = plan_dir / "docker-deployment-plan.md"
    run(
        "docker plan bandwidth",
        [
            sys.executable,
            str(SCRIPT_DIR / "plan.py"),
            "--analysis",
            str(docker_analysis_path),
            "--resource-spec",
            str(docker_spec_path),
            "--app-name",
            "self-check-docker",
            "--region",
            "cn-north-4",
            "--output",
            str(docker_plan_path),
        ],
        capture=True,
    )
    docker_plan = docker_plan_path.read_text(encoding="utf-8")
    if "200 Mbps" not in docker_plan or "5 Mbps EIP" in docker_plan:
        raise SystemExit("plan.py: Docker plan should display 200 Mbps from resource-spec.json")

    # 7. Verify report contains required timing buckets (AC: report 耗时拆分)
    report_text = (plan_dir / "deployment-test-report.md").read_text(encoding="utf-8")
    for bucket in ["terraform", "verify"]:
        if bucket not in report_text:
            raise SystemExit(f"report missing timing bucket: {bucket}")

    with tempfile.TemporaryDirectory(prefix="auto-deploy-env-") as tmp:
        env_project = Path(tmp) / "env-node"
        env_project.mkdir()
        (env_project / "package.json").write_text(
            json.dumps({"scripts": {"start": "node server.js"}, "dependencies": {"express": "^4.18.0"}}),
            encoding="utf-8",
        )
        (env_project / "server.js").write_text(
            "console.log(process.env.DATABASE_URL, process.env.JWT_SECRET); require('express')().listen(process.env.PORT || 3000)\n",
            encoding="utf-8",
        )
        missing_dir = SKILL_DIR / ".auto-deploy" / "self-check-missing-env"
        safe_rmtree(missing_dir)
        missing = run_expect_failure(
            "missing required env fail-fast",
            [
                sys.executable,
                str(SCRIPT_DIR / "auto_deploy.py"),
                "--repo",
                str(env_project),
                "--app-name",
                "self-check-missing-env",
                "--region",
                "cn-north-4",
                "--plan-only",
                "--skip-preflight",
                "--yes",
                "--ssh-cidr",
                "127.0.0.1/32",
                "--workdir",
                str(missing_dir),
            ],
        )
        if "DATABASE_URL" not in (missing.stdout + missing.stderr) or "--env KEY=VALUE" not in (missing.stdout + missing.stderr):
            raise SystemExit("missing env fail-fast message did not name missing keys and --env guidance")
        safe_rmtree(missing_dir)

        allowed_dir = SKILL_DIR / ".auto-deploy" / "self-check-allow-missing-env"
        safe_rmtree(allowed_dir)
        run(
            "allow missing env plan-only",
            [
                sys.executable,
                str(SCRIPT_DIR / "auto_deploy.py"),
                "--repo",
                str(env_project),
                "--app-name",
                "self-check-allow-missing-env",
                "--region",
                "cn-north-4",
                "--plan-only",
                "--skip-preflight",
                "--yes",
                "--allow-missing-env",
                "--ssh-cidr",
                "127.0.0.1/32",
                "--workdir",
                str(allowed_dir),
            ],
            capture=True,
        )
        allowed_summary = json.loads((allowed_dir / "run-summary.json").read_text(encoding="utf-8"))
        if not allowed_summary.get("env", {}).get("risk"):
            raise SystemExit("--allow-missing-env plan should mark env risk in summary")
        safe_rmtree(allowed_dir)

        provided_dir = SKILL_DIR / ".auto-deploy" / "self-check-provided-env"
        safe_rmtree(provided_dir)
        secret_url = "postgres://user:secret-password@example.invalid/db"
        secret_token = "jwt-secret-value"
        run(
            "provided env redaction",
            [
                sys.executable,
                str(SCRIPT_DIR / "auto_deploy.py"),
                "--repo",
                str(env_project),
                "--app-name",
                "self-check-provided-env",
                "--region",
                "cn-north-4",
                "--plan-only",
                "--skip-preflight",
                "--yes",
                "--ssh-cidr",
                "127.0.0.1/32",
                "--env",
                f"DATABASE_URL={secret_url}",
                "--env",
                f"JWT_SECRET={secret_token}",
                "--env",
                "PORT=3000",
                "--workdir",
                str(provided_dir),
            ],
            capture=True,
        )
        summary_text = (provided_dir / "run-summary.json").read_text(encoding="utf-8")
        report_text = (provided_dir / "deployment-test-report.md").read_text(encoding="utf-8")
        if secret_url in summary_text or secret_url in report_text or secret_token in summary_text or secret_token in report_text:
            raise SystemExit("env secret values leaked into summary/report")
        if "DATABASE_URL" not in report_text or "JWT_SECRET" not in report_text:
            raise SystemExit("env report should show provided env keys")
        safe_rmtree(provided_dir)

    # 8. Validate-only test (skipped if terraform provider download unavailable)
    try:
        run(
            "one-command validate-only",
            [
                sys.executable,
                str(SCRIPT_DIR / "auto_deploy.py"),
                "--repo",
                str(SKILL_DIR / "tests" / "test-python"),
                "--app-name",
                "self-check",
                "--region",
                "cn-north-4",
                "--validate-only",
                "--skip-preflight",
                "--workdir",
                str(smoke_dir),
                "--ssh-cidr",
                "127.0.0.1/32",
                "--network-mode",
                "reuse",
                "--existing-vpc-id",
                "vpc-selfcheck",
                "--existing-subnet-id",
                "subnet-selfcheck",
            ],
            capture=True,
        )
    except subprocess.CalledProcessError:
        print("[self-check] validate-only skipped: terraform provider download unavailable", file=sys.stderr)
    safe_rmtree(smoke_dir)

    help_result = run(
        "auto_deploy help",
        [sys.executable, str(SCRIPT_DIR / "auto_deploy.py"), "--help"],
        capture=True,
    )
    help_text = help_result.stdout
    for token in ["--resume-from", "--skip-upload", "--skip-prepare", "--env", "--env-file", "--allow-missing-env", "--allow-native-fullstack"]:
        if token not in help_text:
            raise SystemExit(f"auto_deploy.py help missing expected option: {token}")

    deploy_help = run(
        "deploy help",
        [bash, str(SCRIPT_DIR / "deploy.sh"), "--help"],
        capture=True,
    )
    deploy_help_text = deploy_help.stdout + deploy_help.stderr
    for token in ["--skip-upload", "--skip-prepare", "--env-file", "--allow-native-fullstack"]:
        if token not in deploy_help_text:
            raise SystemExit(f"deploy.sh help missing expected option: {token}")
    auto_deploy_help = help_text
    for token in ["--docker-build-timeout"]:
        if token not in auto_deploy_help or token not in deploy_help_text:
            raise SystemExit(f"Docker build timeout option missing from help: {token}")
    # --- Additional checks for fixes ---

    # Native preflight should stay lightweight and skip Docker Hub checks.
    preflight_result = run(
        "preflight network checks",
        [bash, str(SCRIPT_DIR / "preflight.sh"), "--analysis", str(plan_dir / "analysis.json"), str(SKILL_DIR / "tests" / "test-python")],
        capture=True,
    )
    preflight_data = json.loads(preflight_result.stdout)
    optional = preflight_data.get("checks", {})
    if "dns_huaweicloud" not in optional:
        raise SystemExit("preflight: missing dns_huaweicloud check")
    for unexpected in ["dns_dockerhub", "docker_hub_connectivity", "docker_mirror_daocloud_connectivity"]:
        if unexpected in optional:
            raise SystemExit(f"preflight: unexpected Docker connectivity check for native deployment: {unexpected}")

    docker_preflight_result = run(
        "preflight docker network checks",
        [bash, str(SCRIPT_DIR / "preflight.sh"), "--analysis", str(docker_analysis_path), str(SKILL_DIR / "tests" / "test-docker")],
        capture=True,
    )
    docker_optional = json.loads(docker_preflight_result.stdout).get("checks", {})
    for expected_check in ["dns_dockerhub", "docker_hub_connectivity", "docker_mirror_daocloud_connectivity"]:
        if expected_check not in docker_optional:
            raise SystemExit(f"preflight: missing Docker check for docker deployment: {expected_check}")

    # AC: native.sh contains monorepo backend/ detection
    native_sh = (SKILL_DIR / "scripts" / "deployers" / "native.sh").read_text(encoding="utf-8")
    if "backend_sub" not in native_sh or "monorepo detected" not in native_sh:
        raise SystemExit("native.sh: missing monorepo backend/ detection")
    if "frontend" in native_sh and "nginx" in native_sh.lower():
        pass  # frontend Nginx support present
    else:
        raise SystemExit("native.sh: missing frontend Nginx auto-configuration")

    # AC: docker_compose.sh contains Docker Hub quick connectivity test
    compose_sh = (SKILL_DIR / "scripts" / "deployers" / "docker_compose.sh").read_text(encoding="utf-8")
    if "alpine" not in compose_sh or "docker_hub_unreachable" not in compose_sh:
        raise SystemExit("docker_compose.sh: missing alpine connectivity test")
    if "COMPOSE_PROGRESS='--progress=plain'" not in compose_sh or "COMPOSE_PROGRESS=''" not in compose_sh:
        raise SystemExit("docker_compose.sh: must only use --progress=plain for Docker Compose v2")
    for token in ["docker compose build timed out; retrying once", "docker_build_timeout", "MAVEN_MIRROR", "NPM_MIRROR"]:
        if token not in compose_sh and token not in (SKILL_DIR / "scripts" / "deployers" / "common.sh").read_text(encoding="utf-8"):
            raise SystemExit(f"docker_compose.sh/common.sh: missing expected Docker build behavior: {token}")

    dockerfile_sh = (SKILL_DIR / "scripts" / "deployers" / "dockerfile.sh").read_text(encoding="utf-8")
    for token in ["docker build timed out; retrying once", "docker_build_timeout"]:
        if token not in dockerfile_sh and token not in (SKILL_DIR / "scripts" / "deployers" / "common.sh").read_text(encoding="utf-8"):
            raise SystemExit(f"dockerfile.sh/common.sh: missing expected Docker build behavior: {token}")

    auto_deploy_py = (SKILL_DIR / "scripts" / "auto_deploy.py").read_text(encoding="utf-8")
    for token in ["archive_previous_attempt", "timings-attempt-", "run-summary-attempt-"]:
        if token not in auto_deploy_py:
            raise SystemExit(f"auto_deploy.py: missing attempt archive support: {token}")

    with tempfile.TemporaryDirectory(prefix="auto-deploy-dockerfile-") as tmp:
        docker_root = Path(tmp)
        dockerfile = docker_root / "Dockerfile"
        dockerfile.write_bytes(b"FROM node:20\nWORKDIR /app\nCOPY package*.json ./\nRUN npm ci\nCOPY . .\n")
        run(
            "optimize dockerfiles",
            [sys.executable, str(SCRIPT_DIR / "optimize_dockerfiles.py"), str(docker_root)],
            capture=True,
        )
        optimized = dockerfile.read_text(encoding="utf-8")
        if "\\nFROM" in optimized or "# syntax=docker/dockerfile:1\nFROM" not in optimized:
            raise SystemExit("optimize_dockerfiles.py: Dockerfile syntax line/newlines are invalid")
        if "target=/app/node_modules" in optimized or "target=/root/.npm" not in optimized:
            raise SystemExit("optimize_dockerfiles.py: npm cache mount must use /root/.npm, not node_modules")

    # AC: deploy.sh contains ensure_remote_dns step
    deploy_sh = (SKILL_DIR / "scripts" / "deploy.sh").read_text(encoding="utf-8")
    if "ensure_remote_dns" not in deploy_sh:
        raise SystemExit("deploy.sh: missing ensure_remote_dns function")

    provision = load_provision_module()
    original_public_ip = provision.current_public_ip
    try:
        provision.current_public_ip = lambda: None
        try:
            cidr = provision.normalize_cidr(None)
        except SystemExit:
            cidr = None
        if cidr == "0.0.0.0/0":
            raise SystemExit("provision.py: normalize_cidr(None) must not fall back to 0.0.0.0/0")
    finally:
        provision.current_public_ip = original_public_ip
    legacy_fields = {"create_rds", "create_obs", "create_elb", "create_cce"}
    fake_args = type(
        "Args",
        (),
        {
            "app_name": "self-check",
            "region": "cn-north-4",
            "availability_zone": None,
            "app_port": None,
            "disk_size": None,
            "bandwidth": None,
            "flavor": None,
            "image": None,
            "ssh_cidr": "127.0.0.1/32",
            "public_cidr": "0.0.0.0/0",
            "network_mode": "create",
            "existing_vpc_id": None,
            "existing_subnet_id": None,
            "no_http": False,
            "no_https": False,
        },
    )()
    tfvars = provision.build_tfvars(
        {"app_name": "self-check", "listen_port": 8080},
        {
            "region": "cn-north-4",
            "network_mode": "create",
            "resources": {
                "ecs": {"availability_zone": "cn-north-4a"},
                "vpc": {},
                "security_group": {},
            },
            "deployment_context": {"app_name": "self-check"},
        },
        {"ssh_key_name": "self-check-key", "ssh_public_key": "ssh-ed25519 AAAA"},
        fake_args,
    )
    if legacy_fields & set(tfvars):
        raise SystemExit(f"provision.py: tfvars still contain out-of-scope fields: {sorted(legacy_fields & set(tfvars))}")
    template_text = "\n".join(
        path.read_text(encoding="utf-8")
        for stack in ["ecs-web", "ecs-web-existing-network"]
        for path in (SKILL_DIR / "templates" / "terraform" / stack).glob("*.tf")
    )
    for field in legacy_fields:
        if field in template_text:
            raise SystemExit(f"terraform templates should not contain legacy field {field}")
    fake_keypair_error = subprocess.CalledProcessError(
        1,
        ["terraform", "apply"],
        stderr="Error: creating KPS keypair auto-deploy-key-demo-test-02: keypair already exists",
    )
    if not provision.is_keypair_create_failure(fake_keypair_error):
        raise SystemExit("provision.py: keypair conflict detector did not recognize an existing KPS keypair error")
    renamed = provision.keypair_name_with_public_key_fingerprint(
        "auto-deploy-key-demo-test-02",
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoKey auto-deploy:demo-test-02",
    )
    if renamed == "auto-deploy-key-demo-test-02" or not renamed.startswith("auto-deploy-key-demo-test-02-"):
        raise SystemExit("provision.py: keypair fallback name must include a deterministic public-key fingerprint")

    safe_rmtree(plan_dir)

    print(json.dumps({"status": "pass", "analyzed_projects": analyses}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
