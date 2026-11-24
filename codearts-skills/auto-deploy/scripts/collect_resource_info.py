#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def load_json(path: str | None) -> dict:
    if not path:
        return {}
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def pick(data: dict, *keys):
    for key in keys:
        value = data.get(key)
        if value:
            return value
    return None


def iter_tf_resources(module: dict):
    for resource in module.get("resources", []) or []:
        yield resource
    for child in module.get("child_modules", []) or []:
        yield from iter_tf_resources(child)


def parse_terraform_show(data: dict) -> dict:
    values = data.get("values") or {}
    outputs = values.get("outputs") or {}
    root = values.get("root_module") or {}
    parsed = {}
    for key in ("instance_id", "public_ip", "private_ip", "security_group_id", "vpc_id", "subnet_id"):
        output = outputs.get(key) or {}
        if output.get("value"):
            parsed.setdefault(key, output.get("value"))
    for resource in iter_tf_resources(root):
        rtype = resource.get("type")
        vals = resource.get("values") or {}
        if rtype == "huaweicloud_compute_instance":
            parsed.setdefault("instance_id", vals.get("id"))
            parsed.setdefault("private_ip", vals.get("access_ip_v4") or vals.get("private_ip"))
            network = vals.get("network")
            if isinstance(network, list) and network:
                parsed.setdefault("private_ip", network[0].get("fixed_ip_v4") or network[0].get("fixed_ip"))
        elif rtype == "huaweicloud_vpc_eip":
            parsed.setdefault("public_ip", vals.get("address") or vals.get("publicip_address"))
        elif rtype == "huaweicloud_compute_eip_associate":
            parsed.setdefault("public_ip", vals.get("public_ip"))
            parsed.setdefault("instance_id", vals.get("instance_id"))
        elif rtype == "huaweicloud_networking_secgroup":
            parsed.setdefault("security_group_id", vals.get("id"))
        elif rtype == "huaweicloud_vpc":
            parsed.setdefault("vpc_id", vals.get("id"))
        elif rtype == "huaweicloud_vpc_subnet":
            parsed.setdefault("subnet_id", vals.get("id"))
    return {k: v for k, v in parsed.items() if v}


def main() -> int:
    parser = argparse.ArgumentParser(description="Create auto-deploy resource-info.json after Terraform provisioning.")
    parser.add_argument("--ssh-key-info", required=True)
    parser.add_argument("--resource-spec", required=True)
    parser.add_argument("--terraform-result", help="Optional flat JSON manually collected from Terraform state/query output.")
    parser.add_argument("--terraform-show-json", help="Optional JSON from `terraform show -json`.")
    parser.add_argument("--instance-id")
    parser.add_argument("--public-ip")
    parser.add_argument("--private-ip")
    parser.add_argument("--security-group-id")
    parser.add_argument("--vpc-id")
    parser.add_argument("--subnet-id")
    parser.add_argument("--region")
    parser.add_argument("--output", default="resource-info.json")
    args = parser.parse_args()

    ssh_key = load_json(args.ssh_key_info)
    spec = load_json(args.resource_spec)
    result = load_json(args.terraform_result)
    if args.terraform_show_json:
        result = {**parse_terraform_show(load_json(args.terraform_show_json)), **result}

    region = args.region or pick(result, "region") or spec.get("region")
    public_ip = args.public_ip or pick(result, "public_ip", "eip", "eip_address", "address")
    instance_id = args.instance_id or pick(result, "instance_id", "ecs_instance_id", "server_id", "id")
    vpc = ((spec.get("resources") or {}).get("vpc") or {})
    ecs = ((spec.get("resources") or {}).get("ecs") or {})
    resolution = spec.get("resource_resolution") or {}

    missing = []
    if not public_ip:
        missing.append("public_ip")
    if not instance_id:
        missing.append("instance_id")
    if missing:
        raise SystemExit(
            "missing required fields after provisioning: "
            + ", ".join(missing)
            + ". Provide them via --public-ip/--instance-id or --terraform-result."
        )

    info = {
        "instance_id": instance_id,
        "public_ip": public_ip,
        "private_ip": args.private_ip or pick(result, "private_ip", "fixed_ip", "internal_ip"),
        "ssh_user": ssh_key.get("ssh_user", "root"),
        "ssh_key_path": ssh_key["ssh_private_key_path"],
        "security_group_id": args.security_group_id or pick(result, "security_group_id", "secgroup_id"),
        "region": region,
        "instance_image_name": ecs.get("image") or resolution.get("image"),
        "vpc_id": args.vpc_id or pick(result, "vpc_id") or vpc.get("existing_vpc_id"),
        "subnet_id": args.subnet_id or pick(result, "subnet_id") or vpc.get("existing_subnet_id"),
    }
    info = {k: v for k, v in info.items() if v not in (None, "")}
    Path(args.output).write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(info, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
