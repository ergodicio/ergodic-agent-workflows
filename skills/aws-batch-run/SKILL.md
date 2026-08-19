---
name: aws-batch-run
description: Run single-node simulations on AWS Batch through continuum-infra's generic sim-runner bundle, including dry runs, submission, monitoring, CloudWatch logs, exact-job termination, capacity fallback, and result verification. Use when the user asks to run a simulation on AWS, AWS Batch, or the cloud, or wants a Batch alternative to the NERSC workflow.
---

# AWS Batch simulation workflow

Use the generic sim runner in `continuum-infra`: bundle the local working tree into a
deterministic, content-addressed S3 object, submit a generic Batch job, follow its CloudWatch
logs, and verify the scientific result in MLflow.

`adept-run` still decides what solver command to run. `mlflow-query` still handles metrics and
artifacts. This skill decides where the command runs and moves the code there.

## Choose AWS deliberately

| Workload | Destination |
| --- | --- |
| One GPU, <=24 GB device memory | AWS `gpu` (default) |
| One GPU, <=24 GB, must avoid Spot | AWS `gpu-ondemand` |
| One GPU, 24-48 GB device memory | AWS `gpu-48g` |
| CPU | AWS `cpu`; use `cpu-hmem` for the 60 GiB shape |
| Multi-GPU, multi-node, interactive debugging, or >48 GB GPU memory | NERSC |

There is deliberately no multi-GPU Batch job definition. Do not put a parsl driver that expects
a multi-GPU allocation inside a one-GPU Batch container. For a scan of independent one-GPU
simulations, use a Batch array job whose command indexes a precomputed manifest with
`$AWS_BATCH_JOB_ARRAY_INDEX`.

## Resolve the runner without searching the filesystem

The submit client is owned by `continuum-infra`, not by `adept` and not by this skill. Resolve its
checkout from `EC_CONTINUUM_INFRA`, or assume it is a sibling of the current repository:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
INFRA_ROOT=${EC_CONTINUUM_INFRA:-$(dirname "$REPO_ROOT")/continuum-infra}
SIM_RUNNER=$INFRA_ROOT/sim-runner/submit.py
test -f "$SIM_RUNNER"
```

If that bounded path is absent, ask the user where `continuum-infra` is checked out. Do not scan
their home directory. Keep `REPO_ROOT` pointed at the simulation repository, even when the agent
itself is operating from another checkout or a git worktree.

Verify AWS identity before any submission. The account ID is not a secret and determines the code
bucket name:

```bash
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
SIM_CODE_BUCKET=continuum-sim-code-$AWS_ACCOUNT
aws configure get region
```

If authentication has expired, ask the user to refresh their configured AWS SSO session. Never
request, print, or move AWS credentials.

## Submission contract

The image contains Python, CUDA where applicable, `uv`, and a pre-warmed dependency cache, but no
application code. At runtime `/opt/bootstrap.sh` downloads the bundle, runs `uv sync --frozen`
from its `uv.lock`, and executes `cmd`.

Map queues to job definitions:

| Queue | Job definition | Extras |
| --- | --- | --- |
| `gpu`, `gpu-ondemand`, `gpu-48g` | `sim-gpu` | `gpu` |
| `cpu` | `sim-cpu` | empty |
| `cpu-hmem` | `sim-cpu-hmem` | empty |

Use the unversioned job-definition name; Batch resolves its active revision. Default GPU work to
`gpu`. Use `gpu-48g` only for measured GPU-memory need, not as a capacity fallback.

Run the client through `uv run --no-project` so it gets boto3 without resolving or modifying the
simulation environment:

```bash
uv run --no-project --with boto3 python "$SIM_RUNNER" \
  --repo "$REPO_ROOT" \
  --cmd 'python run.py --cfg configs/example' \
  --queue gpu \
  --job-definition sim-gpu \
  --extras gpu \
  --bucket "$SIM_CODE_BUCKET" \
  --dry-run
```

Remove `--dry-run` only after inspecting the file count, bundle size, excluded suffixes, queue,
job definition, and exact command. A dry run uploads and submits nothing. Always use it before the
first submission from a repository or after changing bundle exclusions.

Useful client flags:

| Flag | Meaning |
| --- | --- |
| `--array N` | Submit an N-child array; the command may read `$AWS_BATCH_JOB_ARRAY_INDEX` |
| `--exclude GLOB` | Exclude an additional path |
| `--include-suffix EXT` | Restore a normally excluded derived-file suffix needed as input |
| `--name NAME` | Override the default `<repo>-<bundle-sha12>` job name |
| `--relock` | Run `uv lock` before bundling; use only when the user intends to change the lock |

The bundle includes tracked files plus untracked, non-ignored files, and force-includes
`pyproject.toml` and `uv.lock`. Uncommitted edits therefore run on AWS. Report whether the tree is
dirty before submitting. For a production/reproducible run, require a clean working tree and a
pushed commit; record both that commit and the printed bundle SHA. The S3 bundle is exact but
expires after 30 days, so a dirty bundle is not a permanent source archive.

The lock determines the installed physics. `uv sync --frozen` uses the bundled `uv.lock` exactly;
it does not pull the newest `adept` commit. Before a campaign, inspect the locked adept source and
confirm it contains any required fix. A stale lock can produce a successful but scientifically
stale run.

Never put credentials or secret values in `--cmd`. Batch parameters are visible through
`describe-jobs`; MLflow credentials are already injected by the job definition from Secrets
Manager.

## Monitor one exact job

Capture the job ID printed by the submit client. Inspect state, reason, attempts, and exit codes:

```bash
aws batch describe-jobs --jobs <job-id> \
  --query 'jobs[0].{name:jobName,status:status,reason:statusReason,queue:jobQueue,definition:jobDefinition,attempts:attempts[].{exit:container.exitCode,reason:container.reason,stream:container.logStreamName}}' \
  --output json
```

States progress through `SUBMITTED`, `PENDING`, `RUNNABLE`, `STARTING`, `RUNNING`, then
`SUCCEEDED` or `FAILED`. A job definition permits two attempts, so inspect every attempt rather
than only the current container.

Once a log stream exists, follow it:

```bash
LOG_STREAM=$(aws batch describe-jobs --jobs <job-id> \
  --query 'jobs[0].container.logStreamName' --output text)
aws logs tail /aws/batch/job --log-stream-names "$LOG_STREAM" --follow
```

For a failed retry, read the stream recorded under the corresponding `attempts[]` entry. Useful
markers are `[bootstrap] code_uri`, `[bootstrap] dependencies ready`, `[bootstrap] running`, solver
output, an MLflow run ID, and the final exit code.

Do not describe a job as successful merely because submission returned a job ID. Verify four
gates in order: it submitted, it reached `SUCCEEDED` with exit code 0, relevant tests or solver
checks passed, and the MLflow metrics/artifacts are scientifically sensible.

## Handle capacity without hiding cost

Every live queue cancels a job that remains `RUNNABLE` for 30 minutes specifically because of
`CAPACITY:INSUFFICIENT_INSTANCE_CAPACITY`. If that reason appears:

- for a 24 GB GPU job that must run now, resubmit the same bundle/command to `gpu-ondemand`;
- otherwise wait and resubmit to the original queue;
- do not switch to `gpu-48g` unless the job actually needs more than 24 GB of GPU memory;
- never move a job to on-demand capacity automatically or without telling the user.

Ordinary queueing behind other jobs does not trigger that capacity cancellation.

## Terminate safely

When the user asks to stop a job, inspect it first, echo the exact job ID/name/state, then use
`terminate-job`. It handles queued and running jobs; `cancel-job` is insufficient after a job
starts.

```bash
aws batch terminate-job --job-id <job-id> --reason '<specific reason>'
```

Never terminate by job name, queue, or user, and never blanket-stop jobs. A termination request is
destructive and must name the exact target.

## Verify and record results

Use `mlflow-query` for run status, parameters, metrics, history, and artifacts. The container may
print an internal URL such as:

```text
http://mlfs.continuum/experiments/#/experiments/<experiment>/runs/<run>
```

Rewrite only the browser host:

```text
https://continuum.ergodic.io/experiments/#/experiments/<experiment>/runs/<run>
```

Record the repository commit, dirty/clean state, exact command, queue, job definition, Batch job
ID, bundle SHA/code URI, MLflow run ID, and the user's reason for the run. The bundle SHA identifies
the code bytes; the lock identifies the dependency graph; both are needed for reproduction.

## Operational rules

- Prefer the existing sim-runner bundle over rebuilding an image or creating a per-project job
  definition.
- Use separate normal jobs for a handful of independent runs; use an array plus an immutable
  manifest for a real scan.
- Do not run multi-node or multi-GPU workloads on this Batch estate.
- Do not modify Batch infrastructure or run `cdk deploy` as part of launching a simulation.
- Do not mutate `uv.lock` unless requested; never silently resolve dependencies in the container.
- Report the verification gate actually reached and include the exact Batch job ID.
