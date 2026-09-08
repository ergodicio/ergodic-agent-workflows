# Transitioning the NOTES.md convention into the Ergodic Research vault

Status: **executed through Phase 7 on 2026-09-08** (repo freeze committed as `b9242af` on
`srs-campaign` `main`). The
dual-write pilot document is retired; the operating protocol is
[vault-protocol.md](vault-protocol.md). This document is the record of the decisions and
of how the execution departed from them (§10).

**USER decisions, 2026-09-08:** scope is `srs-campaign` only; the `<engine>` folder level is
dropped because many studies compare across engines and belong in one note (§4); no agent
session runs on Perlmutter, so the vault is canonical with no repo-side residue (§1c, D1);
`domain-knowledge/` stays in git and is out of scope (§2, Phase 5); history is imported
**verbatim into a segregated `Archive/`** and later *translated* into investigations, with
the verbatim copy retained as insurance (D2/D3); M2 merges with untrusted numbers marked;
M3 narrow; engine-validation notebooks become tagged investigations, not hubs (§4.5).

---

## 1. What exists today

**Repository side — 44 notebooks, 20,451 lines, 1.21 MB** (excluding the 17 tombstoned
copies under `_archive/`):

| Repo | Notebooks | Lines |
|---|---|---|
| `srs-campaign` (`sims/{osiris,warpx,lpse}/<campaign>/`) | 27 | 13,218 |
| `kinetic-srs` (`sims/<campaign>/`) | 15 | 6,955 |
| `lagradept-apps` (`<app>/sims/<campaign>/`) | 1 | 158 |
| `adept-light-coupling` (repo-root notebook) | 1 | 120 |

Largest: `srs-Ln-Te-I-scan2` (2,088 lines), `gradient-srs-hermite-poisson` (1,554),
`srs-2d-testbed` (~1,160, still growing). Two repo-root indexes point at them: `srs-campaign/simulations.md`
(28 campaign rows) and `kinetic-srs/simulations.md`.

**Vault side —** `Ergodic-projects/Ergodic Research/`, 20 notes under `Notes/<project>/`
for five projects: `adept`, `broadband-lpi`, `lagradept`, `srs-campaign`, `vp-turbulence`.
All created 2026-08-31 → 09-07 under the dual-write pilot. Note that `broadband-lpi` and
`vp-turbulence` have **no repo in this tree** — the vault is already wider than this laptop.

Core plugins on: templates, properties, **bases**, sync, graph, backlink, tag-pane,
daily-notes. No community plugins — so **Bases, not Dataview**, is the query layer.

### Three facts that shape the whole plan

**(a) NOTES.md files are not logs. They are hybrid documents.** Each is a stable
reference head — *why this campaign exists*, the deck/geometry tables, the files table,
the launch runbook, assumptions, provenance — followed by an append-only run log. Across
the corpus, dated `## YYYY-MM-DD` sections are rare: median 0 per file, and only
`srs-Ln-Te-I-scan2` (34) and `lpse-srs-scan-test` (6) look like real chronologies.

The vault's current model is the opposite: **one uniquely-named note per session**, which
is what makes Obsidian Sync safe under parallel agents. Neither model alone fits. A naive
"one vault note per checkpoint" migration shreds the reference half of every campaign; a
naive "one vault note per campaign" migration reintroduces exactly the write contention
the vault's naming scheme was designed to avoid.

**(b) The corpus is unusually clean to migrate.** Two relative markdown links (the
`srs-Ln300-Te4-5x` and `srs-Ln500-Te4-lown` preambles point at `../srs-Ln-Te-I-scan/NOTES.md`),
zero image embeds, zero wikilinks across all 44 files. Every path reference is inline code in backticks, which
stays valid as text in any location. **There is nothing to rewrite** — only to split and
re-frame. This is the single biggest reason to do a real backfill rather than a
forward-only cutover.

**(c) The vault is reachable at every moment a record must be written.** USER, 2026-09-08:
*"no agents run on perlmutter itself (laptop is fundamental)"*. Every agent session runs on
the laptop and drives Perlmutter over ssh, so the Obsidian-Sync'd vault is on the same
machine as the process doing the recording — including at the two moments the convention
cares most about, immediately before and immediately after a job is submitted. There is no
point in the workflow where a record has to be written somewhere the vault is not. This
removes the only functional argument for keeping a parallel repository-side log, and lets
the vault be canonical outright rather than a mirror.

---

## 2. Target model: note types

| Type | Cardinality | Churn | Owner | Replaces |
|---|---|---|---|---|
| `campaign` | one per **study** (may span engines) | low, edited in place | one owner of record | the reference head of NOTES.md |
| `investigation` | one per session/question | append-only | creating session | the run-log tail of NOTES.md |
| `archive` | one per **source notebook** (27) | frozen, never edited | n/a | the raw NOTES.md, byte-for-byte |
| `reference` | *reserved — no source in this migration* | — | — | — |

A **campaign note** is a hub over a *study*, not a single execution (§4.1): identity,
motivation and the verbatim user request, the
config/deck/geometry spec, the files table, the launch runbook, current status, a run
table (MLflow experiment + SLURM ids), and an embedded Base listing every investigation
whose `campaign` property points at it. It is the thing you open first and the thing you
link to. It is *editable in place* — it describes the campaign as it stands, not as a
history.

An **investigation note** is what the vault already produces, unchanged: unique filename,
`Investigation` template, append-only checkpoints, corrections appended not rewritten.
Gains one property, `campaign:`, wikilinked to its hub.

`reference` was to have been fed by `srs-campaign/domain-knowledge/` (17 items including
`paper_notes/`). **USER 2026-09-08: that stays in git**, so this migration produces no
reference notes. The type stays in the vocabulary — the vault README already anticipates
notes that are not investigations, and vault-native reference notes may appear later — but
nothing is moved into it, and the `research-docs` boundary question it would have forced
does not need answering yet.

An **archive note** is a frozen, verbatim copy of one source `NOTES.md`. It is not the
end state: per D2 the log content gets *translated* into proper investigation notes so the
vault is internally consistent, and the archive is kept as the thing you diff against if
the translation loses something. It lives outside `Notes/` (§4.1) so it stays out of the
graph, the Bases and the day-to-day search surface.

**Engine-validation notebooks become investigations, not hubs** (USER, §4.5) — "does the
tooling work" is an episode, not a campaign with a standing spec.

So the migration produces `campaign` hubs, frozen `archive` notes, and — first by
translation, then by ordinary use — `investigation` notes.

**Do not add a `run` note type.** MLflow is already the run database. Runs live in the
campaign note's run table and in the checkpoints that launched them.

---

## 3. Decisions before any file moves

### D1 — Does the repository keep a record at all? **RESOLVED 2026-09-08: no**

Earlier drafts proposed a thin machine-written `runlog.md` beside each config, on the
premise that launches recorded from a Perlmutter login node could not reach the vault.
USER corrected the premise (§1c): agents run on the laptop and drive Perlmutter over ssh,
so the vault is always reachable. The proposal is dropped.

**The vault is canonical. The repository keeps no parallel research record** — only the
frozen `NOTES.md` stubs from Phase 7, which name the vault hub and are not appended to.
Two rejected alternatives, recorded so they are not re-proposed: a `runlog.md` residue
(no longer motivated, and a second place for the record to drift), and git-backing the
vault to clone it on Perlmutter (Sync and git transporting the same files invites
conflicts, and it puts the vault inside a sync path that must stay data-free).

### D2 — Backfill history? **RESOLVED 2026-09-08: yes, verbatim first, translated second**

USER: *"let's have them verbatim starting out, but in an archive/ folder. We'll want to
translate these notes into 'investigations' to be consistent with the rest of the Vault,
but want to have a verbatim copy just in case anything gets lost in this translation."*

So the backfill is **two stages, not one**, and the second is the one that matters:

**Stage 1 — verbatim import (mechanical, bulk, cheap).** Every source `NOTES.md` is copied
byte-for-byte into `Archive/srs-campaign/<study>/`, `type: archive`, `status: superseded`,
frozen. This is the only step covered by the fidelity gate of §6, and it is the step that
makes everything after it reversible. 27 files, 13,218 lines.

**Stage 2 — translation (judgement, incremental, expensive).** The log content of each
archive is rewritten into proper `investigation` notes so the vault reads consistently,
with the reference material lifted into the hub. Translation is *interpretive* — it picks
episode boundaries, normalises checkpoint blocks, separates observation from
interpretation — and interpretive work on a research record is exactly what the
append-only convention normally forbids. The verbatim archive is what buys the permission:
nothing is lost, because the original is still there to diff against.

Two consequences worth stating plainly:

- **The archive is insurance, not the searchable record.** It stays out of `Notes/`,
  out of the graph and out of the default Bases. Search still reaches it — Obsidian
  searches the whole vault — but it is not part of the working surface.
- **Stage 2 does not have to be a phase.** It can be lazy: translate a study the next
  time you actually work on it, so the cost lands on active campaigns and the dormant ones
  keep their verbatim copy indefinitely. Recommend lazy translation with two exceptions
  done up front — the M1 and M3 hubs — because those are the two studies where a
  correction supersedes numbers held in a different source notebook, and leaving that
  untranslated is how the stale figure gets cited.

### D3 — Splitting granularity **REVISED 2026-09-08**

An earlier draft said: never reconstruct investigation notes retroactively, because there
is no reliable session boundary in the text and inventing one silently rewrites the
research trail. D2 answers that objection rather than overriding it — the rewrite is not
silent and not lossy while the verbatim archive stands. Retroactive translation is
therefore in scope, with these constraints:

- **Stage 1 splits mechanically, at existing H2 boundaries only** — hub material vs. log
  material, nothing else. No reflowing, no rewording, no merging of adjacent blocks.
- **Stage 2 picks episode boundaries by judgement**, using the existing H2/H3 log sections
  as the seam. An episode is a question pursued to a result, which in this corpus usually
  spans several dated sections. Do **not** bulk-automate this the way Stage 1 is
  automated, and do not translate a study without reading it end to end first.
- **Every translated investigation cites its archive** (`translated-from:` pointing at the
  archive note plus the source H2 headings it consumed), so any claim can be walked back
  to the byte-exact original.
- **Where the source is ambiguous, keep the source's wording.** A translation that cannot
  tell an observation from an interpretation must preserve the original sentence rather
  than pick one — the epistemic boundary in `srs-campaign/CLAUDE.md` still governs.

### D4 — The nested-vault problem

`/Users/phil/Things/Ergodic-projects` is itself a registered Obsidian vault, and it
*contains* the `Ergodic Research` vault. Every migrated note will be indexed twice, and
`[[wikilinks]]` — which Obsidian resolves by basename — become ambiguous across the two
graphs. Fix before importing: either add `Ergodic Research` to the outer vault's excluded
files (`userIgnoreFilters` in its `app.json`), or drop the outer vault registration
entirely. Recommend excluding; the outer vault is still useful for reading repo markdown.

---

## 4. Folder structure and study grouping

### 4.1 Decision (USER, 2026-09-08)

Scope is **`srs-campaign` only**. The engine level is **dropped**, and the verbatim
archive is segregated out of `Notes/` entirely (D2):

```
Notes/srs-campaign/
    <study>/                              13 study folders
        <study>.md                        campaign hub — one per STUDY
        <investigations>.md               translated from the archive, then appended to
    <validation>.md                       5 loose validation notes, tagged (§4.5) —
                                          stubs at stage 1, filled in by translation

Archive/srs-campaign/
    <study>/
        archive-<engine>-<campaign>-NOTES.md    verbatim, frozen, one per SOURCE notebook
    archive-osiris-test-srs-NOTES.md            validation sources, no study folder
```

`Archive/` sits at the vault root beside the existing `Attachments/` and `Templates/`
rather than inside each study folder. Both readings of USER's "in an archive/ folder"
satisfy the ask; top-level is the better one because it makes exclusion a single path
filter — the Bases, the graph and the file explorer all stay clean without per-note
tagging, and the whole tree can be retired in one move once translation is verified. If
you would rather see the archive next to its hub, it is a one-line change to the migration
script and nothing else in this plan depends on it.

USER's reason: many studies compare across engines and belong in one note. That
reframes the hub: **one hub per study, not per execution.** A study may have an OSIRIS
execution, a WarpX execution and an LPSE execution; each keeps its own verbatim archive
note, and the hub above them carries the shared question, the matched parameters, the
comparison, and the corrections that apply across engines.

Merging hubs is lossless: the archive notes are per-source-notebook and unchanged, so
nothing in the 13,218 lines is discarded by grouping four notebooks under one hub.

**Hub naming rule (USER, 2026-09-08): use the established name.** Where a merge has a
dominant or origin member, the hub takes that member's existing name; invent a name only
when no member dominates. Two reasons this is not cosmetic — a hub renamed away from its
MLflow experiment breaks the one string joining the vault note to the tracking server, and
an invented name can land confusingly close to a sibling hub that survived the merge. So
M1 is `srs-1d-ppc-scan` (the name of the shared MLflow experiment, not the invented
`srs-1d-ppc-convergence`) and M3 is `srs-Ln-Te-I-scan2` (its dominant member, not
`srs-threshold-scan`, which sat badly beside the surviving `srs-threshold-recheck` and
`srs-Ln-Te-I-scan` hubs). M2 `srs-2d-follett` is already the OSIRIS member's name; M4
`srs-Ln100-Te4` is a genuine common prefix colliding with nothing.

The hub file is `<study>.md` inside `<study>/` — named for the study, never a generic
`_campaign.md`, because Obsidian resolves `[[wikilinks]]` by basename and thirteen files
sharing one name are unresolvable.

### 4.2 The one hard collision

Dropping the engine level produces exactly **one** basename collision across the 27
notebooks:

| Path | Title line |
|---|---|
| `sims/osiris/srs-1d-ppc-scan/NOTES.md` | `# srs-1d-ppc-scan (OSIRIS half)` |
| `sims/warpx/srs-1d-ppc-scan/NOTES.md`  | `# srs-1d-ppc-scan (WarpX half)` |

The collision and the merge are the same event: these are two halves of one study by
their own first paragraph. No other name repeats — the `-3um`/`-6um`/`-vgap`/`-1d`
suffixes already disambiguate.

Two titles carry a redundant engine prefix that should be dropped on migration:
`# osiris-srs-coll-cpu-vs-gpu` and `# osiris-srs-test-ions-coll`.

### 4.3 Cross-engine studies that merge into one hub

**M1 — `srs-1d-ppc-scan`  ← 4 notebooks, 1,901 lines**

| Source | Lines | Role |
|---|---|---|
| `osiris/srs-1d-ppc-scan` | 842 | OSIRIS ladder; holds the full USER quote trail and both comparison directories |
| `warpx/srs-1d-ppc-scan` | 370 | WarpX ladder |
| `warpx/srs-1d-antenna-cal` | 154 | opened *because* the comparison left two conjectures open |
| `warpx/srs-1d-ppc-scan-vgap` | 535 | the rerun that resolved them |

Evidence: both halves declare each other in their opening paragraph and share the single
MLflow experiment `srs-1d-ppc-scan`; the cross-engine analysis lives in
`osiris/srs-1d-ppc-scan/comparison_osiris_warpx/analysis.md` and
`comparison_osiris_warpx_vgap/analysis.md`; the antenna-cal notebook states it exists to
close conjectures raised by that comparison, and vgap states that the antenna
miscalibration made **every logged R/A of the original WarpX ladder an artifact**
(true R at ppc 8192 = 0.470, logged 0.077).

That last point is the argument for merging all four rather than two: the correction
supersedes numbers held in a different file. Four separate notes is the arrangement in
which someone cites the stale ratio — which has already happened once (the vgap metrics
were re-post-processed 2026-08-28 but the comparison figures were never rebuilt).

**M2 — `srs-2d-follett`  ← 3 notebooks, 1,579 lines**

| Source | Lines | Role |
|---|---|---|
| `osiris/srs-2d-follett` | 537 | reproduce R. Follett's 2D deck in OSIRIS (the reference) |
| `warpx/srs-2d-follett-3um` | 277 | "matched to the OSIRIS reference run `follett2d-3um-Te1keV-4gpu`" |
| `warpx/srs-2d-follett-6um` | 765 | "derived from `srs-2d-follett-3um`" |

**DECIDED 2026-09-08: merge, with the untrusted numbers made explicit.** USER: *"yes, merge
the two, but make explicit that those numbers are untrusted."*

The hazard being managed: `-6um` opens with a USER banner — *"the laser driver these runs
cannot be trusted… reflectivity measurements and so on are not accurate. This is mostly a
vibes-only run"* — carrying an explicit instruction not to tabulate those scalars against
OSIRIS. `-3um` carries a derived warning that the same may apply to it, unconfirmed.
Merging puts untrusted WarpX scalars in the same note as the trustworthy OSIRIS reference.

Three mechanisms, all required — prose in one archive note is not sufficient, because the
whole point of merging is that people will read the hub instead:

1. **Frontmatter.** `trust: {warpx: untrusted-laser-normalized, osiris: ok}` on the hub, so
   a Base can surface every study carrying a trust caveat.
2. **Hub status block.** The `-6um` banner promoted verbatim to the top of the hub, quoted
   and attributed to USER with its date, covering both WarpX executions and stating that
   `-3um`'s exposure is unconfirmed.
3. **Point of use.** Every WarpX row in every comparison table in the hub marked inline
   (a `†` footnote or a `trust` column). A reader who scrolls straight to the table must
   not be able to read an untrusted number as a measurement.

Applies to the translated investigations too (D3), not just the hub.

**M3 — `srs-Ln-Te-I-scan2`  ← 2 notebooks, 2,525 lines**

| Source | Lines | Role |
|---|---|---|
| `osiris/srs-Ln-Te-I-scan2` | 2,088 | the 378-point OSIRIS scan of record |
| `lpse/lpse-srs-scan-test` | 437 | the 378-point LPSE replication |
| *(excluded — own hub)* `lpse/hpe-test` | 233 | exists to close the 63 LPSE-dead/OSIRIS-active points |
| *(excluded — own hub)* `osiris/srs-Ln-Te-I-scan` | 320 | scan v1, superseded |

Evidence: `lpse-srs-scan-test` runs the identical 378-point grid with run names identical
to scan2 *"so MLflow rows join across"*, mirrors each scan2 deck value, and ships
`comparison/compare_scan2.py`. `hpe-test` states it was implemented "to close the one
remaining fluid-vs-PIC gap of the scan2 replication — the 63 LPSE-dead-but-OSIRIS-active
points". `srs-Ln-Te-I-scan` is the run scan2's own USER quote describes as having "several
issues".

**DECIDED 2026-09-08: narrow.** Merge **scan2 + `lpse-srs-scan-test`** only — one grid,
joined run names, a comparison script. `hpe-test` and `srs-Ln-Te-I-scan` stay as separate
hubs, linked with `supersedes:` / `motivated-by:`. `hpe-test`'s subject is the HPE module
rather than the scan; `srs-Ln-Te-I-scan` is a distinct (failed) execution, and `superseded`
is a status, not a merge.

**M4 — `srs-Ln100-Te4`  ← 4 notebooks, 1,303 lines**

| Source | Lines | Role |
|---|---|---|
| `osiris/srs-Ln100-Te4-5x` | 204 | 8 runs, job 55960701 **cancelled while pending**, never executed |
| `osiris/srs-Ln100-Te4-5x-ions` | 759 | the CH-ion successor — cancelled the above to take its queue slot |
| `osiris/srs-Ln100-Te4-5x-eonly` | 237 | electron-only twins, **same MLflow experiment 188941** as `-ions` |
| `warpx/srs-Ln100-Te4-1d` | 103 | "targeting 1:1 comparison with the OSIRIS reference points (scan2 Ln100/Te4 and the 5x campaign)" |

The first three are one OSIRIS series — `-eonly` and `-ions` share experiment 188941 and a
`comparison_eonly_vs_ions/` directory — and the WarpX notebook exists to compare against
them. Note `srs-Ln100-Te4-5x` is a campaign that never ran; as a standalone note that is
misleading, as a phase of the merged hub it reads correctly.

### 4.4 What stays standalone (9 hubs)

`osiris/srs-1d-onset-time-duration`, `osiris/srs-Ln300-Te4-5x`,
`osiris/srs-Ln500-Te4-lown`, `osiris/srs-coll-electrons`, `warpx/srs-1d-ch-boundaries`,
`lpse/srs-2d-testbed`, `lpse/srs-threshold-recheck`, plus `lpse/hpe-test` and
`osiris/srs-Ln-Te-I-scan`, which stay standalone now that M3 is decided narrow.

### 4.5 Engine validation — tagged investigations, no folder

**DECIDED 2026-09-08.** USER: *"Engine validation should be their own investigations, not
in another folder, maybe as a tag?"* The earlier `_validation/` folder proposal is dropped.

Five notebooks answer "does the tooling work", not a physics question:

| Source | Lines | Tag |
|---|---|---|
| `osiris/srs-coll-cpu-vs-gpu` | 662 | `validation/hardware` |
| `osiris/srs-multinode` | 178 | `validation/scaling` |
| `osiris/test-srs` | 368 | `validation/smoke` |
| `osiris/test-twostream` | 210 | `validation/smoke` |
| `osiris/srs-test-ions-coll` | 268 | `validation/smoke` |

Each becomes an `investigation` note directly — **no campaign hub**. A validation exercise
is an episode with a question and an answer, not a campaign with a standing spec, a deck
table and a launch runbook; giving it a hub would leave most of the hub empty. They sit
flat in `Notes/srs-campaign/` alongside the study folders, which is also how the vault's
existing notes are arranged today.

`validation/*` joins the tag taxonomy of §5.5. The `Campaigns` Base excludes them by
tag rather than by path, and a `Validation` Base collects them. Two of the five have real
substance — `srs-coll-cpu-vs-gpu` at 662 lines is longer than most physics campaigns — so
they are worth translating properly (D3 stage 2) rather than left as archives.

### 4.6 Arithmetic

With M2 merged, M3 narrow, and validation as investigations rather than hubs:

| | Notebooks | Hubs | Other notes |
|---|---|---|---|
| M1 `srs-1d-ppc-scan` | 4 | 1 | |
| M2 `srs-2d-follett` | 3 | 1 | |
| M3 `srs-Ln-Te-I-scan2` (narrow) | 2 | 1 | |
| M4 `srs-Ln100-Te4` | 4 | 1 | |
| standalone physics (§4.4) | 9 | 9 | |
| engine validation (§4.5) | 5 | 0 | 5 investigations |
| **total** | **27** | **13** | **5 + N translated** |

**13 study folders, 13 hubs, 5 loose validation investigations, 27 frozen archive notes.**
The number of investigation notes is not fixed by the migration — it is whatever stage-2
translation produces, plus everything written from here on.

### 4.7 Consequences for the schema

Dropping the engine folder makes `engine` load-bearing as a property, and for a merged
study it is a **list**:

```yaml
engines: [osiris, warpx]          # was: engine, a single value implied by the path
executions:                        # one row per source campaign, the path being retired
  - {engine: osiris, path: sims/osiris/srs-1d-ppc-scan, mlflow-experiment: 189011}
  - {engine: warpx,  path: sims/warpx/srs-1d-ppc-scan,  mlflow-experiment: 189011}
supersedes: ["[[srs-Ln-Te-I-scan]]"]
trust: [laser-normalized scalars untrusted for warpx executions]   # M2
```

`executions` is what replaces the information the folder path used to carry, and is what
lets an agent get from a vault hub back to the right repo directory.

## 5. The organizations that are not folders

Folders are a single choice made once. Properties give every other cut for free, and the
`bases` core plugin is already enabled. **Pick the folder scheme for what is most stable
(campaign identity) and buy everything else with properties.**

### 5.1 Property schema (controlled vocabulary)

```yaml
type:        campaign | investigation | reference | archive
project:     srs-campaign | kinetic-srs | adept | lagradept | broadband-lpi | vp-turbulence
engine:      osiris | warpx | lpse | vlasov | lagradept | n/a
campaign:    "[[osiris-srs-Ln-Te-I-scan2]]"
status:      active | blocked | complete | superseded
started:     "YYYY-MM-DD HH:mm:ss"
updated:     "YYYY-MM-DD"
owners:      [phil, claude-opus-5 (session ...), codex-...]
repos:       [srs-campaign, adept]
machine:     perlmutter | laptop | blackbox
mlflow-experiment: 189035
mlflow-runs:  [c9943d13, 6846ff8d]
slurm-jobs:   [57924140]
tags:        [research/investigation, lpi/srs, lpi/tpd, numerics/blowup, validation/scaling]
translated-from: "[[archive-osiris-srs-1d-ppc-scan-NOTES]]"   # stage-2 notes only
source-sections: ["## Run log", "## Conjectures and refutations"]
trust:       {warpx: untrusted-laser-normalized, osiris: ok}   # where it applies
```

`mlflow-experiment` is the highest-value field in the list: it is the one identifier that
joins vault note ↔ repo config ↔ artifacts on the tracking server, and it is the thing
`simulations.md` is currently maintained by hand to provide.

### 5.2 Bases views to ship with Phase 1

- **Active work** — `status: active`, grouped by `project`, sorted by `updated` desc.
  Replaces "which of my 28 campaigns is live?"
- **Campaigns by engine** — `type: campaign`, grouped by `engine`. Replaces `simulations.md`
  as a *table*; see §5.3 for what it does not replace.
- **Blocked / needs a decision** — `status: blocked`. This does not exist today in any form.
- **Cross-engine comparisons** — filter by a shared `tags` value, e.g. everything tagged
  `lpi/ppc-convergence` across OSIRIS and WarpX. This is the cut the folder tree can never
  give you and the reason engine is a property as well as a folder.
- **Validation** — `tags` contains `validation/*`. The `Campaigns` and `Active work` views
  exclude these by tag, so engine-plumbing work stops competing with physics for attention.
- **Untranslated archive** — `type: archive` with no investigation pointing back at it via
  `translated-from`. This is the stage-2 backlog, and it is the view that keeps lazy
  translation honest rather than indefinite.
- **Trust caveats** — any note with a `trust` key set. Small now (M2 only), but it is the
  view that stops an untrusted number being cited a year from now.
- **Schema hygiene** — notes missing `status`, `project`, or carrying an unknown `type`.
  Property drift is the way this convention decays; make it visible from day one.

### 5.3 Maps of Content (MOC), for what a query cannot express

A Base sorts; it does not argue. `srs-campaign/simulations.md` is currently doing both,
and the argumentative half — *this campaign supersedes that one, this pair is the
controlled comparison, this result is the reason the next campaign exists* — should become
a hand-written `srs-campaign MOC` note. One per project. Curated order, prose between the
links.

### 5.4 A `Questions/` folder — the highest-value addition

The organization NOTES.md structurally cannot support: a research question outlives any
one campaign and usually spans engines. `Questions/does-ppc-convergence-differ-between-osiris-and-warpx.md`,
`Questions/what-limits-epw-amplitude-in-lpse2d.md` — each a short note stating the question,
its current best answer, and wikilinks to every investigation bearing on it. This is the
layer between the microscopic vault record and the `research-docs` narrative, and it is
currently missing on both sides. Backlinks make it self-maintaining.

### 5.5 Tag taxonomy for physics facets

Hierarchical, small, enforced: `lpi/{srs,tpd,cbet,rescatter}`,
`numerics/{blowup,convergence,noise-floor,boundary}`,
`diagnostic/{hot-electrons,phase-space,reflectivity}`, `engine/{osiris,warpx,lpse}`,
`validation/{hardware,scaling,smoke}` (§4.5).
The tag pane then does what neither the folder tree nor `simulations.md` can.

### 5.6 Considered and not recommended

- **Daily notes as the spine.** The plugin is on, but Bases sorted by `updated` gives the
  chronology without a second set of files to maintain.
- **A note per MLflow run.** Duplicates the tracking server; goes stale immediately.
- **Folder-per-status** (`Active/`, `Complete/`). Moving files to change state breaks
  links and Sync history. `status` is a property.

---

## 6. Migration mechanics

A script, `scripts/migrate-notes-to-vault.py`, beside `resolve-shared-vault.py`:

```
migrate-notes-to-vault.py <NOTES.md> --vault <root> --project <p> [--engine <e>]
                          [--dry-run] [--manifest out.json]
```

1. Resolve the vault via the existing `resolve-shared-vault.py`. Never search for it.
2. Parse H2 boundaries. Classify each section **reference** (spec, files, decks,
   provenance, runbook, assumptions) or **log** (dated, `Run N`, results, incidents) by
   heading pattern, and emit the classification into the manifest for review — do not
   trust it silently.
3. Emit hub + archive with frontmatter. Dates from
   `git log --follow --diff-filter=A --format=%aI` (first commit → `started`) and the last
   commit (→ `updated`). Use `/Library/Developer/CommandLineTools/usr/bin/git`; the
   `/usr/bin/git` shim on this laptop exits 72.
4. Check the proposed filename against every existing vault basename before writing.

The script does **stage 1 only** (D2). Its output destinations are
`Notes/srs-campaign/<study>/<study>.md` for the hub and
`Archive/srs-campaign/<study>/archive-<engine>-<campaign>-NOTES.md` for the frozen copy.
Stage-2 translation is not scripted — it is read-the-whole-thing work, done per study, and
automating it would reintroduce exactly the silent-rewrite risk D3 is guarding against.

**Fidelity gate — the acceptance criterion for stage 1.** Every non-blank,
non-heading line of the source must appear byte-identical **exactly once** across the
output set. The script asserts this and refuses to write on failure. With zero links and
zero embeds in the corpus (§1c), this is achievable as a hard equality, not a heuristic —
which is what makes a 1.2 MB automated migration trustworthy.

The gate applies to the **archive** output, which is byte-exact by construction. Hub
material is reviewed by eye, not gated — it is the part a human is expected to rewrite.

**Do not migrate the repo's `_archive/`** (17 files). First verify each is a prefix or subset of its
`srs-campaign` counterpart, then leave the tombstones alone.

**Import in batches** — roughly 88 new files — with Obsidian open on exactly one device,
letting Sync settle between batches. Do not import with all clients running.

---

## 7. Phases

| # | Work | Gate |
|---|---|---|
| 0 | Fix vault nesting (D4). Add `NOTES.md merge=union` to `srs-campaign` (`scripts/enable-notes-merge.sh`) so the repo notebooks stay mergeable until Phase 7 freezes them. | Decisions recorded; all of D1–D4 now settled |
| 1 | Author `Templates/Campaign.md`; extend `Investigation.md` frontmatter to the §5.1 schema (incl. `translated-from`, `trust`, `executions`); write the Bases, including `Validation` and the archive exclusion; rewrite the vault `README.md` layout + status vocabulary. | A hub hand-written for one study reads well in Obsidian |
| 2 | **Stage-1 import, piloted on four notebooks** — `srs-Ln-Te-I-scan2` (worst case, 2,088 lines, 34 dated sections), `srs-2d-testbed` (live, ~1,160), `srs-Ln100-Te4-1d` (small, 103), and one M1 member so a multi-notebook hub is exercised from the start. | Fidelity gate passes byte-exactly on all four; hubs read better than the originals |
| 3 | **Stage-1 bulk**: remaining 23 notebooks → 13 hubs + 5 validation stubs + 27 archives per §4.3–4.6. | Fidelity gate on all 27; every hub lists its retired repo paths in `executions`; M2's three trust mechanisms present |
| 4 | **Stage-2 translation of M1 (`srs-1d-ppc-scan`) and M3 (`srs-Ln-Te-I-scan2`) only** (D2): the two studies where a correction supersedes numbers held in another source notebook. Everything else translates lazily, when next worked on. | Each translated investigation carries `translated-from`; no claim in a hub that cannot be walked back to an archive |
| 5 | Campaign index: `srs-campaign/simulations.md` (28 rows) → a `Campaigns` Base plus a hand-written `srs-campaign MOC` (§5.3). `domain-knowledge/` **stays in git**. | Every hub reachable from the MOC; no campaign row lost against the 27 notebooks |
| 6 | Flip the convention: rewrite `research-notes/SKILL.md` (remove pilot framing; the vault is the destination and the repo keeps no parallel record); replace `shared-vault-pilot.md` with a vault protocol doc; add the stage-2 translation protocol; update `srs-campaign/CLAUDE.md` (the recording discipline and epistemic-boundary examples live there) and `srs-campaign/sims/README.md`. | An agent following only the new docs produces a correct record |
| 7 | Freeze repo notebooks: replace each `NOTES.md` body with a stub naming its vault hub; stop appending. Keep the files so `git log` still resolves and an agent opening a campaign directory is pointed at the hub. | Every retired notebook names its hub; no post-freeze append |
| — | *Deferred:* `kinetic-srs` (15), `lagradept-apps` (1), `adept-light-coupling` (1) stay on the repo convention until `srs-campaign` has settled. | — |

Phases 0–2 are the real work. Phase 3 is mechanical once the gate holds. Phase 4 is the
only judgement-heavy step and is deliberately scoped to two studies.

---

## 8. Risks

- **Loss of "the notes are next to the config"** — now the only repo-side concern, and the
  one that survives D1. Today an agent opening `sims/warpx/srs-1d-ch-boundaries/` finds the
  record without being told. After the transition it must resolve the vault first. Mitigate:
  the frozen stub names the hub, and the skill resolves the vault before the first research
  write. Watch for it during the Phase 2 pilot — this is a discoverability question, not a
  reachability one, so it is answered by whether agents actually follow the pointer.
- **Single point of failure.** With no repo-side record, the vault is the only copy of new
  research narrative, held by Obsidian Sync. Confirm Sync version history is on, and that
  the vault is included in whatever laptop backup exists, before Phase 7 freezes anything.
- **Sync conflict during bulk import.** Batches, one client.
- **Property drift.** The schema-hygiene Base from day one.
- **Stage-2 translation never happens.** The likeliest failure of this plan: verbatim
  archives are cheap and land in a week, translation is expensive and lands never, and the
  vault ends up half-consistent — which is worse than either end state, because a reader
  cannot tell which studies were translated. Mitigations: the *Untranslated archive* Base
  makes the backlog visible; Phase 4 does M1 and M3 up front so the pattern exists to copy;
  and lazy translation is tied to touching a study, so the ones that matter get done.
- **Translation loses something.** Accepted and insured against rather than prevented —
  that is the whole point of keeping the verbatim copy. `translated-from` plus
  `source-sections` is what makes the diff possible; without both, the insurance is
  unusable.
- **Campaign notes silently becoming logs again.** The hub is editable in place, so there
  is nothing structural stopping an agent from appending a run to it. State the rule in
  the template header: *material events go in an investigation note, never here.*
- **Scope creep into `research-docs`.** The vault README already draws this line; §5.4's
  `Questions/` folder sits deliberately on the vault side of it. Keeping `domain-knowledge/`
  in git defers the harder half of this boundary rather than settling it — expect it back
  the first time a synthesis doc needs to cite a vault note.

---

## 9. Decisions and what is left

All five original decisions are settled:

| | Decision | Outcome (2026-09-08) |
|---|---|---|
| Scope | which repos | `srs-campaign` only; others deferred |
| Folders | engine level | dropped; hub per **study**, not per execution |
| D1 | repo-side record | none — the vault is canonical |
| D2 | backfill | verbatim into `Archive/` first, translate to investigations second |
| D3 | granularity | stage 1 mechanical at H2; stage 2 by judgement, archive-backed |
| D4 | nested vaults | exclude `Ergodic Research` from the outer vault |
| — | `domain-knowledge/` | stays in git, out of scope |
| M1 | `srs-1d-ppc-scan` | merge all 4 |
| M2 | 2d-follett | merge all 3, untrusted numbers marked three ways (§4.3) |
| M3 | `srs-Ln-Te-I-scan2` | narrow — scan2 + `lpse-srs-scan-test` |
| M4 | Ln100-Te4 | merge all 4 |
| §4.5 | engine validation | tagged investigations, no hub, no folder |
| §4.1 | hub naming | established name of the dominant member; `<study>.md` inside `<study>/` |

**Nothing blocks Phase 0.** Three things want a look but only at the phase that needs them:

1. **`Archive/` at the vault root vs. per study folder** (§4.1) — I picked root for clean
   exclusion; a one-line change if you'd rather it sat beside each hub. Decide before
   Phase 2 writes the first file.
2. **What an "episode" is when translating** (D3) — worth settling by example rather than
   by rule. Phase 4 translates M1 and M3; look at the result before the lazy translations
   start following it.
3. **Whether frozen archives eventually get deleted** once their study is fully translated
   and the diff checked, or kept permanently. No need to decide now — but if the answer is
   "kept permanently", the root `Archive/` choice in (1) matters more.

---

## 10. Execution record (2026-09-08)

What was done, in phase order, and where it departed from the sections above.

| # | Done | Departure from the plan |
|---|---|---|
| 0 | `.gitattributes` union merge added to `srs-campaign` (committed `2dfa380`). D4 was already in place: the outer vault's `app.json` excluded `Ergodic Research/`. | none |
| 1 | `Templates/Campaign.md`; `Templates/Investigation.md` extended; six `.base` files in a new `Bases/` folder; vault `README.md` rewritten. | Bases live in `Bases/`, not the vault root. `Archive/` is **not** added to the vault's excluded files: it is unknown whether Bases honour that exclusion, and the `Archive backlog` Base must see the archives — so exclusion from search/graph is left as a one-click user setting documented in the README, and every Base filters on `file.inFolder("Notes")` instead. |
| 2 | Pilot import of four studies (11 archives, 4 hubs); fidelity gate PASS. | Pilot by study rather than by notebook, because merged hubs need all their members at once. |
| 3 | Bulk import: 27 archives (byte-exact, independently `cmp`-verified), 13 hubs, 5 validation stubs; no basename collisions. The existing blowup investigation note got `campaign: "[[srs-2d-testbed]]"`. | Property schema flattened for Obsidian's property UI and Bases: §4.7's `executions` list-of-maps became `repo-paths` + `mlflow-experiments` + `mlflow-experiment-ids` + `archives` lists plus an *Executions* table in the hub body; `trust` is a list of strings, not a map; `engines` (list) replaces `engine` everywhere. Added `translated` / `translated-to` / `translated-on` on archives (the `Archive backlog` Base keys on `translated`, not on backlinks) and `reviewed: false` + `migrated` on every generated hub and stub. Every index row of `simulations.md` was carried into its hub's *Status → From the campaign index* block. |
| 4 | M1 translated into 7 investigations, M3 into 12 (9 OSIRIS, 3 LPSE); the six archives flagged `translated: true`; the two hubs point at their investigations. | Translated notes are named `YYYY-MM-DD-migrated-<subject>-<uuid8>` (episode start date, no invented time of day, no agent slug); checkpoint IDs `YYYYMMDD-migrated-<uuid8>-<nn>` with a **Source** line per block. `translated-from` may be a list (several archives feed one episode). |
| 5 | `Notes/srs-campaign/srs-campaign MOC.md` (every hub and validation note reachable; the two index rows without a notebook recorded); `Bases/Campaigns` is the table. `simulations.md` stub is part of the Phase 7 freeze. | none |
| 6 | `SKILL.md` rewritten (vault canonical; NOTES.md rules kept only for unmigrated repos); `shared-vault-pilot.md` deleted, `vault-protocol.md` added (includes the stage-2 translation protocol); `srs-campaign/CLAUDE.md` and `sims/README.md` updated (committed `2dfa380`). | none |
| 7 | `freeze-repo-notebooks.py` dry-run (27 stubs + `simulations.md` stub planned, 0 refused; it refuses any notebook whose bytes differ from its archive), then applied by the user after confirming the §8 gate. Before the commit every HEAD notebook was re-verified byte-identical to its archive (27/27). Committed `b9242af`, pushed to `main` and `lpse/srs-2d-testbed`. | none |

Tooling location: the migration script, the freeze script and the study map were moved
out of this skill into `srs-campaign/utils/vault-migration/` the same day (USER: one-time,
srs-campaign-specific, unlikely to serve another repository). Its README records the
known limits — fixed engine order, one notebook per directory, H2-only sectioning,
srs-tuned classifier vocabulary, literal index stub — so nobody reuses it unmodified. The
skill keeps only `resolve-shared-vault.py` and `enable-notes-merge.sh`.

Gates as measured: fidelity 27/27 byte-exact; wikilinks and heading anchors across the
vault checked by script after Phase 5; every hub carries its retired repo paths in
`repo-paths`; M2's three trust mechanisms present (property, two verbatim banners, a
per-execution warning on each WarpX reference block — the per-row `†` rule applies to
comparison tables, which the stage-1 hub does not yet contain).

Left open, as §9 said: `Archive/` at the vault root (kept); what an episode is (settled
by the 19 examples in the two translated studies — one question to a result, several
dated sections each); whether archives are ever deleted (no; `translated: true` marks
them consumed).
