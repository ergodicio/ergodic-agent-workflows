#!/usr/bin/env -S uv run --with mlflow --with boto3 --quiet python
"""Print parameters, metrics, and non-system tags for an MLflow run.

Usage:
    mlflow-get-params.py <run_id>

Requires MLFLOW_TRACKING_URI / USERNAME / PASSWORD in the environment
(see the ergodic-agent-workflows README).
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import _mlflow_patched as mlflow  # noqa: E402  REST-API prefix patch — must precede client use


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: mlflow-get-params.py <run_id>", file=sys.stderr)
        sys.exit(1)

    run_id = sys.argv[1]
    client = mlflow.MlflowClient()
    run = client.get_run(run_id)

    print("=== Run Info ===")
    print(f"Run ID:        {run.info.run_id}")
    print(f"Run Name:      {run.info.run_name}")
    print(f"Experiment ID: {run.info.experiment_id}")
    print(f"Status:        {run.info.status}")
    print(f"Artifact URI:  {run.info.artifact_uri}")

    print("\n=== Parameters ===")
    for k, v in sorted(run.data.params.items()):
        print(f"{k}: {v}")

    if run.data.metrics:
        print("\n=== Metrics ===")
        for k, v in sorted(run.data.metrics.items()):
            print(f"{k}: {v}")

    print("\n=== Tags ===")
    for k, v in sorted(run.data.tags.items()):
        if not k.startswith("mlflow."):
            print(f"{k}: {v}")


if __name__ == "__main__":
    main()
