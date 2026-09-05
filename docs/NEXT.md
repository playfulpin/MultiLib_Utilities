# NEXT — where to resume

> Updated: 2026-09-04 (late) — privetelib REBUILT with fresh keys (v1.1.0)
> Last commit: `[populate_privetelib]` — Phase 1 population tool v1.1.0 + live rebuild (see git log)

## Resume checklist

```bash
cd /home/mike/GIT_ROOT/MultiLib_Utilities
git status             # expect: clean tree
git log --oneline      # expect: 6dd7342 at the top (main)
git push               # 6dd7342 is NOT yet pushed — push before new work so GitHub is current
bash tests/test_backup_privetelib.sh   # 23/23; suite runs anywhere (mock mysql)
```

If CI on the `6dd7342` push shows a failure, the syntax gate comes first —
run `bash -n bin/*.sh` and `bash tests/test_version_sync.sh` locally before
anything else (see the 31de3bd incident for what happens otherwise).

## Current state

The **representation layer** for the personal library is designed and its
safety net is shipped. The end-user app (`MultiLib.exe`, `C:\MultiLib\`)
models **a library = a MySQL DB with the 17-table ml\* schema** and switches
between them (`CurrentLibName` in `MultiLib.ini`, `[MySQL] root@localhost:3306`
no password). The user proved the model by creating **`privetelib`** in-app
via the Flibusta plugin: an empty sibling library, same schema as `flibusta`,
connectable from the app. Everything downstream is about populating
`privetelib` with the personal collection (the `Books` folder) and never
touching `flibusta` / `mllbr_main`. Full design: `docs/REPRESENTATION_PLAN.md`
(rev 5).

### Shipped: the safety net (`bin/backup_privetelib.sh` v1.0.0, commit `6dd7342`)

Backup / restore / verify / list of `privetelib` via mysqldump — the
mandatory prerequisite before Phase 1 populates anything:

```bash
./bin/backup_privetelib.sh                        # backup -> BACKUP_DIR/privetelib_<ts>.sql.gz
./bin/backup_privetelib.sh list
./bin/backup_privetelib.sh verify <file>.sql.gz
./bin/backup_privetelib.sh restore <file>.sql.gz  # safe: backs up current state first;
                                                  # refuses non-empty overwrite without --force
```

- Backups live in `/mnt/c/Backup_Go7/privetelib-backups/`; the known-good
  artifact is `privetelib_20260904-004417.sql.gz` (post-repair schema).
- Registered in `bump-version.sh` / `tests/test_version_sync.sh` / CI;
  mock-mysql suite `tests/test_backup_privetelib.sh` (23 assertions).
- Verified live 2026-09-04: backup -> verify -> restore round-trip green.

### Phase 0 probe results so far

| Probe | Result |
|---|---|
| App behavior (download) | **Empty `privetelib` cannot download anything** — the app needs catalog rows to offer downloads. Population must come FIRST; the one-book write-convention probe therefore runs after Phase 1, not before (or via `Tools/ImportOldLib.exe` trial). |
| Schema parity | **DONE** — all 9 managed tables column-identical between `flibusta` and `privetelib` (checked 2026-09-04; the tool re-checks per run). |
| **Match-rate spike (Phase 0.4)** | Ladder (a) `mlbook.filename`/`arcname`: **dead** — `filename` transliterated librusec-style, `arcname` 0% populated. Ladder (b) author+series+title: **2075/2156 (96.2%) exact**. **SUPERSEDED by the md5 finding below** — the population tool matched **2148/2156 (99.6%)** with zero fuzzy logic. |
| **md5 finding (2026-09-04)** | `flibusta.mlbook.md5` is **100% populated** (all 869,130 rows) and hashes the **decompressed FB2 content** — `zcat file.zip \| md5sum` (== `unzip -p`) and loose `.fb2` resolve to exactly one bookid. No index on the column (equality scans ~1s); the tool pulls the whole `(md5, bookid)` map once and joins locally. Also: `mlcoverpage`/`mldescription` are EMPTY in the loaded dump (covers/descriptions need the extended-data torrents); real enrichment = ratings 361,761, series, genres, `mlcustinfo` 163,161. |

### Shipped: the population tool (`bin/populate_privetelib.sh` v1.1.1)

Rebuilds `privetelib` from the `Books` collection: hash each file (zip by
decompressed content, loose fb2 directly) -> join the one-shot `(md5, bookid)`
map -> rebuild the 9 managed tables **row-by-row with FRESH keys**: every
`AUTO_INCREMENT` in privetelib generates the id, captured per insert via
`LAST_INSERT_ID()` into session variables (`@bid_<old>`, `@aid_<old>`, …)
that child rows reference — keys are used only after they come into
existence, in a single client session. The v1.0.0 "exact copy"
(`INSERT…SELECT *` carrying flibusta's ids wholesale) is GONE: those foreign
ids broke the app's key bookkeeping (exactly why MultiLib.exe showed catalog
basics but no books). Reference entities are inserted for OUR books only
(distinct authors/genres/series of the resolved bookids); **v1.1.1 fixes the
two app-test findings**: `mlgenrename` pulls each used genre's ancestor
categories (the catalog's 1000001+ tree rows) so the genre tree renders
instead of a flat list, and `mlbook.filename` carries the CATALOG value
(transliterated name the app displays) — `arcname` keeps the on-disk zip
member name, `filesize` the on-disk bytes. `mlrating` copies the per-book
aggregate from `flibusta.mlrating` (the `Flibusta_Load_mlrating.sql`
output). Parity is checked for ALL 9 tables BEFORE any TRUNCATE — a
mismatch aborts, never a partial rebuild. `flibusta` read-only; app-owned
tables never touched. Report TSV per run
(`/mnt/c/Backup_Go7/merge-reports/populate_privetelib_<ts>.tsv`).

```bash
./bin/backup_privetelib.sh                # FIRST: safety backup of current privetelib
./bin/populate_privetelib.sh --dry-run   # walk + resolve + summarize, write nothing
./bin/populate_privetelib.sh             # rebuild (TRUNCATE + fresh-key row-by-row INSERTs)
```

- **Rebuilt live 2026-09-04 (21:09)**: 2156 files -> 2148 matched (99.6%), 8
  unmatched, 2138 bookids registered. privetelib rows AFTER the fresh-key
  rebuild: mlbook **2138** (ids 1..2138), mlauthor 2798, mlgenre 5468,
  mlseq 2619, mlrating 1948 (distribution 1:30, 2:278, 3:874, 4:534,
  5:232), mlcustinfo 757, mlauthorname **187**, mlgenrename **70**,
  mlseqname **422** — i.e. only the entities our books actually use (vs.
  216 491 / 296 / 80 744 in the old exact-copy state). AUTO_INCREMENT
  counters verified at rowcount+1 for all 9 tables.
- **v1.1.1 re-rebuilt live 2026-09-04 (22:22)**: `mlgenrename` 70 ->
  **84** rows (70 genres + 14 ancestor categories, e.g. «Фантастика»
  -> 30 children), `parentgenreid` fully remapped, `mlgenre` joins
  0-dangling; `mlbook.filename` = catalog value verbatim (2138/2138
  non-empty, 0 on-disk paths; ~71% of flibusta filenames are numeric
  bookids — loader fallback — copied faithfully).  Next: re-test in
  MultiLib.exe — genre panel should show «Фантастика» -> «Научная
  фантастика» & co, and book `filename` the catalog's value.
- Suite `tests/test_populate_privetelib.sh` **31/31**; registered in
  bump-version.sh / test_version_sync.sh / CI. Pre-rebuild safety backups:
  `/mnt/c/Backup_Go7/privetelib-backups/privetelib_20260904-210914.sql.gz`
  (the 6 MB v1.0.0 state) and the older empty-state snapshots.
- **The 8 unmatched** are 7 Bушков «Пиранья» volumes + 1 Bulychev
  «Девочка…» — exact-content mismatches (catalog has a different edition/
  normalization of the same book). These are the fallback-tier candidates
  (author/series/title ladder).
- **arcname finding (verified 2026-09-04)**: the zip member names inside the
  Books archives are themselves double-encoded mojibake (`01-╨Я╨╡╤А╨▓╨╛╨╡`
  — UTF-8 decoded as cp866 by whatever tool created the zips). The tool
  stores the member bytes VERBATIM, so the app's zip reader sees exactly the
  name physically in the archive — do NOT "fix" arcname to clean UTF-8 or
  member lookup inside the zip would break. `flibusta.mlbook.arcname` is
  empty, so the source catalog is no help here either.

## Environment quirks (learned 2026-09-04 — remember these)

1. **WSL2 mirrored-networking connect hangs**: a `mysql` connect to
   `127.0.0.1:3306` can block indefinitely instead of failing fast.
   Always use `--connect-timeout` (the backup tool does; ad-hoc commands
   should too). `mysqldump` in MariaDB 10.4 does **not** accept that flag —
   bound with `timeout` (`MYSQL_CALL_TIMEOUT`, default 90s) in the tool.
2. **Wedged server after operations**: after several start/stop cycles the
   `--console` mysqld instance can keep running but stop answering
   (handshake stalls; `SELECT 1` hangs). This is the user's known
   "minimized window, still working" quirk. Fix: `taskkill /F /IM mysqld.exe`,
   then start fresh. After a force-kill, first boot may need
   `MARIA_START_TIMEOUT` well above the 30s default (recovery of the big
   MyISAM catalog) — pass `MARIA_START_TIMEOUT=120` until it's stable.
3. **`privetelib.mlcustinfo.frm` was corrupt** (error 1033 on LOCK TABLES) —
   repaired by `CREATE TABLE privetelib.mlcustinfo LIKE flibusta.mlcustinfo`.
   If the app misbehaves on `privetelib`, this is a candidate cause; the
   backup now makes such repairs safe.
4. Server lifecycle on this box requires WSL2 **elevated** (no UAC prompt).

## Next steps (priority order)

1. **Open-trial (decisive for openability)**: switch MultiLib.exe to
   `privetelib` and try to open one of the registered books (e.g. the
   MeXXanik «Адвокат Чехов» one — privetelib bookid 1,
   `M/MeXXanik Гоблин/Адвокат Чехов/01-Первое дело.zip`). If files don't
   open, the `mlbook.filename` naming convention needs a mapping layer —
   iterate until one file opens. This also validates the populated rows
   in-app (the v1.0.0 rebuild showed catalog basics but NO books; the
   v1.1.0 fresh-key rebuild is the fix — confirm the book list renders).
3. **Behavior probe (post-population)**: user downloads/opens one book in
   `privetelib` in-app; diff datadir before/after to learn the exact rows
   the app writes (`mlbook` shape, `mldownloaddata`) and where files land.
4. **Unmatched fallback (ladder b)**: author/series/title matching for the
   8 unmatched files (and any future misses) — extend the tool's resolve
   step or add a small companion.
5. **Covers/descriptions (future)**: load the extended-data torrents
   (covers/descriptions) into `flibusta`, re-run the populate tool — it
   will copy them automatically (tables are in the managed set when
   populated).
4. **Phase 2 — collection-status query bank**: `qry_*` files in
   `data/sql/` (mirrored to `C:\MultiLib\queries\`) — coverage per
   author/genre, series gaps, next-to-collect priorities, reconcile summary
   rendered from the ledger.
5. **Phase 3** — read/search polish; optional `mldownload` mirror for the
   app's Downloads grid.

## Open notes carried forward

- The spike was ad-hoc scratch (deleted, tree clean) — its ladder logic is
  the blueprint for the Phase 1 matcher; re-derive from the reconcile
  matcher + `docs/REPRESENTATION_PLAN.md` rather than from history.
- `mlbook.filename`/`arcname` are NOT the flibusta archive names — do not
  plan matching around them. The monthly-archive filenames on disk
  (`01-Первое дело.zip`, `0Мироходец.zip`) are series-number + title;
  normalize by stripping `^[0-9]+[ -]*` before comparing to `mlbook.title`.
- The raw dump sources (`lib*.sql.gz`, the 12 tables + `lib.md5.txt.gz`
  checksums) are kept on disk at `data/archives/flibusta_gz/` (git-ignored,
  ~130 MB) for reference / re-loads; they are already ingested into
  `flibusta` by the BookTracker-import pipeline.
- Full database reference: `docs/MultiLib_Flibusta_DB.md` — the 17-table
  ml* schema, the lib* dump schema, ingest/update logic, key findings.
- `docs/` is markdown-only; keep the plan and this file in sync after each
  phase.