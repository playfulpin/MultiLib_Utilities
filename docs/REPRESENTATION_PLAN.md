# Personal library representation plan

**Status:** Design approved; safety net implemented
**Updated:** 2026-09-04 (rev 4 — backup/restore tool shipped)

> **Safety net (implemented):** `bin/backup_privetelib.sh` v1.0.0 — backup /
> restore / verify / list of `privetelib` via mysqldump.  `restore` is safe
> by design (backs up the current state first; refuses to overwrite a
> non-empty library without `--force`).  Mandatory before Phase 1 populates
> anything.

## Goal

Make everything we collect visible and useful inside **MultiLib.exe** — the
existing Windows desktop app that is the end-user interface for this project.
Three concrete needs, all scoped to "myself, on this Windows box, through the
app":

1. **Enrich owned books** — link the ~2,156 books on disk back to their
   catalog rows so the app can show covers, descriptions, ratings and series
   position for what is actually in the personal library.
2. **Collection status view** — see, inside the app's own idiom, collection
   coverage per author/genre, series gaps, and the next to-collect priorities.
3. **Read/search experience** — open and find books already on disk without
   leaving the app. (Confirmed: the user opens books from inside the app.)

## Architecture (confirmed, not hypothetical)

The app models **a library = a MySQL database holding the ml* catalog schema**
and switches between them. The user proved this by creating a third library
through the app itself:

- **`privetelib`** — an empty library DB created in-app with the Flibusta
  plugin, connectable from the app, sitting in the MariaDB datadir with the
  **same 17-table schema as `flibusta`** (`mlbook`, `mlauthorname`,
  `mlcoverpage`, `mldescription`, `mlrating`, `mlseq`/`mlseqname`,
  `mlgenre`/`mlgenrename`, `mlauthor`, `mlnews*`, `mluser*`, `mlactual`,
  `mlcustinfo`, `mldownloaddata`), plus a `privetelib.lib` marker next to
  `flibusta.lib`.
- Nothing in `flibusta` or `mllbr_main` needs to be touched, ever: the
  personal library is a **self-contained sibling DB**. Deleting it = deleting
  one database; rebuilding it = re-running one tool.
- `[MySQL]` in `MultiLib.ini`: `root` / no password / `localhost:3306` — the
  same connection our utilities already use.

The plan: **populate `privetelib` with the personal collection** — full
catalog rows copied from `flibusta` for exactly the books on disk, written in
the shape the app itself writes — then switch the app to it like
Flibusta ↔ Librusec. Enrichment (covers/descriptions/ratings/series) is
inherited because the copied rows carry the same metadata, self-contained in
`privetelib`.

## Ecosystem today (grounded)

| Piece | What it is | Where |
|---|---|---|
| `MultiLib.exe` | closed-source Delphi library app (Russian UI, AlReader2 reader, plugin dir, query bank, OPDS support, Downloads grid) | `C:\MultiLib\` |
| `flibusta` DB (17 tables) | the catalog the app browses (`CurrentLibName=flibusta`); `mlbook` carries per-file columns `filename`/`arcname`/`deleted`/`library` + `pi_*`/`di_*` info | MariaDB datadir |
| `privetelib` DB (17 tables) | **the target library** — app-created, empty, same schema as `flibusta` | MariaDB datadir |
| `mllbr_main` DB (4 tables) | app registry: `mldownload` (per-library download ledger, `(bookid, library)` unique), `mlgroup`/`mlgroupname`, `mlgenrelist` — feeds the app's Downloads grids | MariaDB datadir |
| `plugins/Private/` | the app's personal-library schema template (`init.sql` — `mlbook` w/ `filename`, `arcname`, `md5`) | `C:\MultiLib\plugins\Private\` |
| `plugins/Flibusta/`, `plugins/Librus/` | the two online-catalog plugins; user created `privetelib` through the Flibusta one | `C:\MultiLib\plugins\` |
| `upload/` | downloaded official dumps `flibusta_YYYY-MM-DD/` (the load-a-catalog path) | `C:\MultiLib\upload\` |
| `Books` folder | personal collection: 2,156 real books (2,145 zip-wrapped FB2 + 11 loose fb2; 457 `desktop.ini` noise), prefix tree `Letter/…/Author/Series/Book`; the user sets the app's library/download folder | `C:\Backup_Go7\Books` |
| Derived artifacts | per-author reconcile TSV, to-collect list (5,663), download-size estimate | `C:\Backup_Go7\merge-reports` |

Key facts that shape the plan:

- `MultiLib.ini`: `[MySQL] root@localhost:3306`, `CurrentLibName` = active
  library DB, `[recent]` entries keyed `bookid:library`, `ShowDownloaded` +
  `RGridDl*` = Downloads grid driven by `mldownload`.
- `flibusta.mlbook.filename`/`arcname` are populated by the dump pipeline —
  a filename-driven match seam between disk files and catalog `bookid`s
  (population rate unverified; Phase 0 measures it).
- Author-level name matching is already proven by `reconcile_library.sh`
  (99 of 108 loaded author folders resolve to catalog names).
- md5-exact matching is *not* available: the dump's `lib.md5` content hashes
  are deliberately not loaded (future option).

## What gets populated and how

For every real book on disk (zip-wrapped FB2 + loose fb2; skip `desktop.ini`,
empty dirs):

1. **Resolve its catalog `bookid`** from the flibusta dump tables (match
   ladder, order of strength):
   a. `mlbook.filename` / `arcname` — the dump knows the book's own filename;
   b. author (prefix dirs) → series (parent dir) → normalized title;
   c. report as near/unmatched otherwise.
2. **Copy the full catalog rows into `privetelib`** — `INSERT … SELECT` from
   `flibusta` by resolved `bookid`, covering every table the app browses:
   `mlbook` (+ `filename` pointed at the `Books` location per the app's
   convention), `mlauthor`/`mlauthorname`, `mlseq`/`mlseqname`,
   `mlgenre`/`mlgenrename`, `mlrating`, `mlcoverpage`, `mldescription`,
   `mlactual`, `mluser*` as applicable — so browsing and enrichment are
   self-contained in `privetelib`.
3. **Multi-author books** appear once (canonical row) — dedupe on `bookid`.
4. Write the per-run report (matched / near / unmatched) for review.

Rebuild semantics: `privetelib` is *our* database, so the tool reloads it
from scratch each run (drop tables' contents, reload from `flibusta`) while
the app is not connected to it — simplest correctness, no drift, idempotent
by construction. (Incremental upsert is a later option if rebuilds get slow.)

## Phases

### Phase 0 — Probe (target is our own empty DB — safe by construction)

1. **Schema parity check**: diff `privetelib`'s table columns against
   `flibusta`'s (the app created it; confirm nothing to add/alter — we never
   change the app's schema).
2. **Behavior probe (decisive)**: with the app's current library =
   `privetelib`, the user downloads one known book the way they normally
   would, then opens it. Diff before/after to learn: exact rows the app
   writes (shape of `mlbook` row incl. `filename` value, `mldownloaddata`,
   any `mllbr_main`/ini changes), and where the file lands / under what name
   — pins the **folder & filename convention** we must mirror for disk files.
3. **Open trial**: hand-insert one `mlbook` row for an existing `Books` file
   (filename per the observed convention), user opens it in the app → proves
   the app opens *our* rows and their files. This is the naming-contract
   test; iterate until one file opens.
4. **Match-rate spike (no app)**: sample disk files across authors/series;
   measure `mlbook.filename`/`arcname` population, then ladder (a) vs (b)
   hit rates.

**Exit:** schema parity confirmed, observed write conventions, one disk book
opening in-app from a hand-written row, match-ladder rates.

### Phase 1 — Population tool

New tool `bin/populate_privetelib.sh` (project conventions: versioned header,
config, `--dry-run`/`--debug`, MariaDB lifecycle, tests, CI, docs):
scan `Books` → resolve `bookid`s (ladder) → rebuild `privetelib` from
`flibusta` by resolved ids → per-run TSV report (matched/near/unmatched).

**Acceptance:** app switched to `privetelib` shows the full personal
collection with covers/descriptions/ratings and opens files; re-running is a
no-op rebuild; `flibusta` and `mllbr_main` untouched (verify by diff).

### Phase 2 — Collection status inside the app

A `qry_*` bank turning `privetelib` into status views — canonical in the repo
(`data/sql/`), mirrored to the app's query folder (`C:\MultiLib\queries\`):
coverage per author/genre, series gaps per collected author, next to-collect
priorities (against `flibusta`), reconcile summary lines. Keep the app's
parameterized-query idiom (`SET @…` + `SELECT`).

### Phase 3 — Read/search polish

- Fix any naming drift that blocks opening registered files.
- Search the owned subset through the app's existing search or an added
  `qry_*` on `privetelib`.
- Optional (only if wanted): mirror owned books into `mllbr_main.mldownload`
  (`library='privetelib'`) so the app's Downloads grid shows the collection —
  decided after Phase 0 reveals how much the app writes there itself.

## Risks & rules

- **Never alter the app's schema** — `privetelib` keeps exactly the columns
  the app created; we populate, we don't remodel.
- **App not connected to `privetelib` during rebuilds** (switch to `flibusta`
  or close the app); back up the datadir before first real run (existing
  pattern).
- **Folder & filename convention** must match what the app writes (Phase 0.2)
  or files won't open — the Books tree naming may need adjustment or an
  `mlbook.filename` mapping layer.
- **`mlbook.filename` population rate** measured before relying on ladder (a).
- **Multi-author books** deduped to one canonical row per `bookid`.
- **`desktop.ini` and empty dirs** are scan noise, never registered.
- The app may write rows itself (downloads, `mldownloaddata`) into
  `privetelib` over time — the tool must tolerate and preserve them (or the
  rebuild policy must account for them).

## Out of scope (for now)

- Web / mobile / OPDS export of the personal library (the app has an `[opds]`
  section — future option).
- A new reader application.
- Registering the earlier `Books_01` / `Books_02` / `Books_Initial_Load`
  trees — the plan targets the live `Books` collection; older trees can be
  registered later the same way.
