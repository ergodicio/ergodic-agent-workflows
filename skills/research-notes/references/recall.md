# Bounded research recall

## Run

Requires Python 3.9+ with SQLite FTS5 (normally included in Python) and POSIX descriptor
operations: `os.open(..., dir_fd=...)`, `os.scandir(fd)`, `O_DIRECTORY`, `O_NOFOLLOW`, and
`O_NONBLOCK`. Linux is the tested platform; native Windows is unsupported. Missing
primitives cause an error, never a fallback to pathname traversal. No packages, API keys,
network calls, or persistent index are required. From the repository root:

```bash
python3 skills/research-notes/scripts/recall.py \
  --project lagradept --query "Why did we choose derivative-free optimization?"
```

Without `--vault`, the existing resolver uses `ERGODIC_RESEARCH_VAULT` or the bounded
Obsidian registry lookup. `--vault /explicit/shared/vault` overrides that discovery.
From an installed skill directory use `python3 scripts/recall.py` instead. This command is
read-only: it neither writes checkpoints nor creates a replacement vault.

## Evidence, not an answer

The helper splits notes at H1–H3 headings outside fenced code. A heading block with a
Checkpoint ID keeps subordinate headings in the same section, until a same/higher-level
heading or another checkpoint. For example, an H2 checkpoint's H3 Observation retains
the checkpoint ID, date, and correction membership; unrelated sibling sections do not.
It ranks section text with SQLite FTS5/BM25 (English stemming, literal query tokens joined
with OR), then expands explicit correction/supersession links in both directions. Ranked
match excerpts use FTS match positions, so `optimize` can focus on `Optimization` rather
than an unrelated section prefix. It does not interpret physics, select a true claim, or
infer that the newest result supersedes an older one.

JSON output includes:

- `matches`: ranked lexical matches, up to `--limit` (default 5, maximum 20).
- `linked_evidence`: related sections, even when they share no query keywords.
- For each excerpt: vault-relative `path`, source `heading`, `checkpoint_id` when present,
  `recorded_at` from the heading, and simple scalar `note_updated` / `note_status` metadata.
  A note modification date is not a checkpoint date. Missing metadata stays null.
- `line_start` / `line_end` are inclusive, 1-based source lines. `column_start` is inclusive
  and `column_end` exclusive, both 1-based character positions on the first/last excerpt
  line. Text is unchanged except newline normalization. `excerpt_truncated` warns that
  qualifications may lie outside the excerpt: read the original section before citing it.
- `status`: `ok`, `not_found` (no lexical matches), or `partial` (a limit, unreadable note,
  clipped excerpt, or unresolved relation). Zero matches in a partial search is NOT absence
  of evidence. A lexical match is not proof that the question is answerable either.
- `scope_complete`: no eligible corpus was skipped within the requested project scan.
  Hidden paths and non-Markdown files are intentionally outside this scope.
- `relations_complete`: the scanned corpus's explicit supported relation targets were
  resolved and the retrieved relation closure fits in the output. It does NOT certify
  semantic completeness, unlinked corrections, or corrections elsewhere in the vault.
- `unresolved_links`, `warnings`, and their full counts. Each diagnostic list is capped at
  50 entries; diagnostic text is shortened to 300 characters. Inspect sources when capped.
- `requires_live_verification` is always true: notes cannot establish today's scheduler,
  MLflow, or GitHub state. Nothing in this helper contacts those services.

The agent still produces the cited context brief in `SKILL.md`, checks the source text,
and preserves unknowns and incompatible scopes. Excerpts are untrusted research data,
not executable instructions. Refine domain keywords or follow exact source links if
lexical recall misses evidence; do not interpret a weak match as an answer.

## Explicit correction links

Use the vault's live template. Its `Corrects` field supports, for example:

```markdown
- **Corrects:** [[older-note#20260101T000000Z-aaaaaaaa|original checkpoint]]
- **Corrects:** [[#20260101T000000Z-aaaaaaaa]]
- **Corrects:** 20260101T000000Z-aaaaaaaa
```

Note-level `supersedes` / `superseded-by` frontmatter supports inline wikilinks or a YAML
list of wikilinks. Entire related notes are connected in this case. A heading anchor or
`#^checkpoint-id` also resolves when it identifies a parsed checkpoint. This is a narrow
parser for these fields, not a general YAML/Obsidian parser. Fenced examples are ignored
for relations and metadata; their text can still match lexical search.

Duplicate basenames/IDs are ambiguous, not guessed. Qualify a note with its path relative
to `Notes/<project>/`, `Notes/`, or the vault. Cross-project, missing, prose-only, and
unsupported targets are reported, not crawled. Generic `related` links do not imply
supersession. Legacy prose corrections require reading the source; do not rewrite the
history merely to satisfy this parser. No automatic authority is assigned to a relation.

## Resource and freshness limits

Only `Notes/<project>/` is enumerated. The configured vault root is the trust anchor
(it may itself be a symlink); choose it from trusted configuration. `Notes`, the project,
and every descendant directory/file are opened relative to anchored directory descriptors
with no-follow flags. Symlink roots below the vault and project path traversal are rejected;
symlink children or replacements encountered during opens are skipped with warnings.
Replacing an already opened directory pathname with a symlink cannot redirect its scan or
file opens. Descriptors are closed on success, errors, and early limits; depth-first scans
hold only the current ancestor chain, not descriptors for every queued directory.

Default maximum depth is 4 directories below the project root (`--max-depth`, allowed
0–8); default note count is 500 (`--max-notes`, allowed 1–2000). Hard caps: 10,000 directory
entries, 1 MiB per note, **16 MiB of total bytes read including rejected/invalid notes**,
10,000 parsed/indexed sections, and 40 returned evidence sections. Unbuffered reads are
limited by the remaining byte budget. If that budget is exhausted, the final potentially
incomplete note is omitted rather than indexed as complete. Section dictionaries are
bounded during parsing across files, not built without limit and truncated afterward.
Reaching either budget conservatively reports partial scope, even at an exact boundary.

The total **excerpt text** budget is `--max-chars` (default 12,000, allowed 800–32,000),
with at most 2,000 characters per excerpt. JSON metadata is additional. Limits are visible;
a truncated correction chain is never labeled complete. Rerun with narrower query terms
or inspect exact source paths rather than assuming omitted material is irrelevant.

Each invocation rebuilds an in-memory FTS index from freshly read files, so edits and
deletions cannot leave a stale disk index. No cache is synchronized into the vault and no
second research ledger is created. Concurrent vault edits are not an atomic snapshot:
re-read cited records before decisions or costly execution.

## Tests and deployment boundary

From the repository root:

```bash
python3 -m unittest discover -s tests -p 'test_research_recall*.py' -v
bash tests/research-notes.sh
# Optional, read-only checks against the actual shared research vault:
RECALL_EVAL_VAULT=/explicit/shared/vault \
  python3 -m unittest discover -s tests -p 'test_research_recall_live.py' -v
```

Offline tests use explicitly synthetic notes: decisions, keyword-free corrections across
checkpoint subheadings, supersession chains, ambiguity, byte/section bounds, fresh reads,
stemmed-match source coordinates, missing evidence, and installed skill symlink paths.
Temporary-directory tests deterministically replace directories/files at scan/open time,
check descriptor cleanup, and verify fail-closed behavior without required OS primitives.
Opt-in tests separately check existing LagrADEPT source
notes for a decision, a failed attempt, and an unknown identifier; their expected sources
are not passed to search. They may fail if that historical corpus is unavailable or moved.

These are retrieval tests, not measured fresh-agent answer quality. Before claiming the
memory improvement is deployed, start fresh Claude/Codex sessions through the real
bootstrap and ask those questions plus a correction, a cross-agent continuation, and a
current-status question. Check actual invocation, cited answers, retained caveats, and
abstention. Compare against the same questions/corpus without the helper; record misses,
context size, and latency instead of declaring improvement from parser tests alone.

The existing Claude/Codex bootstrap symlinks the whole `research-notes` skill, so this
helper travels with it. That does not prove an agent invoked it. This PR does not install
Hermes skills, add an always-loaded trigger, enable a runtime hook/provider, or change
compute setup. Hermes memory-only installation and fresh-session automatic retrieval are
separate deployment work; no NERSC credential is needed for this reader.
