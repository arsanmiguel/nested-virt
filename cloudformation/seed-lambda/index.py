"""Custom resource: extract embedded script bundle zip into the lab S3 bucket."""
import base64
import io
import zipfile

import boto3

# Minimal cfnresponse (no external deps).
import json
import urllib.request


def send(event, context, status, data, reason=None):
    body = json.dumps(
        {
            "Status": status,
            "Reason": reason or f"See CloudWatch Log Stream: {context.log_stream_name}",
            "PhysicalResourceId": event.get("PhysicalResourceId")
            or event["ResourceProperties"].get("Bucket")
            or context.log_stream_name,
            "StackId": event["StackId"],
            "RequestId": event["RequestId"],
            "LogicalResourceId": event["LogicalResourceId"],
            "Data": data or {},
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        event["ResponseURL"],
        data=body,
        headers={"Content-Type": ""},
        method="PUT",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        resp.read()


def handler(event, context):
    bucket = event["ResourceProperties"]["Bucket"]
    if event["RequestType"] == "Delete":
        send(event, context, "SUCCESS", {"Bucket": bucket})
        return

    bundle_b64 = event["ResourceProperties"]["Bundle"]
    raw = base64.b64decode(bundle_b64)
    s3 = boto3.client("s3")
    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        for name in zf.namelist():
            if name.endswith("/"):
                continue
            s3.put_object(Bucket=bucket, Key=name, Body=zf.read(name))

    send(event, context, "SUCCESS", {"Bucket": bucket, "Seeded": "true"})
