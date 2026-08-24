---
name: mlflow-query
description: Query MLflow tracking server for experiment runs, metrics, metric history, parameters, and worker status. Use when checking training progress, comparing runs, investigating loss curves, or when the user asks about experiment results.
allowed-tools: Bash(uv run python3 *)
---

# MLflow Query

Query the MLflow tracking server (https://continuum.ergodic.io/experiments/) to check experiments, runs, metrics, and worker status.

## Helper scripts (prefer for common ops)

These wrappers live at `~/.ergodic-agent-workflows/ops/` (symlinked by `bootstrap-local.sh`). Use them for the most common single-run lookups; fall back to inline Python (below) for anything bespoke (filtering, ranges, metric history, custom searches).

| Need | Script |
| --- | --- |
| Dump params + metrics + tags for one run | `~/.ergodic-agent-workflows/ops/mlflow-get-params.py <run_id>` |
| List artifact paths for a run | `~/.ergodic-agent-workflows/ops/mlflow-list-artifacts.sh <run_id> [subpath]` |
| Download one artifact to `/tmp/` | `~/.ergodic-agent-workflows/ops/mlflow-download-artifact.sh <run_id> <artifact_path>` |

All three resolve dependencies via `uv run --with mlflow --with boto3 --quiet python` and read `MLFLOW_TRACKING_*` + AWS creds from the environment.

## Setup

All queries use `uv run python3 -c "..."` so dependencies are resolved on the fly. The shell must have these env vars set (see the repo README for where to put them):

```
MLFLOW_TRACKING_URI=https://continuum.ergodic.io/experiments/
MLFLOW_TRACKING_USERNAME=<user>
MLFLOW_TRACKING_PASSWORD=<token>
```

**Required import** — the tracking server sits behind a reverse proxy that exposes the REST API under `/ajax-api/2.0/` instead of the upstream `/api/2.0/`. Bare `import mlflow` will 404 on every call. Use the shared patch module instead (mirrors `adept/adept/patched_mlflow.py`):

```python
import os, sys
sys.path.insert(0, os.path.expanduser("~/.ergodic-agent-workflows/ops"))
import _mlflow_patched as mlflow
client = mlflow.MlflowClient()
```

Every inline Python example below assumes this prelude is included. The three helper scripts already import the patch themselves — no extra work needed when using them.

## Available operations

### List experiments
```python
for e in client.search_experiments():
    print(f'{e.name:40s}  id={e.experiment_id}')
```

### List recent runs in an experiment
```python
exp = client.get_experiment_by_name('<experiment-name>')
runs = client.search_runs(exp.experiment_id, order_by=['start_time DESC'], max_results=10)
for r in runs:
    metrics = {k: v for k, v in r.data.metrics.items() if 'loss' in k.lower()}
    print(f'{r.info.run_name:30s} status={r.info.status:10s} metrics={metrics}')
```

### Filter runs by parameters
```python
runs = client.search_runs(exp.experiment_id,
    filter_string='params.<key> = "<value>"',
    order_by=['start_time DESC'], max_results=10)
```

### All metrics for a run
```python
r = runs[0]
print(f'Run: {r.info.run_name}  Status: {r.info.status}')
for k, v in sorted(r.data.metrics.items()):
    print(f'  {k}: {v}')
```

### All parameters for a run
```python
for k, v in sorted(r.data.params.items()):
    print(f'  {k}: {v}')
```

### Metric history (all steps)
```python
history = client.get_metric_history(run_id, '<metric-name>')
for h in history:
    print(f'step={h.step:4d}  {h.key}={h.value:.6f}')
```

### Child / worker runs
For experiments that spawn worker runs (e.g. a sweep), the workers usually live in a sibling experiment by convention (e.g. `<name>-workers`). Ask the user if unsure.

```python
exp = client.get_experiment_by_name('<name>-workers')
runs = client.search_runs(exp.experiment_id, order_by=['start_time DESC'], max_results=10)
for r in runs:
    print(f'{r.info.run_name:40s} status={r.info.status}')
```

## Downloading artifacts

Artifacts on this tracking server are stored in S3. **Use boto3 to download, not the MLflow client.** MLflow is only for getting URIs — its download methods are slow/unreliable for this backend.

```python
import boto3

run = client.search_runs('<experiment_id>', max_results=1)[0]
artifact_uri = run.info.artifact_uri  # e.g. s3://public-ergodic-continuum/<exp>/<run>/artifacts

bucket = artifact_uri.split('/')[2]
prefix = '/'.join(artifact_uri.split('/')[3:])

s3 = boto3.client('s3')
response = s3.list_objects_v2(Bucket=bucket, Prefix=prefix)
for obj in response.get('Contents', []):
    print(f"  {obj['Key']}  ({obj['Size']/1e6:.1f}MB)")

s3.download_file(bucket, f'{prefix}/<artifact-name>', '/tmp/<artifact-name>')
```

AWS credentials come from `~/.aws/` or env vars; if downloads fail with auth errors, ask the user to check their AWS config.

## Guidelines

- Compose operations as needed — e.g. find a run, then pull its metric history.
- For vague requests like "how's training going", list recent runs in the most likely experiment and show loss metrics.
- If the user names a run or metric, drill into it directly.
- Summarize trends when showing metric history (don't dump 1000 rows verbatim).
- For artifacts, always use boto3 — never `mlflow.artifacts.download_artifacts` against this server.

$ARGUMENTS
