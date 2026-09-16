---
name: research-notes
description: Maintain append-only research records as uniquely named notes in the shared Obsidian vault. Use for scientific simulations, experiments, numerical investigations, and multi-session research decisions; do not use for routine code maintenance with no research record.
---

# Research Notes

Treat the shared Obsidian vault as the canonical research memory and audit ledger, not as
polished documentation or a transcript of agent activity. Preserve enough ground truth
that a later researcher can reconstruct what was tried, why, what happened, and what
changed next.

## Resolve the vault and recover context

Before substantive research work, run `scripts/resolve-shared-vault.py`, relative to this
`SKILL.md`. It checks only explicit configuration and bounded Obsidian registry files;
never recursively search for a vault.

- If it resolves a vault, read
  [references/obsidian-workflow.md](references/obsidian-workflow.md) completely and follow
  it. Read the vault's live instructions and relevant project notes before acting.
- If the path resolves but the execution sandbox blocks access, use the normal approval
  path for that exact vault.
- If the vault cannot be resolved or accessed, report why and do not create another vault
  or a repository-local substitute. Do not claim that a checkpoint was recorded.
- A read-only status, explanation, or review request does not authorize a notes write.

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
secret-bearing command in the vault.

## Preserve the epistemic boundary

- Record the agent's ground-truth observations in neutral, reproducible language: run
  status, numerical changes, controlled differences, errors, and artifact contents.
- Do not infer physics, diagnose a root cause, declare convergence, or opine on method
  suitability from a plot or trend alone. A visible field increase is an observation;
  calling it an instability is an interpretation.
- Record the user's reasons, hypotheses, interpretations, and goals verbatim when they
  matter, labeled `USER (verbatim)`. Do not paraphrase them into an agent conclusion.
- If the task explicitly requires analysis or hypothesis generation, keep proposed
  explanations clearly separate from measured facts and do not record them as findings
  unless the user adopts them or a designed test establishes them.
- Err on the side of recording relevant research information. During authorized research
  work, do not ask whether to update the vault; update it at the appropriate checkpoint.

## Write append-only checkpoints

- Use the unique session note selected or created through the Obsidian workflow. Do not
  append to a shared project log.
- Follow the vault's live templates and the note's established structure.
- Add each checkpoint as a complete block at the end of the note with a stable checkpoint
  ID and a locally correct timestamp.
- Keep planned work visibly separate from measured results. Do not turn a submitted job
  into a result or a hypothesis into a finding.
- Correct an older claim by appending a timestamped correction that points back to it.
  Never silently rewrite or delete the old research trail.
- Update the note after obtaining a material result or reaching a decision, before the
  context is lost. If authorized work ends at a real blocker, record the blocker and the
  fact that no result was produced.

For a run or scan, make checkpoints at these times:

1. **Before submission:** record run number and date, source and material dependency
   commits, config, key differences from the previous run, and the user's reasons,
   hypotheses, and goals verbatim. This is pre-registration, not retrospective narration.
2. **Immediately after submission:** append the scheduler or allocation ID and the run or
   experiment tracking ID as soon as each exists. Keep the state `LAUNCHED` or `PENDING`.
3. **After inspection or completion:** append the actual status, relevant quantitative
   observations, failures, durable artifact locations, and any user interpretation.

When the task authorizes implementation or execution, the associated vault update is part
of that workflow. Do not create a commit, push, publish, or upload merely because the
research record changed; those actions still require their normal authorization.
