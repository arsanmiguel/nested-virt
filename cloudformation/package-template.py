#!/usr/bin/env python3
"""Package userdata-stub.sh into template-src.yaml."""
from pathlib import Path
import base64
import os
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MARKER_B64 = "{{USERDATA_B64}}"
MARKER_BUCKET = "{{BOOTSTRAP_BUCKET}}"


def main() -> int:
    src = HERE / "template-src.yaml"
    stub = ROOT / "userdata-stub.sh"
    out = HERE / "packaged-template.yaml"
    env_file = HERE / ".bootstrap-bucket.env"

    bucket = os.environ.get("BOOTSTRAP_BUCKET")
    if not bucket:
        account = os.environ.get("AWS_ACCOUNT_ID")
        if account:
            bucket = f"nested-virt-bootstrap-{account}"
        else:
            print("ERROR: set BOOTSTRAP_BUCKET or AWS_ACCOUNT_ID", file=sys.stderr)
            return 1
    if env_file.is_file():
        for line in env_file.read_text().splitlines():
            if line.startswith("BOOTSTRAP_BUCKET="):
                bucket = line.split("=", 1)[1].strip()

    tpl = src.read_text()
    if MARKER_B64 not in tpl:
        print(f"Marker {MARKER_B64} not found", file=sys.stderr)
        return 1

    stub_text = stub.read_text().replace(MARKER_BUCKET, bucket)
    b64 = base64.b64encode(stub_text.encode("utf-8")).decode("ascii")
    if len(b64) > 16384:
        print(f"ERROR: stub b64 {len(b64)} > 16384", file=sys.stderr)
        return 1

    out.write_text(tpl.replace(MARKER_B64, b64))
    print(f"Wrote {out} (stub b64={len(b64)}, bucket={bucket})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
