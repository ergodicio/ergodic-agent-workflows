# Vault Protocol

The research record lives in the shared Obsidian vault **Ergodic Research**. This
document is the operating protocol for agents; the vault's own `README.md`,
`Templates/Campaign.md`, `Templates/Investigation.md` and `Templates/Checkpoint.md` are
authoritative for layout, frontmatter and checkpoint formatting — read them before the
first write in a task. It replaces the dual-write pilot (`shared-vault-pilot.md`, retired
2026-09-08).

## Resolve the vault, never search for it

Run `scripts/resolve-shared-vault.py` (relative to `SKILL.md`). It honours
`ERGODIC_RESEARCH_VAULT`, then the exact vault name in Obsidian's bounded registry files.
Every agent session runs on the laptop that holds the vault, so failure to resolve is an
error to report, not a reason to write elsewhere: keep the checkpoint text in the job's
scratch directory, say the vault was unreachable, and never append to a frozen repository
notebook.

## Three note types

- **Campaign hub** — `Notes/<project>/<study>/<study>.md`, `type: campaign`. One per
  study even when it spans OSIRIS, WarpX and LPSE. Holds what belongs to no single
  episode: the question, the USER request verbatim, decks and grid, files, runbook, the
  executions table, current status, trust caveats. **Edited in place; never a log.**
- **Investigation** — `Notes/<project>/<study>/<unique name>.md`, `type: investigation`,
  `campaign: "[[<study>]]"`. One question pursued to a result; append-only checkpoints.
  Engine-validation work is an investigation tagged `validation/hardware|scaling|smoke`
  with no hub, loose under `Notes/<project>/`.
- **Archive** — `Archive/<project>/<study>/archive-<engine>-<campaign>-NOTES.md`,
  `type: archive`. The byte-exact copy of a migrated repository notebook. Body frozen;
  only `translated`, `translated-to`, `translated-on` change.

## Start of a task

1. Resolve the vault; read the hub for the study you are working on (Status, Executions,
   USER quotes, trust caveats). If the hub's log sections are still untranslated, read the
   archive sections it links before relying on any number.
2. If the study has no hub and the work has a standing spec (decks, a grid, an MLflow
   experiment), create the hub from `Templates/Campaign.md` first, named the established
   campaign name. Otherwise write a loose investigation.
3. Create the investigation note from `Templates/Investigation.md`:
   `YYYY-MM-DD-HHmmss-<person-or-agent>-<short-subject>-<uuid8>.md` in the study folder,
   `campaign` set, `engines`, `mlflow-experiment-ids` filled as soon as they exist.

## Checkpoints

One stable ID per material checkpoint, `YYYYMMDDTHHMMSSZ-<uuid8>`, in the block's
**Checkpoint ID** field. Insert the `Checkpoint` template at: pre-registration (before a
submission — run number and date, commits, config, key differences, the user's reasons
verbatim), immediately after submission (job id, run/experiment id, state LAUNCHED or
PENDING), and after inspection or completion (actual status, quantitative observations,
failures, artifact locations, user interpretation verbatim). Correct an earlier block by
appending a new one that names it in **Corrects**. Update the hub's *Status* in place when
the study's state changes; put nothing else in the hub.

## Trust caveats

When a number is known to be untrusted (a mis-calibrated driver, a diagnostic reading
the wrong cells, a superseded ladder), mark it three ways: the `trust` property on the hub
and on every investigation that carries the number; a callout at the top of the hub with
the USER's words and date; and inline at the point of use — a `†` on every affected table
row, never only in prose above the table. `Bases/Trust caveats` lists every note with a
`trust` entry.

## Translating an archive (stage 2)

Do this when you next work on a study whose archives are still `translated: false`
(`Bases/Archive backlog`). It is judgement work: read the archive end to end first, never
bulk-automate it.

1. Split the archive's H2 sections into **episodes** — a question pursued to a result,
   usually several dated sections. Reference material (spec, decks, runbook) goes to the
   hub if it is not already there, not into an investigation.
2. One investigation note per episode, named `YYYY-MM-DD-migrated-<subject>-<uuid8>.md`
   (the episode's start date; "migrated" marks it as a translation). Frontmatter carries
   `translated-from` (the archive link, or a list), `source-sections` (the H2 headings
   consumed, per archive), `translated-by`, `campaign`, `trust` where it applies, and the
   tag `migrated/translated`.
3. Each checkpoint block carries a **Source** line — `[[archive#Heading]]` with the line
   range — and a Checkpoint ID of the form `YYYYMMDD-migrated-<uuid8>-<nn>`. Dates are the
   source's; do not invent times of day.
4. Keep the source's wording wherever an observation and an interpretation cannot be
   told apart; keep every USER quote verbatim; keep the source's own labels (MEASURED,
   SPECULATION (Claude), CONJECTURE (USER), WITHDRAWN).
5. Carry every trust caveat to the point of use in the translated note.
6. When every H2 of the archive is consumed by a note or the hub, set on the archive
   `translated: true`, `translated-on`, and `translated-to` (the list of notes); change the
   hub's "Log sections (archived, untranslated)" headings to say translated. Never edit an
   archive body — the migration script's fidelity gate must still pass.

## Migrating a repository that is still on `NOTES.md`

Stage 1 is mechanical and is scripted per repository. Write a **study map** first: which
notebooks form one study, the dominant member, status, MLflow ids, tags, trust caveats,
banners to promote. Then, per study: a byte-exact archive per notebook (gated — the
archive body must equal the source bytes) and a hub with the reference sections copied
and the log sections linked into the archive; validation notebooks become tagged
investigation stubs. Dry-run into a scratch vault (`--vault <dir with Notes/>`) and read
the generated hubs before touching the real vault; import in batches with Obsidian open
on one device; freeze the repo notebooks into pointer stubs only after every archive is
verified and Obsidian Sync version history covers the vault. Resolve the vault with
`scripts/resolve-shared-vault.py`; never search for it.

The tooling used for `srs-campaign` on 2026-09-08 lives in that repository,
`srs-campaign/utils/vault-migration/` (migration script, freeze script, study map,
README). It is a worked example, not a general tool: its engine order, section-classifier
vocabulary, one-notebook-per-directory layout and H2-only sectioning are srs-campaign's.
`references/vault-transition-plan.md` records the decisions behind the layout and how
the execution went.

## Never

- Append material events to a hub.
- Edit an archive body, or delete an archive.
- Put credentials, secrets, private keys, large raw logs or generated datasets in the
  vault; link to durable artifact locations instead.
- Commit the vault to a repository or sync it with git; Obsidian Sync is the transport.
