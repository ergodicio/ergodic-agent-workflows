"""Minimal end-to-end demo: train a tiny MLP, log to MLflow.

The point is to exercise the whole loop (laptop -> rsync -> Perlmutter GPU ->
MLflow). The model is intentionally trivial so the run takes ~30 seconds.
"""

from __future__ import annotations

import os
import pathlib
import time

import mlflow
import torch
import torch.nn as nn

EXPERIMENT = "ergodic-agent-workflows-first-run"


def main() -> None:
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"[train] device={device}", flush=True)

    # Synthetic regression task: y = sin(2x) + 0.3*x
    torch.manual_seed(0)
    x = torch.linspace(-3, 3, 512, device=device).unsqueeze(1)
    y = torch.sin(2 * x) + 0.3 * x

    model = nn.Sequential(nn.Linear(1, 64), nn.Tanh(), nn.Linear(64, 1)).to(device)
    opt = torch.optim.Adam(model.parameters(), lr=1e-2)

    mlflow.set_experiment(EXPERIMENT)
    run_name = f"first-run-{int(time.time())}"

    with mlflow.start_run(run_name=run_name):
        mlflow.log_params({"device": device, "lr": 1e-2, "steps": 200, "hidden": 64})
        commit_file = pathlib.Path(".git_commit")
        if commit_file.exists():
            mlflow.log_param("git_commit", commit_file.read_text().strip())

        for step in range(200):
            opt.zero_grad()
            loss = ((model(x) - y) ** 2).mean()
            loss.backward()
            opt.step()
            if step % 10 == 0:
                mlflow.log_metric("loss", loss.item(), step=step)
                print(f"[train] step={step:4d}  loss={loss.item():.6f}", flush=True)

        mlflow.log_metric("final_loss", loss.item())
        print(f"[train] done. final_loss={loss.item():.6f}", flush=True)


if __name__ == "__main__":
    if not os.environ.get("MLFLOW_TRACKING_URI"):
        raise SystemExit(
            "MLFLOW_TRACKING_URI not set. Source .env on NERSC, or export it locally."
        )
    main()
