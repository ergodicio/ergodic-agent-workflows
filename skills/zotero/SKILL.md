---
name: zotero
description: Look up papers, references, or PDFs in the user's Zotero library via the Zotero API. Use whenever the user asks to find/look up a paper "in Zotero" or "in the library", references something they've saved, or wants metadata (authors, tags, collection, abstract) for a reference — instead of guessing file paths or grepping the filesystem.
allowed-tools: Bash(curl *)
---

# Zotero

Query Zotero through its HTTP API rather than `find`/`mdfind`-ing blindly through `~/Zotero/storage/` for a filename match. The API returns structured metadata (title, authors, tags, collection, attachment keys) and gets you straight to the right PDF.

## Local API (default — no auth, read-only)

Whenever the Zotero desktop app is running, it exposes a local read-only HTTP API at `http://localhost:23119/api` — no key needed. This is the fast path for lookups.

Search the personal library:
```bash
curl -s "http://localhost:23119/api/users/0/items?q=<query>&qmode=everything&limit=10"
```

Get an item's child attachments (to find its PDF):
```bash
curl -s "http://localhost:23119/api/users/0/items/<itemKey>/children"
```
An attachment's `key` in the response maps to a file at `~/Zotero/storage/<attachmentKey>/<filename>.pdf` — once you have that path, read the PDF directly (e.g. with the Read tool) rather than re-searching the storage tree.

Search a group library (replace `<groupID>` — ask the user if they belong to more than one and it's ambiguous):
```bash
curl -s "http://localhost:23119/api/groups/<groupID>/items?q=<query>&qmode=everything&limit=10"
```

## Web API (writes, or when the desktop app isn't running)

Use `https://api.zotero.org` instead. This requires a Zotero API key — check for `$ZOTERO_API_KEY` in the environment or a key file at `~/.zotero_api_key` before asking the user to generate one at zotero.org/settings/keys.

```bash
curl -s -H "Zotero-API-Key: $(cat ~/.zotero_api_key 2>/dev/null || echo "$ZOTERO_API_KEY")" \
  "https://api.zotero.org/users/<userID>/items?q=<query>"
```

Any write (adding an item, uploading an attachment, editing tags/collections) must go through the Web API — the local API is read-only.

## Guidelines

- Prefer the local API for any read-only lookup — it's faster and needs no credentials.
- Only fall back to filesystem search (`find ~/Zotero/storage -iname "*keyword*"`) if the Zotero app isn't running and no API key is configured.
- Once a PDF's storage path is resolved via the API, read it directly — don't re-search for it.
