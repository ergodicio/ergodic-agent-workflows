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
- Use `python3 scripts/recall.py --project <project-folder> --query "<question>"`, relative
  to the skill directory, to retrieve bounded evidence. See [recall.md](recall.md) for
  output semantics and supported correction links. The project is the actual vault folder,
  not an inferred alias or an unrestricted filesystem path.
- Prefer matching repository, campaign, branch, run IDs, and subject. Read the cited
  sections and their corrections to produce the context brief required by `SKILL.md`.
  Timestamps help reconstruct order; they do not establish authority or comparable scope.
- Preserve explicit missing evidence and conflicting results. A partial corpus or unresolved
  correction link must not be treated as a complete history. Follow exact cross-project
  links separately only when authorized; do not broaden into an unbounded vault search.
- Verify live operational state against the authoritative service. Do not edit historical
  session notes merely to mark them as read.

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
