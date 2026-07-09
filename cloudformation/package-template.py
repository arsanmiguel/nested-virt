#!/usr/bin/env python3
"""Copy template-src.yaml for dev/per-site deploy (UserData uses !Sub BootstrapBucket)."""
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent


def main() -> int:
    src = HERE / "template-src.yaml"
    out = HERE / "packaged-template.yaml"
    out.write_text(src.read_text())
    print(f"Wrote {out} (copy of template-src.yaml)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
