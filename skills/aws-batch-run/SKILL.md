---
name: aws-batch-run
description: Run simulations on AWS Batch via the generic sim runner — bundle the local working tree to S3, submit it to a parameterized job definition, monitor the job, and verify results in MLflow and S3. Use when the user wants to run on AWS / Batch / "the cloud" rather than NERSC, or when Perlmutter is unavailable.
allowed-tools: Bash, Read, Write, Edit
---

# Running simulations on AWS Batch

The counterpart to `nersc-workflow`. Same simulations, different compute: instead of syncing to
Perlmutter and allocating a node, you upload the working tree to S3 and submit a Batch job.

`adept-run` still decides *how* to invoke the solver (ergoExo vs parsl vs training loop). This skill
covers *where* it runs and how to get code there.

## AWS or NERSC?

| Situation | Where |
| --- | --- |
| Fits one 24 GB GPU | **AWS** — `gpu` queue, spot, ~8–16 concurrent |
| Needs more GPU memory than 24 GB but fits 48 GB | AWS `gpu-48g`, on demand, only 6 concurrent |
| Large-memory cases (e.g. ml-for-lpi N=128/100 ps, which OOM'd on 40 GB A100s) | **NERSC** |
| Multi-GPU or multi-node (e.g. kinetic-srs `pic2d` `PIC2D_MULTINODE`) | **NERSC** — there is deliberately no multi-GPU shape on Batch |
| Interactive debugging, long walltimes | NERSC |

This split is settled; don't re-open it per campaign.

## The model — why there is no per-project image

Three layers, split by how often they change:

| Layer | Changes | Cost |
| --- | --- | --- |
| Image (`sim-gpu` / `sim-cpu`) | monthly | rebuild + push, in CI |
| Code bundle | every submit | ~1 s upload, content-addressed |
| Job definition | ~never | one per *resource shape*, not per project |

The image contains **no application code** — CUDA, Python, `uv`, and a pre-warmed `uv` cache seeded
from the participating repos' lockfiles. At run time `bootstrap.sh` fetches the bundle, runs
`uv sync --frozen`, and execs your command. The warm cache is what makes that ~20 s instead of
minutes, and it is why the image tag can sit still while the code moves daily.

Background and rationale: ergodicio/continuum-infra#47. Runtime lives in
`continuum-infra/sim-runner/` (`Dockerfile`, `bootstrap.sh`, `submit.py`, `locks/`).

## Submitting

The client is `continuum-infra/sim-runner/submit.py`. (It is destined for `adept.cloud.submit` —
ergodicio/adept#316 — so check whether that exists before reaching for the path.)

```bash
/path/to/continuum-infra/sim-runner/submit.py \
  --repo /path/to/ml-for-lpi \
  --cmd 'python tools/run_exo.py --config configs/opt-peak-omega.yaml --run my-run' \
  --queue gpu --job-definition sim-gpu --extras gpu \
  --bucket continuum-sim-code-106231741818
```

| Flag | Notes |
| --- | --- |
| `--repo` | tree to bundle (default cwd) |
| `--cmd` | command run inside the project. A command, not an `(entry, config)` pair, because the repos disagree about their CLIs |
| `--queue` / `--job-definition` | see the table below |
| `--extras` | comma-separated uv extras — almost always `gpu` for GPU jobs |
| `--bucket` | or `$SIM_CODE_BUCKET` |
| `--array N` | array job; the command can read `$AWS_BATCH_JOB_ARRAY_INDEX` |
| `--dry-run` | bundle and report, upload and submit nothing. **Use this first on a new repo** |
| `--exclude GLOB` | drop extra paths |
| `--include-suffix EXT` | keep a suffix that is dropped by default |
| `--relock` | run `uv lock` before bundling |

Bundling uses `git ls-files -co --exclude-standard` — tracked files plus untracked-not-ignored — so
**uncommitted edits ride along**. That is the point: iteration is an upload, not a rebuild.
`.venv`, artifacts and `mlflow.db` stay out for free via `.gitignore`.

### Queues and shapes

| Queue | Fleet | GPU | Concurrency |
| --- | --- | --- | --- |
| `gpu` | g6/g5.xlarge + .2xlarge, **spot**, falls through to on demand | 24 GB L4/A10G | ~8–16 |
| `gpu-ondemand` | same types, on demand only | 24 GB | ~8 |
| `gpu-48g` | g6e.xlarge, on demand | 48 GB L40S | **6** (maxvCpus 24) |
| `cpu` | c7i.large, spot | — | wide |
| `cpu-hmem` | r7i.2xlarge, spot | — | wide |

| Job definition | vCPU | Memory | GPU |
| --- | --- | --- | --- |
| `sim-gpu` | 4 | 14000 MiB | 1 |
| `sim-cpu` | 2 | 3500 MiB | 0 |
| `sim-cpu-hmem` | 8 | 60000 MiB | 0 |

`sim-gpu` is sized for the 16 GiB-host g6/g5.xlarge so one definition runs on both GPU queues. One
GPU per instance regardless of instance size, so one job per instance.

Default to `--queue gpu`. It is spot-backed and the widest.

### Pick a single-run entry point, not a scan driver

**Do not put a parsl driver inside a Batch container.** `lpi-scan.py`, `lpi-learn.py` and
`train_two_stream.py` manage their own parsl fan-out and expect a multi-GPU allocation; running one
in a 1-GPU container is wrong. Use the single-run entry instead:

| Repo | Single run |
| --- | --- |
| ml-for-lpi | `python tools/run_exo.py --config <cfg> --run <name>` |
| kinetic-srs | `python run.py --cfg <cfg-without-.yaml>` |
| vp-turbulence | `python run_two_stream.py --cfg <cfg>` |

For a scan, use `--array N` and have the command index into the config list with
`$AWS_BATCH_JOB_ARRAY_INDEX` — one array job of N children rather than parsl.

### MLflow — do not override the tracking URI

The job definitions already carry `MLFLOW_TRACKING_URI=http://mlfs.continuum/experiments`,
`MLFLOW_TRACKING_USERNAME=batch`, and the password injected from Secrets Manager. **Pass no
`MLFLOW_TRACKING_URI` in `--cmd`.** Never put credentials in `--cmd` either — job parameters are
readable via `describe-jobs` and the console.

## Monitoring

```bash
aws batch describe-jobs --jobs <job-id> \
  --query 'jobs[0].{status:status,reason:statusReason,exits:attempts[].container.exitCode}' --output json
```

Container logs — log group `/aws/batch/job`, stream from the job:

```bash
aws logs get-log-events --log-group-name /aws/batch/job \
  --log-stream-name "$(aws batch describe-job... --query 'jobs[0].container.logStreamName' --output text)" \
  --start-from-head --limit 400 --query 'events[].message' --output text | tr '\t' '\n' | tail -40
```

Per attempt (a retry gets its own stream): `jobs[0].attempts[N].container.logStreamName`.

Job definitions set `retry_attempts=2`, so a failure you care about appears twice.

Useful progress markers, in order: `[bootstrap] code_uri=…` → `[bootstrap] dependencies ready in Ns`
→ `[bootstrap] running: <cmd>` → solver output → `run_id: <32 hex>`.

Prefer a background poller over repeated manual checks. Make the filter cover failure as well as
success — grep `run_id|Traceback|Error|OOM|RESOURCE_EXHAUSTED|Killed|No space|MlflowException`, not
just the happy path, or a crash is indistinguishable from "still running".

## Verifying results

The log prints an MLflow URL using the in-VPC host. Rewrite it for a browser:

```
http://mlfs.continuum/experiments/#/experiments/<exp>/runs/<run>
  ->  https://continuum.ergodic.io/experiments/#/experiments/<exp>/runs/<run>
```

Artifacts land in S3 and can be listed without MLflow auth:

```bash
python3 -c "
import boto3
s3=boto3.client('s3')
for page in s3.get_paginator('list_objects_v2').paginate(
        Bucket='public-ergodic-continuum', Prefix='<exp>/<run_id>/artifacts'):
    for o in page.get('Contents',[]):
        print(f\"{o['Size']/1e6:9.1f} MB  {o['Key'].split('/artifacts/',1)[-1]}\")
"
```

For metrics and params use the `mlflow-query` skill. **Watch for the local-sqlite fallback**: if the
shell has no `MLFLOW_TRACKING_URI`, `mlflow-get-params.py` silently creates a local store and reports
"Run not found". That is a missing env var, not a missing run.

## Traps

Each of these cost real debugging time.

**The lock determines the physics.** `uv sync --frozen` installs exactly the `uv.lock` inside the
bundle, so the pinned `adept` SHA is what runs — not `main`. Before starting a campaign, check the
pin and whether it predates a fix you depend on:

```bash
grep -A2 'name = "adept"' uv.lock          # in the sim repo
git -C /path/to/adept merge-base --is-ancestor <needed-sha> <pinned-sha> && echo included
git -C /path/to/adept log --oneline <pinned>..origin/main -- adept/_lpse2d   # what changed
```

A stale pin fails **silently** — the run succeeds with old physics. Bump with
`uv lock --upgrade-package adept`, then verify imports and `ergoExo.setup` locally before submitting.

**Paths drift after a repo reorg.** The bundle comes from the working tree; a driver that moved
(e.g. `run_exo.py` → `tools/run_exo.py`) gives
`python: can't open file '/work/...': No such file or directory`. Confirm with `git ls-files | grep <driver>`.

**Config defaults beat CLI overrides you copied from a docstring.** Passing `--shape tl` to
ml-for-lpi's `run_exo.py` overrides a working config default with a driver lacking
`scale_intensities`. Prefer the config's own values unless there is a reason.

**Derived files are dropped by suffix** — `.nc`, `.h5`, `.png`, `.npy`, `.db` and friends. Never
silently: the count and size print on every submit. If one is an *input*, pass `--include-suffix`.
Check before assuming: in vp-turbulence the dropped 463 MB of `.nc` is unused sample data plus a
training input with an MLflow fallback, so plain sim runs are unaffected.

**`RUNNABLE` forever is capacity, and the job says nothing.** Job `statusReason` stays `null` and the
compute environment reports `VALID` / `ComputeEnvironment Healthy`. The error is in the ASG:

```bash
ASG=$(aws autoscaling describe-auto-scaling-groups \
  --query 'AutoScalingGroups[?contains(AutoScalingGroupName,`gpu-24g`)].AutoScalingGroupName' --output text)
aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG" \
  --max-items 5 --query 'Activities[?StatusCode==`Failed`].StatusMessage' --output text
```

`InsufficientInstanceCapacity` means try `gpu-48g` or wait. Both GPU fleets are confined to
us-east-1a/1b (the VPC has no 1c/1d subnets), so capacity dips bite.

**`cancel-job` only works before `STARTING`.** For a job already `STARTING`/`RUNNING` it silently
no-ops. Use `terminate-job`, which handles both:

```bash
aws batch terminate-job --job-id <id> --reason "why"
```

**Precision is per repo, not per platform.** ml-for-lpi leaves `jax_enable_x64` off (float32, so
complex128→complex64 truncation warnings are normal and appear on Perlmutter too);
vp-turbulence's `run_two_stream.py` sets it on. Don't "fix" either from the warnings, and remember
float64 doubles memory when judging fit.

**The shell here is zsh.** `declare -A` / `${!arr[@]}` give `bad substitution`. Keep poller scripts
POSIX-ish.

## Recording runs

Same discipline as NERSC — the repo's `NOTES.md` is the record. Before submitting, write down the
config, the driver command, the resolved **adept SHA from the lock**, and the user's stated reason.
Immediately after, add the **Batch job id**; once it starts, the **MLflow run id** and the bundle
`sha256`. The bundle digest plus the lock is what makes a cloud run reproducible, so record both.

## Guidelines

- `--dry-run` first on any repo you have not bundled before; check the reported file count and what got dropped.
- Prefer `--queue gpu`. Reach for `gpu-48g` only when 24 GB is genuinely not enough.
- One job per config for a handful of runs; `--array N` once it is a scan.
- Don't rebuild the image to change a dependency — the bundle's lock handles it. Images get rebuilt in CI (`continuum-infra/.github/workflows/sim_runner_image.yaml`), and `locks/` is only a cache hint.
- Don't `cdk deploy` from a laptop. continuum-infra deploys via CI on merge to `main`.
