# Personal library representation plan

**Status:** Draft — design only, nothing implemented
**Updated:** 2026-09-03

## Goal

Make everything we collect visible and useful inside **MultiLib.exe** — the
existing Windows desktop app that is the end-user interface for this project.
Three concrete needs, all scoped to "myself, on this Windows box, through the
app":

1. **Enrich owned books** — link the ~2,156 books on disk back to their
   catalog rows so the app can show covers, descriptions, ratings and series
   position for what is actually in the personal library.
2. **Collection status view** — see, inside the app's own idiom, collection
   coverage per author/genre, series gaps, and the next to-collect priorities
   (the data today lives in TSV reports nobody opens).
3. **Read/search experience** — open and find books already on disk without
   leaving the app.

## Ecosystem today (grounded)

| Piece | What it is | Where |
|---|---|---|
| `MultiLib.exe` | closed-source Delphi library app (Russian UI, AlReader2 reader, plugin dir, query bank) | `C:\MultiLib\` |
| `flibusta` DB (ml*) | 869,130-book catalog: `mlauthorname` (names + Total/Normal counts), `mlbook` (title, filesize, lang), `mlseq`/`mlseqname` (series), `mlgenre`/`mlgenrename`, `mlrating` (361,761), `mlcoverpage`, `mldescription` | MariaDB data dir |
| `mllbr_main` DB | the app's own state: `mldownload` registry, `mlgroup`/`mlgroupname`, `mlgenrelist` | MariaDB data dir |
| `Books` folder | personal collection: 2,156 real books (2,145 zip-wrapped FB2 + 11 loose fb2; 457 `desktop.ini` noise to ignore), prefix tree `Letter/…/Author/Series/Book` | `C:\Backup_Go7\Books` |
| Derived artifacts | per-author reconcile TSV, to-collect list (5,663 names), download-size estimate w/ top-rated split | `C:\Backup_Go7\merge-reports` |
| `dictionary_nested_set` | the author-prefix tree the app renders from | MariaDB `flibusta` |

Key facts that shape the plan:

- `MultiLib.ini` → `CurrentLibName=flibusta`: the app browses the **catalog
  DB**, not the disk folder. "My books on disk" and "the catalog" are two
  worlds that are **not linked today** (no bookid recorded for disk files).
- `mllbr_main.mldownload` is the app's own per-library registry:
  `(bookid, library)` unique, carrying title, FullName, seqname,
  genrenamerus, filesize, lang, ext and a `dl_done` flag. This table is the
  designed bridge: a row here is how the app represents "I own/downloaded
  catalog book X in library Y".
- Author-level name matching is already proven by `reconcile_library.sh`
  (the 108 loaded author folders resolve to catalog names). Book-level
  matching is unproven — that is Phase 0.

## Core idea

Register the personal `Books` collection into the app's own ledger
(`mldownload`, one row per disk book, a dedicated `library` tag), with each
row's `bookid` resolved from the disk path:

```
disk path  ──►  author (prefix folders) + series (parent folder)
                    + title (filename minus series-number prefix)
                        │
                        ▼
              flibusta ml*  ──►  bookid
                        │
                        ▼
        mllbr_main.mldownload (library='Books', dl_done='1')
                        │
                        ▼
        app shows covers / descriptions / ratings / series
        for owned books + a real "collection" status
```

Once bookids are registered, the app's catalog browsing, its cover/description
lookups and its own query bank all work against the personal collection for
free — because the enrichment is inherited from the catalog join.

## Phases

### Phase 0 — Feasibility & behavior probe (no writes to real data)

Answers that decide the rest; each is cheap and reversible.

1. **Match-rate spike.** Take a sample of disk books (all formats), resolve
   author → candidate `bookid`s → series → normalized title, and measure
   exact/near/failed match rates. Feeds a decision: title-exact vs
   fuzzy/normalized matching in Phase 1.
2. **`library` semantics.** Have the app itself download one catalog book
   into a scratch collection and diff the row it writes (`dl_position`,
   `dl_done`, `dl_msg`, whether `library` holds a path or a label). This tells
   us the safe shape of rows *we* insert.
3. **Safety rules.** Confirm: app closed during writes, datadir backup first,
   scratch-library test writes, then a real insert on a copy of `mllbr_main`
   before the live table.

**Exit:** match-rate table + written conventions for Phase 1 + green light.

### Phase 1 — Registration & enrichment tool

New tool `bin/register_collection.sh` (project conventions: versioned header,
config, `--dry-run`/`--debug`, MariaDB lifecycle, tests, CI, docs):

1. Scan `Books` (skip `desktop.ini`; `.zip` + `.fb2`), normalize CRLF names.
2. Resolve each file to a `bookid` via the Phase-0 matching strategy.
3. Upsert `mldownload` rows for `library='Books'` (idempotent: re-runs only
   add new/changed books).
4. Write a per-run TSV report: matched / near-match / unmatched, with reasons
   — the unmatched list doubles as the "these disk books are not in the
   catalog" review artifact.

**Acceptance:** app (started after the run) shows enriched metadata for owned
books; re-running the tool changes nothing.

### Phase 2 — Collection status inside the app

The app ships a query bank (`C:\MultiLib\queries\`). Add a set of
`qry_*` files (same style as the existing ones) that turn the registered
collection into status views:

- coverage per author/genre (owned vs recommended list vs catalog),
- series gaps per collected author (`mlseq` position missing from `Books`),
- next to-collect priorities joined with ratings and sizes (the estimator's
  top-rated split),
- reconcile summary lines rendered from the ledger instead of TSV files.

Keep the app's parameterized-query idiom (`SET @…` + `SELECT`) so each query
is copy-paste runnable in the app.

**Acceptance:** collection status readable in the app with two clicks; no
extra runtime.

### Phase 3 — Read/search polish

- Confirm the app opens zip-wrapped FB2 from the `Books` tree (AlReader2 path)
  once rows are registered; fix any naming convention drift that blocks it.
- Wire search of the *owned* subset (author/title/series) through the app's
  existing search or an added `qry_*` that filters `mldownload`.

## Risks & rules

- **Closed-source app.** Every assumption about `mldownload` semantics is
  inferred from the schema and observable behavior — hence Phase 0's probe.
  Never write while the app is running; always back up the datadir first
  (existing pattern from the ingest pipeline).
- **`dl_position` / `dl_done` / `dl_msg`** must mirror what the app writes, or
  the app may mis-render the row — copied from the probe, not guessed.
- **Multi-author books** appear under every author folder (by design of the
  collection). `(bookid, library)` is unique, so a book owned once must not be
  registered twice — resolution order decides the canonical row.
- **`desktop.ini` and empty dirs** are scan noise, never registered.

## Out of scope (for now)

- Web / mobile / OPDS representation — deliberately deferred; the ask is "in
  the app".
- A new reader application.
- Registering the earlier `Books_01` / `Books_02` / `Books_Initial_Load`
  trees — the plan targets the live `Books` collection; older trees can be
  registered later the same way if wanted.
