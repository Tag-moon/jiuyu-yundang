#!/usr/bin/env python3
"""Lightweight Huawei Cloud VPC/subnet query using AK/SK HMAC signing.

Uses only Python standard library (hmac, hashlib, urllib) to avoid
SDK dependencies.  Replaces the slow Terraform data-source precheck
with a direct API call that completes in ~1 second.
"""

import hashlib
import hmac
import json
import os
import sys
import urllib.request
from datetime import datetime, timezone


class HwCloudAPIError(Exception):
    pass


class HwCloudVPCAPI:
    """Minimal Huawei Cloud VPC API client with AK/SK signing."""

    def __init__(self, region: str, ak: str | None = None, sk: str | None = None, project_id: str | None = None):
        self.region = region
        self.ak = ak or os.environ.get("HW_ACCESS_KEY") or os.environ.get("HUAWEICLOUD_ACCESS_KEY") or ""
        self.sk = sk or os.environ.get("HW_SECRET_KEY") or os.environ.get("HUAWEICLOUD_SECRET_KEY") or ""
        if not self.ak or not self.sk:
            raise HwCloudAPIError("Huawei Cloud credentials not found (HW_ACCESS_KEY / HW_SECRET_KEY)")
        self.project_id = project_id or os.environ.get("HW_PROJECT_ID") or os.environ.get("OS_PROJECT_ID") or ""

    def _sign(self, method: str, host: str, path: str, query: str, headers: dict[str, str], body: bytes) -> dict[str, str]:
        now = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        headers["X-Sdk-Date"] = now
        if "host" not in {k.lower() for k in headers}:
            headers["Host"] = host
        headers.setdefault("Content-Type", "application/json")
        signed_headers = ";".join(sorted(k.lower() for k in headers))
        canonical = "\n".join([
            method.upper(),
            path,
            query,
            *(f"{k.lower()}:{headers[k].strip()}" for k in sorted(headers, key=str.lower)),
            "",
            signed_headers,
            hashlib.sha256(body).hexdigest(),
        ])
        string_to_sign = f"SDK-HMAC-SHA256\n{now}\n{hashlib.sha256(canonical.encode()).hexdigest()}"
        sig = hmac.new(self.sk.encode(), string_to_sign.encode(), hashlib.sha256).hexdigest()
        headers["Authorization"] = (
            f"SDK-HMAC-SHA256 Credential={self.ak}, "
            f"SignedHeaders={signed_headers}, Signature={sig}"
        )
        return headers

    def _get(self, service_host: str, path: str, query: str = "") -> dict:
        url = f"https://{service_host}{path}" + (f"?{query}" if query else "")
        body = b""
        headers = {"Host": service_host, "Accept": "application/json"}
        headers = self._sign("GET", service_host, path, query, headers, body)
        req = urllib.request.Request(url, method="GET", headers=headers, data=body)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as exc:
            msg = exc.read().decode(errors="replace") if exc.fp else ""
            raise HwCloudAPIError(f"HTTP {exc.code} {service_host}{path}: {msg}") from exc
        except urllib.error.URLError as exc:
            raise HwCloudAPIError(f"Connection failed to {service_host}: {exc.reason}") from exc

    def _vpc_host(self) -> str:
        return f"vpc.{self.region}.myhuaweicloud.com"

    def get_project_id(self) -> str:
        if self.project_id:
            return self.project_id
        try:
            data = self._get("iam.myhuaweicloud.com", "/v3/projects", f"name={self.region}")
        except HwCloudAPIError as exc:
            raise HwCloudAPIError(
                f"Could not determine project_id for region {self.region} via IAM API: {exc}. "
                "Set HW_PROJECT_ID or OS_PROJECT_ID to skip IAM project lookup."
            ) from exc
        projects = data.get("projects") or []
        for p in projects:
            if p.get("name") == self.region and p.get("enabled") is not False:
                self.project_id = p["id"]
                return self.project_id
        raise HwCloudAPIError(
            f"Could not determine project_id for region {self.region}. "
            "Set HW_PROJECT_ID or OS_PROJECT_ID environment variable."
        )

    def list_vpcs(self) -> list[dict]:
        pid = self.get_project_id()
        data = self._get(self._vpc_host(), f"/v1/{pid}/vpcs")
        return [
            {
                "id": v.get("id", ""),
                "name": v.get("name", ""),
                "cidr": v.get("cidr", ""),
                "status": v.get("status", ""),
            }
            for v in (data.get("vpcs") or [])
        ]

    def list_subnets(self, vpc_id: str) -> list[dict]:
        pid = self.get_project_id()
        data = self._get(self._vpc_host(), f"/v1/{pid}/subnets", f"vpc_id={vpc_id}")
        return [
            {
                "id": s.get("id", ""),
                "name": s.get("name", ""),
                "cidr": s.get("cidr", ""),
                "status": s.get("status", ""),
                "vpc_id": s.get("vpc_id", ""),
            }
            for s in (data.get("subnets") or [])
        ]

    def find_auto_deploy_vpc(self, cidr: str | None = None) -> tuple[list[dict], list[dict] | None]:
        """Return (all_vpcs, conflicting_vpcs_or_None).

        conflicting_vpcs contains VPCs whose CIDR matches *cidr*.
        """
        vpcs = self.list_vpcs()
        conflicts = [v for v in vpcs if cidr and v.get("cidr") == cidr] if cidr else []
        return vpcs, conflicts or None


class HwCloudFlavorAPI:
    """Huawei Cloud ECS flavor and availability-zone query with AK/SK signing.

    Reuses the same signing mechanism as HwCloudVPCAPI to query:
    - Available availability zones in a region
    - Available ECS flavors (optionally filtered by AZ)
    """

    def __init__(self, region: str, ak: str | None = None, sk: str | None = None, project_id: str | None = None):
        self.region = region
        self.ak = ak or os.environ.get("HW_ACCESS_KEY") or os.environ.get("HUAWEICLOUD_ACCESS_KEY") or ""
        self.sk = sk or os.environ.get("HW_SECRET_KEY") or os.environ.get("HUAWEICLOUD_SECRET_KEY") or ""
        if not self.ak or not self.sk:
            raise HwCloudAPIError("Huawei Cloud credentials not found (HW_ACCESS_KEY / HW_SECRET_KEY)")
        self.project_id = project_id or os.environ.get("HW_PROJECT_ID") or os.environ.get("OS_PROJECT_ID") or ""
        self._vpc_api = HwCloudVPCAPI(region, ak=self.ak, sk=self.sk, project_id=project_id)

    def _sign(self, method: str, host: str, path: str, query: str, headers: dict[str, str], body: bytes) -> dict[str, str]:
        return self._vpc_api._sign(method, host, path, query, headers, body)

    def _get(self, service_host: str, path: str, query: str = "") -> dict:
        return self._vpc_api._get(service_host, path, query)

    def get_project_id(self) -> str:
        return self._vpc_api.get_project_id()

    def list_availability_zones(self) -> list[str]:
        """Query available availability zones in the region.

        API: GET /v1/{project_id}/availability-zones
        Returns sorted list of AZ codes, e.g. ["cn-north-4a", "cn-north-4b", ...]
        """
        pid = self.get_project_id()
        data = self._get(f"ecs.{self.region}.myhuaweicloud.com", f"/v1/{pid}/availability-zones")
        azs = [az.get("zoneName") or az.get("zone_name") or az.get("code", "") for az in data.get("availabilityZoneInfo", data.get("availability_zones", []))]
        return sorted(az for az in azs if az)

    def list_flavors(self, az: str | None = None) -> list[dict]:
        """Query available ECS flavors in the region, optionally filtered by AZ.

        API: GET /v1/{project_id}/cloudservers/flavors
        Returns list of {"name", "vcpus", "ram_mb"} dicts.
        """
        pid = self.get_project_id()
        query = f"availability_zone={az}" if az else ""
        data = self._get(f"ecs.{self.region}.myhuaweicloud.com", f"/v1/{pid}/cloudservers/flavors", query)
        flavors = []
        for f in data.get("flavors", []):
            name = f.get("name", "")
            vcpus = int(f.get("vcpus", 0))
            ram_mb = int(f.get("ram", 0))  # API returns MB
            if name and vcpus > 0 and ram_mb > 0:
                flavors.append({"name": name, "vcpus": vcpus, "ram_mb": ram_mb})
        return flavors


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--region", default="cn-north-4")
    parser.add_argument("--cidr", default="")
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("list-vpcs")
    p_sub = sub.add_parser("list-subnets")
    p_sub.add_argument("--vpc-id", required=True)
    sub.add_parser("get-project-id")
    sub.add_parser("check-conflict")
    sub.add_parser("list-azs")
    p_flavors = sub.add_parser("list-flavors")
    p_flavors.add_argument("--az", default="")
    args = parser.parse_args()

    api = HwCloudVPCAPI(region=args.region)
    if args.cmd == "get-project-id":
        print(api.get_project_id())
    elif args.cmd == "list-vpcs":
        print(json.dumps(api.list_vpcs(), indent=2))
    elif args.cmd == "list-subnets":
        print(json.dumps(api.list_subnets(args.vpc_id), indent=2))
    elif args.cmd == "check-conflict":
        vpcs, conflicts = api.find_auto_deploy_vpc(args.cidr or None)
        print(json.dumps({"vpcs": len(vpcs), "conflicts": conflicts}, indent=2))
    elif args.cmd in ("list-azs", "list-flavors"):
        flavor_api = HwCloudFlavorAPI(region=args.region)
        if args.cmd == "list-azs":
            print(json.dumps(flavor_api.list_availability_zones(), indent=2))
        else:
            print(json.dumps(flavor_api.list_flavors(args.az or None), indent=2))
