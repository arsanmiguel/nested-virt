#!/usr/bin/env python3
"""Build nested-virt-lab.yaml — single drop-in CloudFormation template (CFN and go)."""
from __future__ import annotations

import base64
import io
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

RUNTIME_FILES = [
    ("bootstrap.sh", ROOT / "bootstrap.sh"),
    ("s3-lab-common.sh", ROOT / "scripts" / "s3-lab-common.sh"),
    ("coordinate-peer-routing-on-host.sh", ROOT / "scripts" / "coordinate-peer-routing-on-host.sh"),
    ("lab-site-pipeline.sh", ROOT / "scripts" / "lab-site-pipeline.sh"),
    ("routing-proof-on-host.sh", ROOT / "scripts" / "routing-proof-on-host.sh"),
    ("ensure-lab-dnsmasq.sh", ROOT / "scripts" / "ensure-lab-dnsmasq.sh"),
    ("ensure-lab-vnc.sh", ROOT / "scripts" / "ensure-lab-vnc.sh"),
    ("ensure-lab-image-cache.sh", ROOT / "scripts" / "ensure-lab-image-cache.sh"),
    ("ensure-lab-guest-dns.ps1", ROOT / "scripts" / "ensure-lab-guest-dns.ps1"),
    ("ensure-inner-guest-dns.sh", ROOT / "scripts" / "ensure-inner-guest-dns.sh"),
    ("internet-proof-on-host.sh", ROOT / "scripts" / "internet-proof-on-host.sh"),
    ("apply-peer-routes.sh", ROOT / "scripts" / "apply-peer-routes.sh"),
    ("fix-transport-routing.sh", ROOT / "scripts" / "fix-transport-routing.sh"),
    ("setup-gre-tunnel.sh", ROOT / "scripts" / "setup-gre-tunnel.sh"),
    ("provision-windows-guest.sh", ROOT / "scripts" / "provision-windows-guest.sh"),
    ("autounattend.xml", ROOT / "scripts" / "autounattend.xml"),
    ("enable-hyperv.ps1", ROOT / "scripts" / "enable-hyperv.ps1"),
    ("enable-hyperv-nested-host.ps1", ROOT / "scripts" / "enable-hyperv-nested-host.ps1"),
    ("fix-kvm-nested-hyperv-xml.sh", ROOT / "scripts" / "fix-kvm-nested-hyperv-xml.sh"),
    ("prepare-ubuntu-inner-image.sh", ROOT / "scripts" / "prepare-ubuntu-inner-image.sh"),
    ("provision-ubuntu-inner-vm.ps1", ROOT / "scripts" / "provision-ubuntu-inner-vm.ps1"),
    ("deploy-inner-ubuntu-on-host.sh", ROOT / "scripts" / "deploy-inner-ubuntu-on-host.sh"),
    ("deploy-real-l2.sh", ROOT / "scripts" / "deploy-real-l2.sh"),
    ("open-guest-firewall.ps1", ROOT / "scripts" / "open-guest-firewall.ps1"),
    ("apply-guest-firewall.sh", ROOT / "scripts" / "apply-guest-firewall.sh"),
]


def build_bundle_b64() -> str:
    site_yaml = (HERE / "template-src.yaml").read_text()
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, path in RUNTIME_FILES:
            zf.writestr(f"nested-virt/{name}", path.read_bytes())
        zf.writestr("nested-virt/cloudformation/site.yaml", site_yaml.encode("utf-8"))
    return base64.b64encode(buf.getvalue()).decode("ascii")


def indent_lambda(code: str, spaces: int = 10) -> str:
    pad = " " * spaces
    return "\n".join(f"{pad}{line}" for line in code.splitlines())


def main() -> int:
    master = (HERE / "lab-drop-in-master.yaml").read_text()
    bundle_b64 = build_bundle_b64()
    seed_py = (HERE / "seed-lambda" / "index.py").read_text()

    if len(bundle_b64) > 900_000:
        print(f"ERROR: bundle b64 too large ({len(bundle_b64)} bytes)", flush=True)
        return 1

    out = master.replace("__BUNDLE_B64__", bundle_b64)
    out = out.replace("__SEED_LAMBDA_ZIPFILE__", indent_lambda(seed_py))

    out_path = HERE / "nested-virt-lab.yaml"
    out_path.write_text(out)
    size = out_path.stat().st_size
    print(f"Wrote {out_path} ({size:,} bytes, bundle b64 {len(bundle_b64):,} bytes)")
    if size > 1_000_000:
        print("WARN: template exceeds 1MB console upload limit — use S3 template URL", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
