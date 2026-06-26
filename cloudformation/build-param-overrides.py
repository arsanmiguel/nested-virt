#!/usr/bin/env python3
"""Write CloudFormation --parameter-overrides lines."""
import json
import os
import sys


def main() -> int:
    params_path = sys.argv[1]
    skip = frozenset({
        "SubnetId",
        "ExtraHostNicSubnetId",
        "InstanceName",
        "PeerTransportEniIp",
        "PeerLabSupernet",
    })
    with open(params_path) as f:
        params = {p["ParameterKey"]: str(p["ParameterValue"]) for p in json.load(f)}
    params = {k: v for k, v in params.items() if k not in skip}
    params["LaunchInstance"] = os.environ["LAUNCH_INSTANCE"]
    params["KeyName"] = os.environ["KEY_NAME"]
    params["InstanceName"] = os.environ["STACK_NAME"]
    params["SiteId"] = os.environ.get("SITE_ID", "0")
    if os.environ.get("METAL_SUBNET_ID"):
        params["SubnetId"] = os.environ["METAL_SUBNET_ID"]
    if os.environ.get("EXTRA_HOST_NIC_SUBNET_ID"):
        params["ExtraHostNicSubnetId"] = os.environ["EXTRA_HOST_NIC_SUBNET_ID"]
    if os.environ.get("PEER_TRANSPORT_ENI_IP"):
        params["PeerTransportEniIp"] = os.environ["PEER_TRANSPORT_ENI_IP"]
    if os.environ.get("PEER_LAB_SUPERNET"):
        params["PeerLabSupernet"] = os.environ["PEER_LAB_SUPERNET"]
    if os.environ.get("BOOTSTRAP_BUCKET"):
        params["BootstrapBucket"] = os.environ["BOOTSTRAP_BUCKET"]
    overrides = dict(params)
    with open(params_path, "w") as f:
        json.dump(
            [{"ParameterKey": k, "ParameterValue": v} for k, v in params.items()],
            f,
            indent=2,
        )
        f.write("\n")
    out_path = sys.argv[2]
    with open(out_path, "w") as f:
        for k, v in overrides.items():
            f.write(f"{k}={v}\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        sys.exit(0)
