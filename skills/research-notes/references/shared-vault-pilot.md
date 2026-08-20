# Shared Vault Pilot

Use this protocol only after `scripts/resolve-shared-vault.py` returns the shared vault
root. During the pilot, the relevant repository `NOTES.md` remains required and
canonical; the vault is a cross-repository mirror of new microscopic work.

## Resolve and prepare the destination

The resolver gives precedence to `ERGODIC_RESEARCH_VAULT`, then looks for the exact vault
name `Ergodic Research` in Obsidian's bounded local registry files. The environment
variable is the supported configuration for headless agents and machines without the
Obsidian desktop application. It must point at the synced vault root containing `Notes/`.

Read the resolved vault's `README.md`, `Templates/Investigation.md`, and
`Templates/Checkpoint.md` before its first write in a task. Those live files are
authoritative for vault layout, frontmatter, and checkpoint formatting.

## Give each session a unique note

- Put the note under `Notes/<repository-name>/`, using an existing project folder when its
  name clearly corresponds to the repository. Create that one bounded folder if missing.
- Use a globally unique filename. Prefer
  `YYYY-MM-DD-HHmmss-<person-or-agent>-<short-subject>-<uuid8>.md`.
- Never use a shared project log as the write target. Parallel agents create separate
  notes and connect them with `[[wikilinks]]`.
- Treat the note as owned by its creating session unless an explicit handoff says
  otherwise. Follow the vault's investigation template, record the repository notebook
  path in the vault note, and record the vault-relative note path in `NOTES.md`.

## Mirror checkpoints, not narratives

For every meaningful checkpoint, generate one stable ID such as
`YYYYMMDDTHHMMSSZ-<uuid8>` and include it in both records.

1. Append the checkpoint to the relevant repository `NOTES.md`.
2. Append the same ground-truth checkpoint to the session's vault note.

Each destination may follow its local format, but the checkpoint ID, state, provenance,
observations, artifact locations, and open questions must agree. Keep planned work
separate from measured results in both places.

If the vault write fails after the repository append, do not alter or delete the
repository entry. Append or include a concise mirror-failure status associated with the
same checkpoint ID, report the failure, and reuse that ID when retrying. Never invent two
independent accounts of the same checkpoint.

Do not copy historical notebooks wholesale during ordinary work. Mirror new checkpoints
created during the pilot and link to older repository context as needed. Obsidian Sync,
not Git, transports vault notes; do not add the external vault to a repository commit.
