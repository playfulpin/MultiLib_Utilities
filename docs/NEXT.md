# NEXT — where to resume

> Updated: 2026-09-04
> Last commit: `6dd7342 feat(backup): add privetelib backup/restore tool before any population`

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
(rev 4).

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
| Schema parity | `privetelib` = same 17 tables as `flibusta`, all empty (confirmed via row counts + `.frm` listing). |
| **Match-rate spike (Phase 0.4, done 2026-09-04)** | Ladder (a) `mlbook.filename`/`arcname`: **dead** — `filename` holds transliterated librusec-style names (`Aarh_Andrej_Aida`, 100% populated), `arcname` is 0% populated. Ladder (b) author+series+title: **2075/2156 files (96.2%) exact**, 37 near (multi-volume suffix, e.g. "…Том N" collapsing to one bookid), 39 author-matched-but-title-miss, 5 unrecoverable (genre folders `Эротика/…`, pure-number filename). Match chain reused `reconcile_library.sh`'s matcher (author folder = exact/ASCII-casefold `mlauthorname.FullName`, nearest-author ancestor). |

Remaining Phase 0 refinements (cheap, deferred): count **distinct bookids**
in the exact tier, quantify unambiguous-vs-multiple candidates, and test
better title normalization for the 39 T4 files (strip `Том N`/`Книга N`
suffixes, unify `'`/`«»`/`…` punctuation) — likely recovers most of them.

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

1. **Push `6dd7342`** to `origin/main`; confirm CI green (new suite in the
   workflow; `actions/checkout@v5` already bumped).
2. **Phase 1 — `bin/populate_privetelib.sh`** (design in
   `docs/REPRESENTATION_PLAN.md`): scan `Books`, resolve bookids via the
   spike ladder (author+series+title exact, near-fallback, T4 report),
   rebuild `privetelib` from `flibusta` rows (`INSERT…SELECT` by resolved
   ids: `mlbook` + `filename` pointed at `Books` paths per the app's
   convention, `mlauthor`/`mlauthorname`, `mlseq`/`mlseqname`,
   `mlgenre`/`mlgenrename`, `mlrating`, `mlcoverpage`, `mldescription`,
   `mlactual`, `mluser*`), idempotent rebuild while the app is not connected,
   per-run TSV report. Project conventions: versioned header, config,
   `--dry-run`/`--debug`, MariaDB lifecycle, mock-mysql suite, CI, docs,
   bump registration.
3. **Behavior probe (post-population)**: user downloads/opens one book in
   `privetelib` in-app; diff datadir before/after to learn the exact rows
   the app writes (`mlbook` shape incl. `filename` value, `mldownloaddata`)
   and where files land — pins the folder/filename convention and validates
   the populated rows are openable.
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
- md5-exact matching remains unavailable (the dump's `lib.md5` content
  hashes are deliberately not loaded) — future option, not a dependency.
- `docs/` is markdown-only; keep the plan and this file in sync after each
  phase.