---
name: research-notes
description: Maintain research records and consume shared-vault NERSC investigation handoffs. Use for scientific simulations, experiments, numerical investigations, and multi-session research decisions; do not use for routine code maintenance with no research record.
---

# Research Notes

Treat the relevant `NOTES.md` as persistent research memory and an audit ledger, not as
polished documentation or a transcript of agent activity. Preserve enough ground truth
that a later researcher can reconstruct what was tried, why, what happened, and what
changed next.

The shared Obsidian vault is being evaluated as a cross-repository view of the same
microscopic work. During this pilot, `NOTES.md` remains required and canonical. When the
vault is available, mirror each material checkpoint there as well. Do not replace or
weaken the repository record until the team explicitly ends the pilot.

## Find the notebook first

- Search only within the current repository or another bounded project root.
- Prefer the most specific existing notebook: a campaign notebook beside its configs and
  runners over a repository-wide notebook. Use a root notebook for work that spans
  campaigns or has no narrower home. Do not duplicate the same entry at both levels.
- Read the relevant notebook before substantive work. For a very large notebook, scan its
  headings and tail first, then read the sections related to the current question.
- A read-only status, explanation, or review request does not authorize a notes edit.

## Mirror to the shared vault during the pilot

Before the first authorized research write in a task, run
`scripts/resolve-shared-vault.py`, relative to this `SKILL.md`. It checks only explicit
configuration and bounded Obsidian registry files; never recursively search for a vault.

- If it resolves a vault, read [references/shared-vault-pilot.md](references/shared-vault-pilot.md)
  completely and follow its dual-write protocol.
- If it cannot resolve the vault, keep the required `NOTES.md` record, report that the
  mirror was skipped and why, and do not block the research work or create another vault.
- If the path resolves but the execution sandbox blocks the write, use the normal
  approval path for that exact vault. If access remains unavailable, handle it as a
  skipped mirror.

## Consume NERSC investigation handoffs

When the user asks a local agent to find, claim, run, or return a NERSC investigation
request from the shared vault, read
[references/nersc-investigation-handoff.md](references/nersc-investigation-handoff.md)
completely and follow its executor protocol. It composes this skill's dual-write research
record with `nersc-workflow`; it does not replace either one.

This path is only for an agent running on a local machine that already has the user's NERSC
access. A credential-free requesting agent writes the handoff into the vault but does not
receive an SSH proxy key or use this executor path.

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
secret-bearing command in the notebook.

## Preserve the epistemic boundary

- Record the agent's ground-truth observations in neutral, reproducible language: run
  status, numerical changes, controlled differences, errors, and artifact contents.
- Do not infer physics, diagnose a root cause, declare convergence, or opine on method
  suitability from a plot or trend alone. A visible field increase is an observation;
  calling it an instability is an interpretation.
- Record the user's reasons, hypotheses, interpretations, and goals verbatim when they
  matter, labeled `USER (verbatim)`. Do not paraphrase them into an agent conclusion.
- If the task explicitly requires analysis or hypothesis generation, keep proposed
  explanations clearly separate from measured facts and do not put them in the durable
  ledger as findings unless the user adopts them or a designed test establishes them.
- Err on the side of recording relevant research information. During authorized research
  work, do not ask whether to update `NOTES.md`; update it at the appropriate checkpoint.

## Write append-only entries

- Follow the notebook's established structure and level of detail.
- Add each checkpoint as a complete block at the end of the file. For new notebooks, use a
  short title and one sentence explaining their scope.
- During the vault pilot, include the shared checkpoint ID and vault-relative note path in
  each new repository checkpoint when a vault was resolved.
- Use a locally correct timestamp in new top-level entries, preferably
  `## YYYY-MM-DD — concise subject`. Preserve a notebook's established run numbering and
  heading style; include local time and timezone when concurrent branches or same-day
  entries need deterministic ordering.
- Keep planned work visibly separate from measured results. Do not turn a submitted job
  into a result or a hypothesis into a finding.
- Correct an older claim by appending a timestamped correction that points back to it.
  Never silently rewrite or delete the old research trail.
- Update the notebook after obtaining a material result or reaching a decision, before the
  context is lost. If authorized work ends at a real blocker, record the blocker and the
  fact that no result was produced.

For a run or scan, make the checkpoints at these times:

1. **Before submission:** record run number and date, source and material dependency
   commits, config, key differences from the previous run, and the user's reasons,
   hypotheses, and goals verbatim. This is pre-registration, not retrospective narration.
2. **Immediately after submission:** append the scheduler or allocation ID and the run or
   experiment tracking ID as soon as each exists. Keep the state `LAUNCHED` or `PENDING`.
3. **After inspection or completion:** append the actual status, relevant quantitative
   observations, failures, durable artifact locations, and any user interpretation.

When the task authorizes implementation or execution, the associated notes update is part
of that workflow. Do not create a commit, push, publish, or upload merely because the notes
changed; those actions still require their normal authorization.

## Make append-only notes merge safely

For repositories that track append-only notebooks, configure the root `.gitattributes` so
both root and nested notebooks use Git's built-in union merge driver:

```gitattributes
NOTES.md merge=union
**/NOTES.md merge=union
```

Use `scripts/enable-notes-merge.sh`, relative to this `SKILL.md`, to add the missing rules
without replacing existing attributes. Do this when adopting the convention or creating
the first tracked notebook. If the repository deliberately assigns another merge driver
to notes, stop and report the conflict instead of overriding it.

Union merge preserves both sides of an append conflict; timestamps do not themselves make
Git resolve the conflict. Union merge is safe here only because prior entries are
immutable. After a merge that touched notes, verify that each complete entry appears once,
that no entry was interleaved or truncated, and that ordering is intelligible. Reorder
whole entry blocks by timestamp when needed. Preserve conflicting scientific
interpretations as separate evidence rather than choosing one during merge cleanup.

If resolving a pre-existing conflict without the driver, keep every complete entry from
both sides, order whole blocks by timestamp, and remove only exact duplicates. Never use a
whole-file `ours` or `theirs` resolution for a research notebook.
