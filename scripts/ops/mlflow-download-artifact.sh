#!/usr/bin/env bash
# Download one artifact from an MLflow run to /tmp/.
# Usage: mlflow-download-artifact.sh <run_id> <artifact_path>
# Example: mlflow-download-artifact.sh 9bd9277... plots/scalars/mean_e2.png
set -euo pipefail

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    echo "Usage: $0 <run_id> <artifact_path>" >&2
    echo "  artifact_path: relative path under the run's artifact root" >&2
    exit 1
fi

RUN_ID="$1"
ARTIFACT_PATH="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

OPS_DIR="$SCRIPT_DIR" uv run --with mlflow --with boto3 --quiet python - "$RUN_ID" "$ARTIFACT_PATH" <<'PYTHON'
import os
import sys
from urllib.parse import urlparse

import boto3

sys.path.insert(0, os.environ["OPS_DIR"])
import _mlflow_patched as mlflow  # REST-API prefix patch — required for continuum.ergodic.io

run_id = sys.argv[1]
artifact_path = sys.argv[2]

run = mlflow.MlflowClient().get_run(run_id)
parsed = urlparse(run.info.artifact_uri)
if parsed.scheme != "s3":
    raise SystemExit(f"Expected s3:// artifact_uri, got {run.info.artifact_uri!r}")

bucket = parsed.netloc
key = f"{parsed.path.lstrip('/')}/{artifact_path}"
local_path = f"/tmp/{os.path.basename(artifact_path)}"

boto3.client("s3").download_file(bucket, key, local_path)
print(f"Downloaded: {local_path}")
PYTHON
