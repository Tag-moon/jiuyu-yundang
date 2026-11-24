#!/usr/bin/env python3
import argparse
import hashlib
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

from env_utils import has_credentials, merged_env
from hw_cloud_api import HwCloudAPIError, HwCloudFlavorAPI, HwCloudVPCAPI
from resource_spec import resolve_az, resolve_flavor


SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
TEMPLATE_ROOT = SKILL_DIR / "templates" / "terraform"


def slug(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9-]+", "-", value.strip().lower()).strip("-") or "app"


def load_json(path: str) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def terraform_env(workdir: Path) -> dict:
    env = merged_env()
    if not env.get("HW_ACCESS_KEY") and env.get("HUAWEICLOUD_ACCESS_KEY"):
        env["HW_ACCESS_KEY"] = env["HUAWEICLOUD_ACCESS_KEY"]
    if not env.get("HW_SECRET_KEY") and env.get("HUAWEICLOUD_SECRET_KEY"):
        env["HW_SECRET_KEY"] = env["HUAWEICLOUD_SECRET_KEY"]
    if not env.get("HW_SECURITY_TOKEN") and env.get("HUAWEICLOUD_SECURITY_TOKEN"):
        env["HW_SECURITY_TOKEN"] = env["HUAWEICLOUD_SECURITY_TOKEN"]
    if env.get("HW_SECURITY_TOKEN"):
        env["TF_VAR_security_token"] = env["HW_SECURITY_TOKEN"]
    env["TF_CLI_CONFIG_FILE"] = str(workdir / ".tfrc")
    return env


def run(cmd: list[str], cwd: Path, env: dict, capture: bool = False) -> subprocess.CompletedProcess:
    print(f"[auto-deploy] {' '.join(cmd)}", file=sys.stderr)
    return subprocess.run(
        cmd,
        cwd=str(cwd),
        env=env,
        check=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def current_public_ip() -> str | None:
    endpoints = [
        "https://api.ipify.org",
        "https://ifconfig.me/ip",
    ]
    for url in endpoints:
        try:
            with urllib.request.urlopen(url, timeout=6) as response:
                value = response.read().decode("utf-8").strip()
            ipaddress.ip_address(value)
            return value
        except Exception:
            continue
    return None


def normalize_cidr(value: str | None) -> str:
    if value:
        network = ipaddress.ip_network(value, strict=False)
        return str(network)
    detected = current_public_ip()
    if detected:
        return f"{detected}/32"
    raise SystemExit(
        "Could not detect this control machine's public IP. Provide --ssh-cidr x.x.x.x/32. "
        "Use --ssh-cidr 0.0.0.0/0 only if you intentionally want SSH open to the internet."
    )


def gateway_for_subnet(subnet_cidr: str, explicit_gateway: str | None = None) -> str:
    """Return a gateway IP that belongs to the subnet CIDR."""
    network = ipaddress.ip_network(subnet_cidr, strict=False)
    if explicit_gateway:
        gateway = ipaddress.ip_address(explicit_gateway)
        if gateway not in network:
            raise SystemExit(f"subnet_gateway_ip {explicit_gateway} is not in subnet_cidr {subnet_cidr}")
        return str(gateway)
    return str(network[1])


def copy_template(template_name: str, workdir: Path) -> None:
    template_dir = TEMPLATE_ROOT / template_name
    if not template_dir.exists():
        raise SystemExit(f"terraform template not found: {template_dir}")
    workdir.mkdir(parents=True, exist_ok=True)
    for stale in list(workdir.glob("*.tf")) + list(workdir.glob(".tfrc")):
        if stale.is_file():
            stale.unlink()
    for item in template_dir.iterdir():
        if item.is_file():
            shutil.copy2(item, workdir / item.name)


def declared_template_variables(workdir: Path) -> set[str]:
    variables_file = workdir / "variables.tf"
    if not variables_file.exists():
        return set()
    return set(re.findall(r'variable\s+"([^"]+)"', variables_file.read_text(encoding="utf-8")))


def write_tfvars_file(workdir: Path, tfvars: dict) -> None:
    declared = declared_template_variables(workdir)
    output = {key: value for key, value in tfvars.items() if key in declared}
    (workdir / "terraform.tfvars.json").write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def configure_security_token_provider(workdir: Path) -> None:
    token = os.environ.get("HW_SECURITY_TOKEN") or os.environ.get("HUAWEICLOUD_SECURITY_TOKEN")
    if not token:
        return
    provider_file = workdir / "providers.tf"
    text = provider_file.read_text(encoding="utf-8")
    text = text.replace(
        'provider "huaweicloud" {\n  region = var.region\n}',
        'provider "huaweicloud" {\n  region         = var.region\n  security_token = var.security_token\n}',
    )
    provider_file.write_text(text, encoding="utf-8")


def build_tfvars(analysis: dict, spec: dict, ssh_key: dict, args: argparse.Namespace) -> dict:
    resources = spec.get("resources") or {}
    ecs = resources.get("ecs") or {}
    vpc = resources.get("vpc") or {}
    sg = resources.get("security_group") or {}
    context = spec.get("deployment_context") or {}
    app_name = slug(args.app_name or context.get("app_name") or analysis.get("app_name") or Path(analysis.get("project_root", "app")).name)
    region = args.region or spec.get("region") or "cn-north-4"
    az = args.availability_zone or ecs.get("availability_zone") or f"{region}a"
    app_port = int(args.app_port or context.get("app_port") or analysis.get("listen_port") or 8080)
    disk_size = int(args.disk_size or ecs.get("disk_size_gb") or 40)
    bandwidth = int(args.bandwidth or ecs.get("bandwidth_size_mbps") or 5)
    vpc_cidr = vpc.get("cidr") or "10.254.0.0/16"
    subnet_cidr = vpc.get("subnet_cidr") or "10.254.1.0/24"
    subnet_gateway_ip = gateway_for_subnet(subnet_cidr, vpc.get("subnet_gateway_ip"))

    return {
        "region": region,
        "availability_zone": az,
        "app_name": app_name,
        "vpc_name": f"auto-deploy-vpc-{app_name}",
        "vpc_cidr": vpc_cidr,
        "subnet_name": f"auto-deploy-subnet-{app_name}",
        "subnet_cidr": subnet_cidr,
        "subnet_gateway_ip": subnet_gateway_ip,
        "security_group_name": sg.get("name") or f"auto-deploy-sg-{app_name}",
        "instance_name": f"auto-deploy-ecs-{app_name}",
        "instance_flavor_name": args.flavor or ecs.get("flavor") or "s6.large.2",
        "instance_image_name": args.image or ecs.get("image") or "^Ubuntu 22.04.*",
        "system_disk_type": ecs.get("disk_type") or "SSD",
        "system_disk_size": disk_size,
        "keypair_name": ssh_key.get("ssh_key_name") or ecs.get("ssh_key_name") or f"auto-deploy-key-{app_name}",
        "keypair_public_key": ssh_key.get("ssh_public_key") or ecs.get("ssh_public_key"),
        "eip_type": ecs.get("eip_type") or "5_bgp",
        "bandwidth_name": f"auto-deploy-bandwidth-{app_name}",
        "bandwidth_size": bandwidth,
        "bandwidth_share_type": ecs.get("bandwidth_share_type") or "PER",
        "bandwidth_charge_mode": ecs.get("bandwidth_charge_mode") or "traffic",
        "ssh_cidr": normalize_cidr(args.ssh_cidr),
        "app_port": app_port,
        "open_http": (not args.no_http) and bool(sg.get("open_http", True)),
        "open_https": (not args.no_https) and bool(sg.get("open_https", True)),
        "app_public_cidr": args.public_cidr or sg.get("app_public_cidr") or "0.0.0.0/0",
        "network_mode": spec.get("network_mode") or vpc.get("mode") or args.network_mode or "create",
        "existing_vpc_id": args.existing_vpc_id or vpc.get("existing_vpc_id") or "",
        "existing_subnet_id": args.existing_subnet_id or vpc.get("existing_subnet_id") or "",
    }


def write_timings(path: str | None, stages: list[dict]) -> None:
    if not path:
        return
    output = Path(path).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"stages": stages}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def diagnose_terraform_error(exc: subprocess.CalledProcessError, workdir: Path) -> None:
    text = "\n".join([exc.stdout or "", exc.stderr or ""])
    lowered = text.lower()
    if "keypair" in lowered and any(term in lowered for term in ["exist", "conflict", "duplicate"]):
        print(
            "[auto-deploy] Terraform failed while creating a KPS keypair that already exists. "
            "The workflow will try to import a matching keypair or switch to a unique keypair name.",
            file=sys.stderr,
        )
    if "vpc" in lowered and "conflict" in lowered:
        print(
            "[auto-deploy] Terraform failed while creating a VPC and Huawei Cloud returned a conflict. "
            "Retry with --network-mode reuse --existing-vpc-id <id> --existing-subnet-id <id>. "
            f"If Terraform state exists, clean up only with scripts/destroy.py --workdir {workdir}.",
            file=sys.stderr,
        )


def require_tools() -> None:
    missing = [tool for tool in ["terraform"] if shutil.which(tool) is None]
    if missing:
        raise SystemExit(f"missing required tool(s): {', '.join(missing)}")


def require_credentials() -> None:
    if not has_credentials():
        raise SystemExit("Huawei Cloud credentials not found. Set HW_ACCESS_KEY/HW_SECRET_KEY or HUAWEICLOUD_ACCESS_KEY/HUAWEICLOUD_SECRET_KEY.")


def collect_resource_info(workdir: Path, args: argparse.Namespace) -> None:
    terraform_show = workdir / "terraform-show.json"
    result = run(["terraform", "show", "-json"], cwd=workdir, env=terraform_env(workdir), capture=True)
    terraform_show.write_text(result.stdout, encoding="utf-8")
    output = Path(args.output_resource_info).resolve()
    cmd = [
        sys.executable,
        str(SCRIPT_DIR / "collect_resource_info.py"),
        "--ssh-key-info",
        str(Path(args.ssh_key_info).resolve()),
        "--resource-spec",
        str(Path(args.resource_spec).resolve()),
        "--terraform-show-json",
        str(terraform_show),
        "--output",
        str(output),
    ]
    run(cmd, cwd=SKILL_DIR, env=merged_env())


def update_resource_spec_image(path: str, image: str, preinstalled_hint: bool = False) -> None:
    spec_path = Path(path)
    spec = load_json(str(spec_path))
    ecs = spec.setdefault("resources", {}).setdefault("ecs", {})
    ecs["image"] = image
    ecs["image_preinstalled_hint"] = preinstalled_hint
    resolution = spec.setdefault("resource_resolution", {})
    resolution["image"] = image
    resolution["image_preinstalled_hint"] = preinstalled_hint
    resolution["image_reason"] = "fallback image regex after Terraform image lookup failure"
    spec_path.write_text(json.dumps(spec, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def vpc_cidr_precheck(workdir: Path, tfvars: dict, env: dict) -> dict | None:
    """Best-effort precheck that avoids a slow apply/retry loop on obvious VPC CIDR conflicts.

    This optimization must never block the main Terraform provisioning path. If the
    lightweight API probe fails, continue with the normal Terraform apply flow and
    let the existing apply-time network recovery handle real conflicts.
    """
    if tfvars.get("network_mode") != "create":
        return None

    target_cidr = str(tfvars.get("vpc_cidr") or "")
    if not target_cidr:
        return None
    try:
        api = HwCloudVPCAPI(region=str(tfvars.get("region") or "cn-north-4"))
        _, conflicts = api.find_auto_deploy_vpc(target_cidr)
    except HwCloudAPIError as exc:
        print(
            "[auto-deploy][network-precheck] skipping VPC API precheck and continuing with Terraform apply: "
            f"{exc}",
            file=sys.stderr,
        )
        return None
    if not conflicts:
        return None
    return choose_reusable_network(tfvars, reason="precheck_vpc_conflict", workdir=workdir, env=env)


def terraform_query_output(query_dir: Path, env: dict, output_name: str) -> list[dict]:
    run(["terraform", "init"], cwd=query_dir, env=env)
    run(["terraform", "apply", "-auto-approve"], cwd=query_dir, env=env)
    result = run(["terraform", "output", "-json", output_name], cwd=query_dir, env=env, capture=True)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Could not parse Terraform network query output {output_name}: {exc}") from exc
    if not isinstance(value, list):
        raise SystemExit(f"Unexpected Terraform network query output for {output_name}: expected list")
    return value


def query_existing_vpcs_with_terraform(base_workdir: Path, region: str, env: dict) -> list[dict]:
    query_dir = base_workdir.parent / "network-query-vpcs"
    shutil.rmtree(query_dir, ignore_errors=True)
    query_dir.mkdir(parents=True, exist_ok=True)
    for name in (".tfrc", ".terraform.lock.hcl"):
        src = base_workdir / name
        if src.exists():
            shutil.copy2(src, query_dir / name)
    (query_dir / "main.tf").write_text(
        """
terraform {
  required_providers {
    huaweicloud = {
      source = "huaweicloud/huaweicloud"
    }
  }
}

variable "region" { type = string }
provider "huaweicloud" { region = var.region }
data "huaweicloud_vpcs" "all" {}
output "vpcs" {
  value = [for v in data.huaweicloud_vpcs.all.vpcs : {
    id     = v.id
    name   = v.name
    cidr   = v.cidr
    status = v.status
  }]
}
""".lstrip(),
        encoding="utf-8",
    )
    (query_dir / "terraform.tfvars.json").write_text(json.dumps({"region": region}) + "\n", encoding="utf-8")
    query_env = dict(env)
    query_env["TF_CLI_CONFIG_FILE"] = str(query_dir / ".tfrc")
    return terraform_query_output(query_dir, query_env, "vpcs")


def query_subnets_with_terraform(base_workdir: Path, region: str, env: dict, vpc_id: str) -> list[dict]:
    query_dir = base_workdir.parent / "network-query-subnets"
    shutil.rmtree(query_dir, ignore_errors=True)
    query_dir.mkdir(parents=True, exist_ok=True)
    for name in (".tfrc", ".terraform.lock.hcl"):
        src = base_workdir / name
        if src.exists():
            shutil.copy2(src, query_dir / name)
    (query_dir / "main.tf").write_text(
        """
terraform {
  required_providers {
    huaweicloud = {
      source = "huaweicloud/huaweicloud"
    }
  }
}

variable "region" { type = string }
variable "vpc_id" { type = string }
provider "huaweicloud" { region = var.region }
data "huaweicloud_vpc_subnets" "selected" {
  vpc_id = var.vpc_id
}
output "subnets" {
  value = [for s in data.huaweicloud_vpc_subnets.selected.subnets : {
    id     = s.id
    name   = s.name
    cidr   = s.cidr
    status = s.status
    vpc_id = s.vpc_id
  }]
}
""".lstrip(),
        encoding="utf-8",
    )
    (query_dir / "terraform.tfvars.json").write_text(
        json.dumps({"region": region, "vpc_id": vpc_id}) + "\n",
        encoding="utf-8",
    )
    query_env = dict(env)
    query_env["TF_CLI_CONFIG_FILE"] = str(query_dir / ".tfrc")
    return terraform_query_output(query_dir, query_env, "subnets")


def choose_reusable_network(tfvars: dict, reason: str, workdir: Path, env: dict) -> dict:
    """Find any reusable VPC/subnet pair.

    Prefer VPCs that are OK, have an ACTIVE subnet, and do not use the common
    192.168.0.0/16 CIDR. Names are intentionally ignored; user-created VPCs are
    valid deployment targets.
    """
    region = tfvars.get("region", "cn-north-4")
    api: HwCloudVPCAPI | None = None
    subnet_lookup_mode = "api"
    try:
        api = HwCloudVPCAPI(region=region)
        all_vpcs = api.list_vpcs()
    except HwCloudAPIError as exc:
        print(
            "[auto-deploy][network-recovery] direct VPC API query failed; falling back to Terraform provider data source: "
            f"{exc}",
            file=sys.stderr,
        )
        all_vpcs = query_existing_vpcs_with_terraform(workdir, region, env)
        subnet_lookup_mode = "terraform"

    candidates = [
        v
        for v in all_vpcs
        if v.get("status") == "OK" and v.get("cidr") != "192.168.0.0/16"
    ]
    if not candidates:
        raise SystemExit(
            "No reusable VPC found: all existing VPCs are unavailable or use "
            "the avoided CIDR 192.168.0.0/16."
        )

    subnet_errors: list[str] = []
    for vpc in candidates:
        vpc_id = vpc.get("id") or ""
        try:
            if subnet_lookup_mode == "terraform":
                subnets = query_subnets_with_terraform(workdir, region, env, vpc_id)
            else:
                assert api is not None
                subnets = api.list_subnets(vpc_id)
        except Exception as exc:
            subnet_errors.append(f"{vpc.get('name', vpc_id)}: subnet query failed: {exc}")
            continue
        active_subnet = next((s for s in subnets if s.get("status") == "ACTIVE"), None)
        if not active_subnet:
            subnet_errors.append(f"{vpc.get('name', vpc_id)}: no ACTIVE subnet")
            continue

        print(
            f"[auto-deploy][network-recovery] switching to reuse: "
            f"VPC={vpc_id} subnet={active_subnet['id']}",
            file=sys.stderr,
        )
        tfvars["network_mode"] = "reuse"
        tfvars["existing_vpc_id"] = vpc_id
        tfvars["existing_subnet_id"] = active_subnet["id"]
        return {
            "action": "auto_switched_to_reuse",
            "reason": reason,
            "reuse_vpc_id": vpc_id,
            "reuse_vpc_name": vpc.get("name", ""),
            "reuse_vpc_cidr": vpc.get("cidr", ""),
            "reuse_subnet_id": active_subnet["id"],
            "reuse_subnet_name": active_subnet.get("name", ""),
            "reuse_subnet_cidr": active_subnet.get("cidr", ""),
        }

    raise SystemExit(
        "No reusable VPC with an ACTIVE subnet was found. Checked VPCs: "
        + "; ".join(subnet_errors[:12])
    )


def keypair_name_with_public_key_fingerprint(base_name: str, public_key: str) -> str:
    suffix = hashlib.sha256(public_key.encode("utf-8")).hexdigest()[:10]
    candidate = f"{base_name}-{suffix}"
    return candidate[:64].rstrip("-") or f"auto-deploy-key-{suffix}"


def terraform_state_has_resource(workdir: Path, env: dict, address: str) -> bool:
    result = subprocess.run(
        ["terraform", "state", "list"],
        cwd=str(workdir),
        env=env,
        check=False,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        return False
    return address in set(result.stdout.splitlines())


def terraform_state_show(workdir: Path, env: dict, address: str) -> str:
    result = run(["terraform", "state", "show", address], cwd=workdir, env=env, capture=True)
    return result.stdout or ""


def keypair_state_public_key(state_text: str) -> str:
    for line in state_text.splitlines():
        stripped = line.strip()
        if stripped.startswith("public_key"):
            _, _, value = stripped.partition("=")
            return value.strip().strip('"')
    return ""


def check_or_import_existing_keypair(workdir: Path, env: dict, keypair_name: str, public_key: str, quiet: bool = False) -> str:
    """Return matched, mismatched, or missing after checking/importing the KPS keypair."""
    address = "huaweicloud_kps_keypair.deploy"
    if terraform_state_has_resource(workdir, env, address):
        imported_public_key = keypair_state_public_key(terraform_state_show(workdir, env, address))
        if imported_public_key == public_key:
            return "matched"
        subprocess.run(
            ["terraform", "state", "rm", address],
            cwd=str(workdir),
            env=env,
            check=False,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return "mismatched"

    if not quiet:
        print(f"[auto-deploy][keypair-recovery] importing existing keypair {keypair_name}", file=sys.stderr)
    result = subprocess.run(
        ["terraform", "import", address, keypair_name],
        cwd=str(workdir),
        env=env,
        check=False,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.stdout and not quiet:
        print(result.stdout, file=sys.stderr)
    if result.stderr and not quiet:
        print(result.stderr, file=sys.stderr)
    if result.returncode != 0:
        return "missing"

    imported_public_key = keypair_state_public_key(terraform_state_show(workdir, env, address))
    if imported_public_key == public_key:
        print("[auto-deploy][keypair-recovery] imported keypair matches local public key", file=sys.stderr)
        return "matched"

    print(
        "[auto-deploy][keypair-recovery] existing keypair public key does not match the local private key; "
        "switching to a unique keypair name",
        file=sys.stderr,
    )
    subprocess.run(
        ["terraform", "state", "rm", address],
        cwd=str(workdir),
        env=env,
        check=False,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return "mismatched"


def import_existing_keypair_if_matching(workdir: Path, env: dict, keypair_name: str, public_key: str) -> bool:
    return check_or_import_existing_keypair(workdir, env, keypair_name, public_key) == "matched"


def is_vpc_create_failure(exc: subprocess.CalledProcessError) -> bool:
    text = "\n".join([exc.stdout or "", exc.stderr or ""]).lower()
    network_terms = ["vpc", "subnet", "network"]
    failure_terms = ["conflict", "already exists", "quota", "over quota", "cidr", "overlap"]
    return any(term in text for term in network_terms) and any(term in text for term in failure_terms)


def is_keypair_create_failure(exc: subprocess.CalledProcessError) -> bool:
    text = "\n".join([exc.stdout or "", exc.stderr or ""]).lower()
    keypair_terms = ["keypair", "key pair", "huaweicloud_kps_keypair", "kps"]
    failure_terms = ["already exists", "exist", "duplicate", "conflict"]
    return any(term in text for term in keypair_terms) and any(term in text for term in failure_terms)


def is_image_lookup_failure(exc: subprocess.CalledProcessError) -> bool:
    text = "\n".join([exc.stdout or "", exc.stderr or ""]).lower()
    image_terms = ["image", "huaweicloud_images_image", "instance_image_name"]
    failure_terms = ["no results", "not found", "query returned no", "your query returned no"]
    return any(term in text for term in image_terms) and any(term in text for term in failure_terms)

def main() -> int:
    parser = argparse.ArgumentParser(description="Render and run bundled Huawei Cloud Terraform for auto-deploy.")
    parser.add_argument("--analysis", required=True)
    parser.add_argument("--resource-spec", required=True)
    parser.add_argument("--ssh-key-info", required=True)
    parser.add_argument("--workdir", default=".auto-deploy/terraform")
    parser.add_argument("--template")
    parser.add_argument("--app-name")
    parser.add_argument("--region")
    parser.add_argument("--availability-zone")
    parser.add_argument("--flavor")
    parser.add_argument("--image")
    parser.add_argument("--disk-size", type=int)
    parser.add_argument("--bandwidth", type=int)
    parser.add_argument("--app-port", type=int)
    parser.add_argument("--ssh-cidr", help="CIDR allowed to SSH to ECS. Defaults to detected public IP /32.")
    parser.add_argument("--public-cidr", default="")
    parser.add_argument("--network-mode", choices=["create", "reuse"])
    parser.add_argument("--existing-vpc-id")
    parser.add_argument("--existing-subnet-id")
    parser.add_argument("--no-http", action="store_true")
    parser.add_argument("--no-https", action="store_true")
    parser.add_argument("--validate-only", action="store_true", help="Render, init, and validate without planning or applying.")
    parser.add_argument("--plan-only", action="store_true", help="Render, init, validate, and plan without applying.")
    parser.add_argument("--apply", action="store_true", help="Apply the generated Terraform plan.")
    parser.add_argument("--auto-approve", action="store_true", help="Skip interactive confirmation for apply after user approval was already collected.")
    parser.add_argument("--output-resource-info", default=".auto-deploy/resource-info.json")
    parser.add_argument("--timings", help="Write Terraform stage timing JSON.")
    args = parser.parse_args()

    if args.validate_only and (args.plan_only or args.apply):
        raise SystemExit("--validate-only cannot be combined with --plan-only or --apply")
    if args.plan_only and args.apply:
        raise SystemExit("--plan-only and --apply are mutually exclusive")

    require_tools()
    if not args.validate_only:
        require_credentials()

    workdir = Path(args.workdir).resolve()
    analysis = load_json(args.analysis)
    spec = load_json(args.resource_spec)
    ssh_key = load_json(args.ssh_key_info)
    template_name = args.template or ("ecs-web-existing-network" if (spec.get("network_mode") or ((spec.get("resources") or {}).get("vpc") or {}).get("mode")) == "reuse" else "ecs-web")
    if (spec.get("network_mode") == "reuse" or args.network_mode == "reuse") and template_name == "ecs-web":
        template_name = "ecs-web-existing-network"
    copy_template(template_name, workdir)
    configure_security_token_provider(workdir)
    tfvars = build_tfvars(analysis, spec, ssh_key, args)
    if tfvars["network_mode"] == "reuse" and (not tfvars["existing_vpc_id"] or not tfvars["existing_subnet_id"]):
        raise SystemExit("network reuse requires existing_vpc_id and existing_subnet_id in resource spec or CLI args")
    if not tfvars.get("keypair_public_key"):
        raise SystemExit("missing ssh public key; run prepare_ssh_key.py before provisioning")

    write_tfvars_file(workdir, tfvars)
    printable_tfvars = {k: v for k, v in tfvars.items() if k not in {"keypair_public_key", "security_token"}}
    print(json.dumps({"workdir": str(workdir), "template": template_name, "tfvars": printable_tfvars}, ensure_ascii=False, indent=2))

    env = terraform_env(workdir)
    stages: list[dict] = []

    def timed(name: str, fn):
        started = time.perf_counter()
        status = "success"
        try:
            return fn()
        except Exception:
            status = "failed"
            raise
        finally:
            stages.append({"step": name, "status": status, "duration_seconds": round(time.perf_counter() - started, 3)})
            write_timings(args.timings, stages)

    def persist_keypair_recovery(keypair_recovery: dict) -> None:
        print(json.dumps({"keypair_recovery": keypair_recovery}, ensure_ascii=False), file=sys.stderr)
        (workdir.parent / "keypair-recovery.json").write_text(
            json.dumps(keypair_recovery, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        write_tfvars_file(workdir, tfvars)

    def recover_keypair_conflict(reason: str) -> dict:
        keypair_name = str(tfvars.get("keypair_name") or "")
        public_key = str(tfvars.get("keypair_public_key") or "")
        if import_existing_keypair_if_matching(workdir, env, keypair_name, public_key):
            return {
                "action": "imported_existing_keypair",
                "reason": reason,
                "keypair_name": keypair_name,
            }

        original_name = keypair_name
        tfvars["keypair_name"] = keypair_name_with_public_key_fingerprint(original_name, public_key)
        return {
            "action": "renamed_keypair",
            "reason": reason,
            "original_keypair_name": original_name,
            "keypair_name": tfvars["keypair_name"],
        }

    def keypair_precheck() -> dict | None:
        keypair_name = str(tfvars.get("keypair_name") or "")
        public_key = str(tfvars.get("keypair_public_key") or "")
        status = check_or_import_existing_keypair(workdir, env, keypair_name, public_key, quiet=True)
        if status == "missing":
            return None
        if status == "matched":
            return {
                "action": "imported_existing_keypair",
                "reason": "precheck_existing_keypair",
                "keypair_name": keypair_name,
            }

        original_name = keypair_name
        tfvars["keypair_name"] = keypair_name_with_public_key_fingerprint(original_name, public_key)
        return {
            "action": "renamed_keypair",
            "reason": "precheck_existing_keypair_mismatch",
            "original_keypair_name": original_name,
            "keypair_name": tfvars["keypair_name"],
        }

    def terraform_plan_with_image_fallback():
        try:
            run(["terraform", "plan", "-out", "tfplan"], cwd=workdir, env=env)
        except subprocess.CalledProcessError as exc:
            if is_keypair_create_failure(exc):
                if exc.stdout:
                    print(exc.stdout, file=sys.stderr)
                if exc.stderr:
                    print(exc.stderr, file=sys.stderr)
                recovery = recover_keypair_conflict("terraform_plan_failed")
                persist_keypair_recovery(recovery)
                run(["terraform", "plan", "-out", "tfplan"], cwd=workdir, env=env)
                return
            if not is_image_lookup_failure(exc) or tfvars.get("instance_image_name") == "^Ubuntu 22.04.*":
                raise
            print(
                f"[auto-deploy][image-fallback] image regex {tfvars.get('instance_image_name')} was not found; "
                "falling back to ^Ubuntu 22.04.*",
                file=sys.stderr,
            )
            tfvars["instance_image_name"] = "^Ubuntu 22.04.*"
            update_resource_spec_image(args.resource_spec, "^Ubuntu 22.04.*", preinstalled_hint=False)
            write_tfvars_file(workdir, tfvars)
            (workdir.parent / "image-recovery.json").write_text(
                json.dumps(
                    {
                        "action": "auto_switched_image_regex",
                        "fallback_image": "^Ubuntu 22.04.*",
                        "reason": "terraform_plan_image_lookup_failed",
                    },
                    ensure_ascii=False,
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            run(["terraform", "plan", "-out", "tfplan"], cwd=workdir, env=env)

    try:
        def resolve_resources():
            """Pre-check AZ and flavor availability; fall back if defaults are unavailable."""
            if args.validate_only or not has_credentials():
                return
            region = tfvars.get("region", "cn-north-4")
            desired_az = tfvars.get("availability_zone", "")
            desired_flavor = tfvars.get("instance_flavor_name", "")
            try:
                flavor_api = HwCloudFlavorAPI(region=region)
                available_azs = flavor_api.list_availability_zones()
                resolved_az, az_reason = resolve_az(desired_az, available_azs)
                if resolved_az != desired_az:
                    print(f"[auto-deploy][resource-resolution] AZ {desired_az} not available in {region}; using {resolved_az} ({az_reason})", file=sys.stderr)
                    tfvars["availability_zone"] = resolved_az

                available_flavors = flavor_api.list_flavors(az=resolved_az)
                resolved_flavor, flavor_reason = resolve_flavor(desired_flavor, available_flavors)
                if resolved_flavor != desired_flavor:
                    print(f"[auto-deploy][resource-resolution] Flavor {desired_flavor} not available in {resolved_az}; using {resolved_flavor} ({flavor_reason})", file=sys.stderr)
                    tfvars["instance_flavor_name"] = resolved_flavor

                resolution = {
                    "original_az": desired_az,
                    "resolved_az": resolved_az,
                    "az_reason": az_reason,
                    "original_flavor": desired_flavor,
                    "resolved_flavor": resolved_flavor,
                    "flavor_reason": flavor_reason,
                    "available_azs": available_azs,
                    "available_flavors_count": len(available_flavors),
                }
                (workdir.parent / "resource-resolution.json").write_text(
                    json.dumps(resolution, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
                )
                write_tfvars_file(workdir, tfvars)
            except HwCloudAPIError as exc:
                print(f"[auto-deploy][resource-resolution] API query failed, proceeding with defaults: {exc}", file=sys.stderr)
            except Exception as exc:
                print(f"[auto-deploy][resource-resolution] Unexpected error, proceeding with defaults: {exc}", file=sys.stderr)

        def validate_and_plan():
            run(["terraform", "fmt"], cwd=workdir, env=env)
            run(["terraform", "init"], cwd=workdir, env=env)
            run(["terraform", "validate"], cwd=workdir, env=env)
            if not args.validate_only:
                keypair_recovery = timed("keypair_precheck", keypair_precheck)
                if keypair_recovery:
                    persist_keypair_recovery(keypair_recovery)
                terraform_plan_with_image_fallback()

        timed("resource_resolution", resolve_resources)
        timed("terraform_init_validate_plan", validate_and_plan)
        if args.validate_only:
            print("[auto-deploy] validation completed; no Terraform plan or apply was run", file=sys.stderr)
            return 0
    except subprocess.CalledProcessError as exc:
        diagnose_terraform_error(exc, workdir)
        raise

    if not args.apply:
        print("[auto-deploy] plan completed; rerun with --apply after confirmation", file=sys.stderr)
        return 0

    if not args.auto_approve:
        answer = input("Apply Terraform plan and create/update live Huawei Cloud resources? Type 'yes' to continue: ")
        if answer.strip().lower() != "yes":
            raise SystemExit("apply cancelled")

    def persist_network_recovery(network_recovery: dict) -> None:
        print(json.dumps({"network_recovery": network_recovery}, ensure_ascii=False), file=sys.stderr)
        (workdir.parent / "network-recovery.json").write_text(
            json.dumps(network_recovery, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        write_tfvars_file(workdir, tfvars)

    def switch_to_existing_network_template() -> None:
        nonlocal template_name, env
        if template_name != "ecs-web-existing-network":
            template_name = "ecs-web-existing-network"
            copy_template(template_name, workdir)
            configure_security_token_provider(workdir)
            write_tfvars_file(workdir, tfvars)
            env = terraform_env(workdir)

    def replan_current_template() -> None:
        run(["terraform", "init"], cwd=workdir, env=env)
        terraform_plan_with_image_fallback()

    def apply_with_network_fallback() -> None:
        try:
            result = run(["terraform", "apply", "tfplan"], cwd=workdir, env=env, capture=True)
            if result.stdout:
                print(result.stdout, end="", file=sys.stderr)
            if result.stderr:
                print(result.stderr, end="", file=sys.stderr)
            return
        except subprocess.CalledProcessError as exc:
            if is_vpc_create_failure(exc) and tfvars.get("network_mode") != "reuse":
                if exc.stdout:
                    print(exc.stdout, file=sys.stderr)
                if exc.stderr:
                    print(exc.stderr, file=sys.stderr)
                print("[auto-deploy][network-recovery] VPC creation failed; trying existing VPC/subnet reuse", file=sys.stderr)
            elif is_keypair_create_failure(exc):
                if exc.stdout:
                    print(exc.stdout, file=sys.stderr)
                if exc.stderr:
                    print(exc.stderr, file=sys.stderr)
                recovery = timed("keypair_recovery", lambda: recover_keypair_conflict("terraform_apply_failed"))
                persist_keypair_recovery(recovery)
                timed("keypair_recovery_replan", replan_current_template)
                apply_with_network_fallback()
                return
            else:
                raise

        network_recovery = timed(
            "network_recovery_select_existing_vpc",
            lambda: choose_reusable_network(tfvars, reason="terraform_apply_failed", workdir=workdir, env=env),
        )
        persist_network_recovery(network_recovery)
        switch_to_existing_network_template()
        timed("network_recovery_replan", replan_current_template)
        apply_with_network_fallback()

    try:
        if args.network_mode == "create":
            network_recovery = timed("vpc_cidr_precheck", lambda: vpc_cidr_precheck(workdir, tfvars, env))
            if network_recovery:
                persist_network_recovery(network_recovery)
                switch_to_existing_network_template()
                timed("vpc_cidr_precheck_replan", lambda: (
                    run(["terraform", "init"], cwd=workdir, env=env),
                    terraform_plan_with_image_fallback(),
                ))

        timed("terraform_apply", apply_with_network_fallback)
        timed("collect_resource_info", lambda: collect_resource_info(workdir, args))
    except subprocess.CalledProcessError as exc:
        diagnose_terraform_error(exc, workdir)
        raise
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        if exc.stdout:
            print(exc.stdout, file=sys.stderr)
        if exc.stderr:
            print(exc.stderr, file=sys.stderr)
        raise SystemExit(exc.returncode)



