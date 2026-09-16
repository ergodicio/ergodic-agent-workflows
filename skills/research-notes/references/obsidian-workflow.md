# Obsidian Research Workflow

Use this protocol after `scripts/resolve-shared-vault.py` returns the shared vault root.
The vault is the canonical research record.

## Resolve and read the live conventions

The resolver gives precedence to `ERGODIC_RESEARCH_VAULT`, then looks for the exact vault
name `Ergodic Research` in Obsidian's bounded local registry files. The environment
variable is the supported configuration for headless agents and machines without the
Obsidian desktop application. It must point at the synced vault root containing `Notes/`.

Read the resolved vault's `README.md`, `Templates/Investigation.md`, and
`Templates/Checkpoint.md` before its first write in a task. Those live files are
authoritative for vault layout, frontmatter, and checkpoint formatting.

## Recover relevant context

- Limit discovery to the vault's `Notes/<repository-name>/` project folder and directly
  linked notes. Never recursively search the whole vault.
- Prefer notes whose repository, branch, campaign, run IDs, or subject match the current
  work. Use timestamps and links to identify the newest relevant context.
- Read enough of those notes to recover prior decisions, results, corrections, and open
  questions before substantive work. Do not edit historical session notes merely to mark
  them as read.

## Give each session a unique note

- Put the note under `Notes/<repository-name>/`, using an existing project folder when its
  name clearly corresponds to the repository. Create that one bounded folder if missing.
- Use a globally unique filename. Prefer
  `YYYY-MM-DD-HHmmss-<person-or-agent>-<short-subject>-<uuid8>.md`.
- Never use a shared project log as the write target. Parallel agents create separate
  notes and connect them with `[[wikilinks]]`.
- Treat the note as owned by its creating session unless an explicit handoff says
  otherwise. Follow the investigation template and link the relevant prior notes.

## Record checkpoints, not narratives

For every meaningful checkpoint, generate a stable ID such as
`YYYYMMDDTHHMMSSZ-<uuid8>` and append the ground-truth checkpoint to the session note.
Include its state, provenance, observations, artifact locations, and open questions. Keep
planned work separate from measured results.

If a vault write fails, report the failure and retain the intended checkpoint ID for a
retry. Do not create a second record elsewhere or claim the checkpoint is durable until
the write succeeds.

Do not copy historical records wholesale during ordinary work. Link to older context as
needed. Obsidian Sync, not Git, transports vault notes; do not add the external vault to a
repository commit.
