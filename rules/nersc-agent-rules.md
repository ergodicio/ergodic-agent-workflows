# NERSC agent rules

Adapted from NERSC's [AI Coding Tools at NERSC](https://docs.nersc.gov/development/coding-agents/)
guidance. NERSC asks every user running a coding agent to put the filesystem-discovery
rules below into their agent config (`~/.claude/CLAUDE.md` or `~/.codex/AGENTS.md`).

`scripts/install-agent-rules.sh` installs this block into both `~/.claude/CLAUDE.md` and
`~/.codex/AGENTS.md` between managed markers, on your laptop and on Perlmutter. Re-running
it refreshes the block in place; nothing else in either file is touched.

The one deviation from NERSC's text: their example routes heavy searches through a
`$perlmutter-compute` subagent, which we don't have. Ours routes them through an
interactive allocation instead (`~/.ergodic-claude/ops/interactive-cpu.sh`).

---

<!-- BLOCK START: everything below this line is what gets installed. -->

## NERSC filesystem discovery

These rules apply to any NERSC filesystem you can reach — directly when running on a
Perlmutter login or compute node, and *through* `ssh perlmutter "…"` / `rsync` when
driving Perlmutter from a laptop. A remote shell is not an exemption.

- Never recursively traverse `/`, `/global`, `/global/cfs`, `/global/homes`, `/pscratch`,
  `/opt`, `/usr`, or another shared top-level directory. This prohibition applies on
  compute nodes as well as login nodes.
- This prohibition includes `find`, `bfs`, `fd`, `tree`, recursive `du`, `rg --files`,
  recursive `grep`, recursive `ls`, globstar expansion, and recursive traversal written in
  Python or another language.
- Before searching, identify a bounded root inside the current workspace or a known
  project or data directory. Constrain depth and filename patterns where possible. If no
  bounded root is known, stop and ask the user.
- Locate software with `command -v`, `type -a`, `module spider`, package metadata, or
  known environment prefixes. Do not search mounted filesystems for executables.
- Do not disable or bypass an installed filesystem-traversal hook, and do not ask the user
  to approve an equivalent broad scan through another command.
- A compute allocation is not permission for an unbounded traversal of a shared
  filesystem. Narrow the search first; route only bounded, computationally substantial
  searches through a compute allocation (`~/.ergodic-claude/ops/interactive-cpu.sh`),
  never a login node.

Bounded roots on Perlmutter that are almost always what you actually wanted:
`$PSCRATCH/<repo>/`, `$PSCRATCH/<repo>-runs/<sha>/`,
`$EC_SOFTWARE_ROOT/$USER/` (your project space on global common), `$HOME`.

## NERSC agent conduct

- You have exactly the user's own permissions on NERSC systems. Nothing you run is
  sandboxed from their data, their allocation, or their teammates' jobs.
- Keep writes inside the working directory you were pointed at (`$HOME` or `$SCRATCH`).
  If the files to edit live on `$CFS`, copy them to a fresh working directory on `$HOME`
  or `$SCRATCH` and work there.
- **Python environments are the documented exception, and belong on global common.** Do not
  "fix" a venv under `/global/common/software/<project>/$USER/` by relocating it to `$HOME`
  or `$SCRATCH`. NERSC's own
  [Python guidance](https://docs.nersc.gov/development/languages/python/nersc-python/)
  recommends installing environments used by parallel applications to
  `/global/common/software/<project>` — for import performance and, explicitly, to avoid
  causing filesystem slowdowns for other users; their Python FAQ prescribes moving a stack
  there to fix metadata timeouts at scale. `$SCRATCH` would also purge it after 8 weeks.
  The write-scope rule above is about an agent's blast radius on *data*, not about where a
  software stack lives; these are different concerns and the Python guidance wins here.
- Bounds that keep that safe: write only inside `$USER/`, never elsewhere under the
  project's global common (it is shared with teammates), and only from a **login node** —
  global common is read-only from compute, so never from inside `salloc`/`srun`.
- Installing or updating that environment on a login node is therefore expected, not a
  violation of the "substantial work belongs in an allocation" principle above: there is
  no allocation that can write global common. It is minutes, once per project, and
  attended. Don't route it through `salloc`, and don't move the venv to make that possible.
- Never put credentials, tokens, or private keys into a prompt, a commit, a log line, or a
  command line. On Perlmutter they are read from files (`~/.mlflow_credentials`,
  `~/.ssh/*-deploy`) by the launch scripts — keep it that way.
- Slurm and module advice is the least reliable thing a model produces. Verify the
  account, QOS, node/GPU counts, module names, launch command, and filesystem paths
  against the actual system before submitting anything.
- Prefer the smallest concrete next step, run it, and inspect the result — over a large
  generated solution accepted whole. Use plan mode for multi-step work on shared systems.

<!-- BLOCK END -->
