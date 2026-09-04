# Author Toolchain — current milestone

A Bash + AWK toolchain that turns a flat author list into UTF-8-safe,
byte-ordered prefix structures: a prefix table, its integrity check, a rendered
prefix tree, and a nested directory hierarchy — all validated against a real
6,088-author dataset.  It also provides safe tools for merging a legacy book
archive into an author-prefix skeleton and finalizing that skeleton into the
Books library.

## Shipped tools

- `bin/build_shell_nested_authors.sh` **6.6.10** — nested directory-tree builder (`mkdir -p` / SQL; apostrophes become `^` in SHELL output)
- `bin/build_prefix_table.sh` **1.0.4** — pre-order trie prefix-table generator
- `bin/prefix_table_integrity.sh` **1.2.1** — ultra-strict table validator
- `bin/prefix_tree_visualizer.sh` **2.8.1** — Unicode tree renderer
- `lib/utf8_prefix_generator.awk` **1.1** — original AWK generator (parity reference)
- `bin/merge_books_into_skeleton.sh` **0.2.0** — merge a legacy archive into an in-memory author-prefix hierarchy (pruned, timestamped `BooksInput_<ts>` staging; no on-disk skeleton)
- `bin/merge_skeleton_into_books.sh` **0.2.3** — finalize a `BooksInput_*` staging tree into the Books library with rsync (destination wins, live `pv -l` item-count progress bar with `--info=progress2` fallback, empty-dir prune after merge)
- `bin/export_authors_from_db.sh` **1.0.2** — regenerate the flat author list (`data/fixtures/authors_list_from_db.txt`) straight from the MariaDB catalog by running a query file (default `data/sql/qry_authors_4_and_5_all.sql`); uses the same `MYSQL_*` connection contract as BookTracker-import, and mirrors its MariaDB lifecycle (auto-start a stopped server via elevated PowerShell, graceful SHUTDOWN on exit, already-running servers left untouched) — the lifecycle now lives in the shared `lib/mariadb_lifecycle.sh`
- `bin/reconcile_library.sh` **1.0.3** — personal-catalog collection-progress report: the scope file (`data/fixtures/authors_list_from_db.txt`) is the recommended-author list, and the library root (default `/mnt/c/Backup_Go7/Books`) is where the user collects those authors' books; the report counts how much of the list is collected (`collected` / remaining-to-collect / empty) and what extra content sits beyond the list (the user's own picks, known / unknown to the catalog), with catalog book counts (mlauthorname snapshot) vs on-disk file counts, output as a progress summary plus a per-run TSV report — and it exports the next-round shopping list (recommended authors with no books on disk yet) as a byte-ordered `reconcile_to_collect_<ts>.txt` next to the report, plus, in DB mode, the beyond-books review export `reconcile_beyond_books_<ts>.tsv` (every on-disk file attributed to a beyond-list author, `author<TAB>relative-path`, to review whether those books should stay; book-less folders that are not on the list are not counted as authors)
- `bin/estimate_download_size.sh` **1.0.0** — catalog download-size estimate for the next collecting round, BEFORE anything is downloaded: given a to-collect author list (the reconcile shopping-list export or the recommended-author fixture), it resolves the names to catalog authorids via an mlauthorname dump (same whitespace normalization as the exporter, so exported lists match 1:1) and sums the real per-book sizes (`mlbook.filesize`) as DISTINCT-book totals — the honest download figures: the qualifying subset (Russian books rated 4/5 in the `Фантастика` genre family, 40,535 books / ~61 GB for the 5,663-author round) and the full oeuvre (all Russian books by those authors, 234,388 books / ~432 GB); every run writes a per-author breakdown TSV sorted top-rated first (5-rated qualifying books desc, then qualifying count desc) with the top 10 printed in the summary, so the round can be prioritized author by author (per-author rows attribute co-authored books to each author, so their sums exceed the distinct totals by the multi-author overlap); shares the MariaDB lifecycle via `lib/mariadb_lifecycle.sh`
- `bin/backup_privetelib.sh` **1.0.0** — backup / restore of the app-registered personal library DB (`privetelib`, the sibling library the MultiLib desktop app created with the same 17-table ml* schema as `flibusta`); the safety net that must exist BEFORE anything is populated into it: `backup` mysqldumps the DB into a timestamped, integrity-checked `.sql.gz` under `BACKUP_DIR` (optional `BACKUP_KEEP` retention), `restore` is safe by design (backs up the current state first, refuses to overwrite a non-empty library without `--force`), plus `verify` (gzip + dump sanity) and `list`; shares the MariaDB lifecycle via `lib/mariadb_lifecycle.sh`, password via `MYSQL_PWD` only

## Highlights

- Deterministic `LC_ALL=C` byte-order output — zero byte-order violations on real data.
- Multi-byte prefix-slicing fixes (`utf8_chop`, `utf8_prefix`) so trees descend through every level under byte locales.
- New end-to-end pipeline suite locks out cross-tool format drift.
- Root-only layout finalized — the `release/` snapshot model is retired; the root script is the released artifact.
- Tool-prefixed release tags: `build_prefix_table-1.0.4`, `prefix_table_integrity-1.2.1`, `utf8_prefix_generator-1.1` (plus the earlier `v6.6.8`, `v2.8.1`).

### Book-library merge tools

- **`merge_books_into_skeleton.sh` (0.2.0)**  
  Builds the author prefix tree **in memory** from a flat author list (the
  same range-walk algorithm as `bin/build_shell_nested_authors.sh` —
  `MERGE_MIN_AUTHORS` pruning, `MERGE_MAX_PREFIX` cap), then copies every
  top-level author folder from the legacy archive into the deepest valid
  prefix.  Output lands directly in a timestamped, **pruned** staging tree
  `<output-root>/BooksInput_<timestamp>` — the `Empty_Skeleton` folder is
  gone: it is neither built nor consumed.  Supports recursive series copy,
  configurable overwrite policy, skip-list for Windows metadata, dry-run
  reports, and config-file / environment overrides.

- **`merge_skeleton_into_books.sh` (0.2.0)**  
  Replaces the rename → prune → copy loop with a thin, validated **rsync**
  wrapper: `rsync -a --ignore-existing` onto the Books library (destination
  wins, never overwrites), with auto-discovery of the newest `BooksInput_*`
  folder, path-safety guards, and a per-file TSV report (`copied` /
  `would-copy` / `kept-existing` / `would-keep`).

## Testing

- **CI (GitHub Actions):** every push/PR runs shell syntax checks, the
  version-sync suite, and all ten test suites on `ubuntu-latest`.
- Prefix-table family: green under WSL (prefix table, nested-authors,
  visualizer, AWK generator, e2e pipeline) and in CI on Linux bash.
- Merge tools: the merge suite slices UTF-8 prefixes, so it runs under WSL
  (byte-based Git Bash mangles Cyrillic); the finalize suite needs rsync and
  real POSIX paths (WSL/Linux — MSYS rsync cannot sync Windows-drive paths),
  and skips cleanly when either is absent.
  - `test_merge_books_into_skeleton.sh` — in-memory prefix build, pruned
    staging output, dry-run, overwrite policies, config/env precedence, etc.
  - `test_merge_skeleton_into_books.sh` — rsync dry-run and full run,
    keep-existing conflicts, auto-detection, CLI, version header.
- `test_version_sync.sh` — every tool's version identical across header,
  lib twin, README table, and RELEASE_NOTES; backed by `bin/bump-version.sh`
  which edits all locations in one command.
