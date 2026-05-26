#!/usr/bin/env bash
# List artifacts for an MLflow run (via direct S3 — the MLflow client is slow here).
# Usage: mlflow-list-artifacts.sh <run_id> [path]
#   path: optional subdirectory to list (e.g. 'plots')
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <run_id> [path]" >&2
    exit 1
fi

RUN_ID="$1"
ARTIFACT_PATH="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

OPS_DIR="$SCRIPT_DIR" uv run --with mlflow --with boto3 --quiet python - "$RUN_ID" "$ARTIFACT_PATH" <<'PYTHON'
import os
import sys
from urllib.parse import urlparse

import boto3

sys.path.insert(0, os.environ["OPS_DIR"])
import _mlflow_patched as mlflow  # REST-API prefix patch — required for continuum.ergodic.io

run_id = sys.argv[1]
path = sys.argv[2] if len(sys.argv) > 2 else ""

run = mlflow.MlflowClient().get_run(run_id)
parsed = urlparse(run.info.artifact_uri)
if parsed.scheme != "s3":
    raise SystemExit(f"Expected s3:// artifact_uri, got {run.info.artifact_uri!r}")

bucket = parsed.netloc
base_key = parsed.path.lstrip("/")
prefix = f"{base_key}/{path}".rstrip("/") + "/"

paginator = boto3.client("s3").get_paginator("list_objects_v2")
for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
    for obj in page.get("Contents", []) or []:
        print(obj["Key"][len(base_key) + 1:])
PYTHON
