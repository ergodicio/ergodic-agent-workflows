---
name: research-notes
description: Maintain the research record in the shared Obsidian vault (Ergodic Research) — campaign hubs, append-only investigation notes with reproducible checkpoints, and the translation of archived notebooks — and, for repositories not yet migrated, append-only NOTES.md notebooks. Use for scientific simulations, experiments, numerical investigations, and multi-session research decisions; do not use for routine code maintenance with no research record.
---

# Research Notes

The research record is persistent research memory and an audit ledger, not polished
documentation or a transcript of agent activity. Preserve enough ground truth that a
later researcher can reconstruct what was tried, why, what happened, and what changed
next.

For `srs-campaign` the record is the shared Obsidian vault **Ergodic Research**
(canonical since 2026-09-08). The repository keeps no parallel record: its `NOTES.md`
files are frozen stubs that name the vault hub. Repositories not yet migrated
(`kinetic-srs`, `lagradept-apps`, `adept-light-coupling`) stay on the `NOTES.md`
convention in the last section until they are.

## Vault workflow (migrated repositories)

Before the first research write in a task, run `scripts/resolve-shared-vault.py`
(relative to this `SKILL.md`) and read
[references/vault-protocol.md](references/vault-protocol.md) completely. In short:

- Read the study's **campaign hub** (`Notes/<project>/<study>/<study>.md`) first: status,
  executions, USER quotes, trust caveats. If its log sections are still untranslated, read
  the linked archive sections before relying on any number.
- Record the work in a new **investigation note** in the study folder, from
  `Templates/Investigation.md`, with `campaign: "[[<study>]]"`. Create the hub first (from
  `Templates/Campaign.md`, established campaign name) when the study is new.
- Append **checkpoints** with the `Checkpoint` template at pre-registration, submission,
  and inspection; correct by appending; update the hub's *Status* in place and put
  nothing else in the hub.
- When you touch a study whose archives are `translated: false`, translate them per the
  protocol's stage-2 rules.
- If the vault cannot be resolved, keep the checkpoint text in the job's scratch
  directory, report it, and do not append to a frozen `NOTES.md`.

## What belongs in the record

Append a checkpoint at a meaningful research boundary, including:

- the question, acceptance criterion, or user interpretation that directs the work;
- simulation provenance needed to reproduce a result: commit, config, material command,
  environment, run ID, job ID, seed, and output or tracking location as applicable;
- launches and their honest state (`PLANNED`, `LAUNCHED`, `COMPLETED`, `FAILED`,
  `CANCELLED`, or `PARTIAL`), especially before a long-running job leaves the session;
- quantitative observations, failed approaches, corrections, and unexpected behavior;
- decisions made by the user or by an explicit pre-declared acceptance criterion; and
- concrete open questions without speculative answers.

Do not record routine tool narration, unsupported conclusions, large raw output that has a
durable artifact location, or credentials. Never put a token, password, private key, or
secret-bearing command in the record.

## Preserve the epistemic boundary

- Record the agent's ground-truth observations in neutral, reproducible language: run
  status, numerical changes, controlled differences, errors, and artifact contents.
- Do not infer physics, diagnose a root cause, declare convergence, or opine on method
  suitability from a plot or trend alone. A visible field increase is an observation;
  calling it an instability is an interpretation.
- Record the user's reasons, hypotheses, interpretations, and goals verbatim when they
  matter, labeled `USER (verbatim)`. Do not paraphrase them into an agent conclusion.
- If the task explicitly requires analysis or hypothesis generation, keep proposed
  explanations clearly separate from measured facts and label them (`SPECULATION`,
  `CONJECTURE (USER)`); do not put them in the durable ledger as findings unless the user
  adopts them or a designed test establishes them.
- Mark untrusted numbers three ways (property, banner, point of use) as the protocol
  describes.
- Err on the side of recording relevant research information. During authorized research
  work, do not ask whether to update the record; update it at the appropriate checkpoint.

## Timing of checkpoints for a run or scan

1. **Before submission:** run number and date, source and material dependency commits,
   config, key differences from the previous run, and the user's reasons, hypotheses, and
   goals verbatim. This is pre-registration, not retrospective narration.
2. **Immediately after submission:** the scheduler or allocation ID and the run or
   experiment tracking ID as soon as each exists. Keep the state `LAUNCHED` or `PENDING`.
3. **After inspection or completion:** the actual status, relevant quantitative
   observations, failures, durable artifact locations, and any user interpretation.

When the task authorizes implementation or execution, the record update is part of that
workflow. Do not create a commit, push, publish, or upload merely because the record
changed; those actions still require their normal authorization.

## Repositories still on `NOTES.md`

- Search only within the current repository or another bounded project root. Prefer the
  most specific existing notebook: a campaign notebook beside its configs over a
  repository-wide notebook. Read it before substantive work; for a very large notebook,
  scan headings and tail first.
- A read-only status, explanation, or review request does not authorize a notes edit.
- Follow the notebook's established structure. Add each checkpoint as a complete block at
  the end of the file, with a locally correct timestamp (`## YYYY-MM-DD — concise
  subject`). Keep planned work visibly separate from measured results. Correct an older
  claim by appending a timestamped correction; never rewrite the trail.
- Configure the root `.gitattributes` so notebooks use Git's union merge driver
  (`NOTES.md merge=union`, `**/NOTES.md merge=union`) with
  `scripts/enable-notes-merge.sh`; refuse to override another driver. After a merge that
  touched notes, verify each entry appears once, uninterleaved, in intelligible order;
  never use a whole-file `ours`/`theirs` resolution for a research notebook.
- Migrating a repository off `NOTES.md` is one-time, per-repository work: follow the
  stage-1 / stage-2 protocol in `references/vault-protocol.md`. The tooling used for
  `srs-campaign` lives in that repository (`utils/vault-migration/`) as a worked example,
  not as a general tool.
