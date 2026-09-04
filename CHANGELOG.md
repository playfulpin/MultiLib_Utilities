# Changelog

All notable changes to the author-toolchain scripts in this repository:
`bin/build_shell_nested_authors.sh` (directory-tree builder),
`bin/build_prefix_table.sh` (prefix-table generator),
`bin/prefix_tree_visualizer.sh` (tree renderer),
`bin/merge_books_into_skeleton.sh`, and
`bin/merge_skeleton_into_books.sh`.

## [Unreleased]

- **New `bin/estimate_download_size.sh` v1.0.0 — catalog download-size
  estimate for the next collecting round.**  Given a to-collect author list
  (one canonical name per line — e.g. the reconcile shopping-list export
  `reconcile_to_collect_<ts>.txt`, or the recommended-author fixture
  `data/fixtures/authors_list_from_db.txt`), it sums the REAL per-book
  sizes the catalog stores (`mlbook.filesize`) and reports two
  **distinct-book totals** — a co-authored book counts once even when
  several list authors wrote it, so the totals are the honest "how much
  will I download" figures: the **qualifying** subset (Russian books
  rated 4/5 in the `Фантастика` genre family, the list's own criteria:
  40,535 books / ~61 GB for the 5,663-author round) and the **full
  oeuvre** (all Russian books by those authors: 234,388 books / ~432 GB).
  List names are resolved to catalog authorids via an `mlauthorname` dump
  with the same trailing-whitespace normalization the exporter applies
  (5,663/5,663 matched; unmatched names are counted and reported), and
  the aggregates restrict with the resulting integer IN-list — fast, and
  no SQL-escaping of names ever happens.  Every run also writes a
  per-author breakdown TSV next to the summary
  (`estimate_download_size_<ts>.tsv`, columns
  `author|qualifying_books|qualifying_bytes|5rated_books|avg_rating|full_books|full_bytes`)
  sorted **top-rated first** (5-rated qualifying books desc, then
  qualifying count desc) with the top 10 printed in the summary
  (Шекли, Брэдбери, Саймак, Азимов, Лем...), so the round can be
  prioritized author by author; per-author rows attribute co-authored
  books to each author, so their sums exceed the distinct-book totals by
  exactly the multi-author overlap.  The MariaDB lifecycle and `MYSQL_*`
  client settings are shared via `lib/mariadb_lifecycle.sh` (auto-start
  when down, graceful stop on exit when this script started it;
  `--dry-run` never starts or stops the server and writes no breakdown
  file).  Config `config/estimate_download_size.conf` (flag > env >
  config > default); registered in the version-sync machinery and CI.
  New mock-mysql suite `tests/test_estimate_download_size.sh` (runs
  anywhere, 21/21 checks): argv/password contract, all five query shapes
  dispatched by stdin, name→authorid resolution into the IN-list,
  unmatched-author count, summary totals, top-rated-first breakdown
  content, dry-run / failure / missing-input handling, and the lifecycle
  mocks.  **Correction vs the earlier ad-hoc estimate:** the previously
  reported ~181 GB / ~562 GB figures matched no correct query — they came
  from a scratch join whose byte sums were wrong and which counted
  co-authored books once per author; the verified numbers are ~61 GB
  qualifying / ~432 GB full (distinct books).
- **`bin/reconcile_library.sh` v1.0.2 → 1.0.3 — beyond-books review export.
  In DB mode every run now also writes `reconcile_beyond_books_<ts>.tsv`
  next to the TSV report: every on-disk file attributed to a beyond-list
  author (the `orphan-known` / `orphan-unknown` rows) as
  `author<TAB>relative-path`, sorted by author then path — the per-file
  content behind the summary's `books (beyond list authors)` figure, so
  the user can review whether those 961 books should stay.  Requires DB
  mode (per-file attribution comes from the catalog name set); `--no-db`
  logs a warning, `--dry-run` logs would-write without creating the file.
  Book-less folders whose name is not on the list (structural prefix dirs
  that happen to match a catalog name, or folders left with only
  desktop.ini) are no longer counted as authors at all — in-scope empty
  folders still report as `empty` — so `authors (beyond list)` now equals
  the export's author count and always holds books (64 -> 55 on the real
  library; 961 books unchanged).  Suite grown to 23/23 checks (export
  content, collected-author exclusion, book-less folder suppression).
- **`bin/reconcile_library.sh` v1.0.1 → 1.0.2 — next-round shopping list.
  Every run now also exports the `reconcile_to_collect_<ts>.txt` artifact
  next to the TSV report: every recommended author with no books on disk
  yet — the `missing` rows plus `empty`-folder rows (`authors (remaining
  to collect)` now counts both, so an author with an empty folder is still
  to collect; identical numbers while no empty folders exist) — one
  canonical name per line in byte order, the same shape as the author-list
  fixture, ready to feed the merge pipeline for the next collecting round.
  `--dry-run` logs would-write without creating it.  Suite grown to 20/20
  checks (export content + byte order asserted).
- **`bin/reconcile_library.sh` v1.0.0 → 1.0.1 — statistics rebuilt around
  the personal-catalog model.**  The tool is a **collection-progress** report,
  not a completeness audit: the scope file is the recommended-author list
  (highly rated authors in the chosen genre, the user's shopping list) and
  the library root is where the user keeps the books collected so far.
  "Not yet collected" is therefore the normal, expected state of most of the
  list — not a defect — and on-disk content that is not on the current list
  is the user's own pick, not an orphan to flag.  The summary now reads as
  collection progress against the recommended list, in the user's own
  shape: author counts first (`authors (from list)` with its % of the
  list, `authors (beyond list)` with its % of all loaded authors, the
  `listed / unlisted author ratio` = listed share of all loaded, `authors
  (remaining to collect)`), then the books (`books on disk`;
  `books (from listed authors)` / `books (beyond list authors)` each with
  its % of books on disk; the `listed / unlisted books ratio`), and
  `empty (folder, no books)` last.  Units and percentage bases are
  explicit on every line — list coverage vs composition of the loaded set
  vs share of books on disk — so the 44 loaded list authors (holding
  1,195 books) can never be read as a book count against the 2,156 books
  on disk.  The known/unknown-to-catalog split of beyond-list authors
  stays in the per-row TSV.  `collected` counts distinct
  list authors, so a case-variant disk folder of a list author (which the
  report marks matched under both spellings) is not double-counted and the
  headline partition stays exact: collected + still-to-collect + empty ==
  scope.  The report's machine statuses
  and TSV shape are unchanged.  Also fixes the on-disk file-count readout,
  which assumed a header row the headerless report does not have and so
  silently dropped the first author's files from the total every run; the
  suite now asserts the progress summary (no-db and db variants, 18/18
  checks green).
- **New `bin/reconcile_library.sh` v1.0.0 — catalog vs library reconciliation
  report.**  Compares the on-disk book library (default
  `/mnt/c/Backup_Go7/Books`) against the catalog author scope the merge
  pipeline was built from (default
  `data/fixtures/authors_list_from_db.txt`) and classifies every author:
  `matched` (in scope + on disk), `missing` (in scope, no folder),
  `empty` (folder present, zero files), `orphan-known` / `orphan-unknown`
  (on disk but outside the scope).  The disk walk handles BOTH library
  layouts the pipeline produces — the flat `<letter>/<author>[/series]`
  and the nested skeleton `<letter>/<prefix>/.../<author>[/series]` — by
  recognizing author folders **by name** (a folder is an author folder iff
  its basename matches a known author name from scope ∪ catalog) at any
  depth, attributing every file to its nearest ancestor author folder, so
  structural prefix dirs are never mistaken for authors and authors nested
  under prefixes are found (verified against the real `Books` root:
  `А/Аб/Абр/Абра/Абрамов Александр` at depth 5).  With the catalog
  reachable (default) it pulls the `mlauthorname.FullName` snapshot so
  each row carries the catalog book count next to the on-disk file count;
  `--no-db` skips the pull and assumes the flat layout (without the name
  set a nested skeleton cannot be told from series dirs).  desktop.ini
  never counts as a book file.  Read-only against the library; output is
  a summary plus one per-run TSV report in the report dir (default
  `/mnt/c/Backup_Go7/merge-reports`).  Config `config/reconcile_library.conf`
  (flag > env > config > default); registered in the version-sync
  machinery and CI (mock-mysql suite, runs anywhere).
- **Shared `lib/mariadb_lifecycle.sh` v1.0.0.**  The MariaDB lifecycle
  (tasklist interop check, elevated PowerShell start, bounded readiness
  probe, graceful SHUTDOWN / taskkill stop, already-running servers left
  untouched) is extracted from `bin/export_authors_from_db.sh` into a
  shared library sourced by every DB tool; the exporter now sources it
  (`bin/export_authors_from_db.sh` v1.0.1 → 1.0.2, behavior unchanged).
  The shared library also owns the `MYSQL_*` client defaults (host/port/
  user/db over TCP), fixing DB-mode in the new recon tool, whose own
  defaults previously left it probing the local socket instead of the
  Windows-side server.
- **CI: bump `actions/checkout` v4 -> v5.**  GitHub is deprecating
  Node.js 20, which forced the v4 action onto Node.js 24 with an
  annotation warning; v5 runs on a supported runtime and silences it.

## [v1.2.0] - 2026-09-03

**DB-driven author-list release.**  New `bin/export_authors_from_db.sh`
regenerates the flat author fixture straight from the MariaDB catalog by
running a query file, and manages the MariaDB lifecycle itself — auto-start
when down, graceful stop on exit, already-running servers left untouched —
so no manual server handling is needed.  The working fixture is now a
genre-scoped list (5,707 Фантастика authors, 2026-09-03) and stays fully
regenerable; the previous 6,088-name snapshot traced back to a
single-genre legacy query, now annotated for provenance.  All 9 suites
(190 checks) green under WSL.

- **The author list is now DB-driven.**  New `bin/export_authors_from_db.sh`
  v1.0.0 regenerates `data/fixtures/authors_list_from_db.txt` straight from
  the MariaDB catalog by running a query file (default
  `data/sql/qry_authors_4_and_5_all.sql`, a new committed query selecting
  authors with at least one book rated 4/5 and enough books overall).
  Connection settings reuse the BookTracker-import `MYSQL_*` contract
  (defaults `mysql` / `127.0.0.1` / `3306` / `root` / empty / `flibusta`;
  password via `MYSQL_PWD` only).  The session charset is pinned with
  `SET NAMES utf8` via `--init-command`, because the server ignores the
  client handshake charset (`skip-character-set-client-handshake`) and would
  otherwise transcode results to cp1251.  Rows are normalized (BOM/CRLF,
  trailing whitespace, blank lines, literal `NULL` rows) before the atomic
  write; `--dry-run` counts without writing; `-o -` streams to stdout.
  Registered in the version-sync machinery (header = README table row =
  RELEASE_NOTES shipped line = bump-version registry).
- **Fixture refreshed from the live catalog**: 6,088 -> 13,396 authors
  (2026-09-03 query run).  The old snapshot was produced by the
  genre-restricted `data/sql/qry_authors_4_and_5_love_hard.sql` (books in
  the single `Порно` genre rated 4/5, no book-count thresholds) and an
  untrimmed CONCAT; that query is now annotated for provenance and
  superseded by `qry_authors_4_and_5_all.sql` (all genres, `TotalCount
  >= 10` / `NormalCount > 6`).  Membership diff (whitespace-trimmed):
  6,069 of the 6,089 old unique names are kept, 20 genuinely dropped,
  ~7,327 genuinely added; ~3,150 of the raw "losses" were just
  trailing-space artifacts of the old CONCAT.  All toolchain suites green
  on the new list.
- **Working fixture is now genre-scoped (5,707 authors).**  On 2026-09-03
  the fixture was re-generated from the corrected
  `data/sql/qry_Фантастика_4-and-5.sql` (authors of the Фантастика genre
  family rated 4/5, `TotalCount >= 10` / `NormalCount > 6`).  The
  originally committed query was an Access-export artifact (square-bracket
  `[Books]` syntax, tables absent from `flibusta`, book rows instead of
  author names) and is replaced by a faithful `ml*`-schema translation of
  its intent (`ParentCode = "0.17"` -> every genre whose `parentgenreid`
  is the root `Фантастика`); the Access original stays in git history.
  The list remains regenerable at any time via `bin/export_authors_from_db.sh`
  (which now auto-starts/stops MariaDB).
- **Prefix-table roots grow 24 -> 33 first characters.**  Regenerated
  from the new fixture, `bin/build_prefix_table.sh` emits 17,670 rows
  (old list: 10,151, matching the historical record) with no root present
  only in the old list.  New root classes, verified with real authors:
  digit `1` ("100 Рожева Татьяна"), Latin `H Q d e l p` ("Harvard
  Business Review (HBR)", "Qrasik", "de Budyon Michael A.",
  "estimata", "linnea", "pavel_7_8"), lowercase Cyrillic `б к ф`
  ("бен-Маймон Моше", "клевчук", "фон Беренготт Лючия"), and CJK
  `我` ("我吃西红柿 .").  Existing roots grow too (Ё 1->3, Й 5->14,
  Э 71->172); Ъ/Ы/Ь remain impossible initials (0 in both lists).
- **MariaDB lifecycle in the exporter (`bin/export_authors_from_db.sh`
  v1.0.0 → 1.0.1).**  The tool no longer requires a manually started
  server: mirroring `bin/booktracker-ingest.sh` from BookTracker-import, it
  checks `mysqld.exe` via the Windows `tasklist` interop and, when the
  server is down, starts it with an elevated PowerShell `Start-Process`,
  waits up to `MARIA_START_TIMEOUT` for it to answer, and stops it again on
  exit with a graceful `SHUTDOWN` (taskkill fallback) — but only when it
  was this script that started it; a server that was already running is
  left untouched.  `--dry-run` never starts or stops the server (it logs
  would-start / would-stop).  When the `tasklist` interop is unavailable
  (e.g. plain Linux CI) lifecycle management degrades to connect-directly.
  New env vars with BookTracker-import defaults: `MARIA_TASKLIST`,
  `MARIA_TASKKILL`, `MARIA_EXE`, `MARIA_BIN_DIR`, `MARIA_START_TIMEOUT`,
  `MARIA_READY_TIMEOUT`, `MARIA_STOP_TIMEOUT`.
- **New mock suite `tests/test_export_authors_from_db.sh` grown to 18
  checks (runs anywhere, no DB needed)**: asserts the connection argv
  (password never on the command line, `SET NAMES` init-command), row
  normalization, NULL-row drop, dry-run/stderr/stdout modes, failure
  handling, and — via a mock `tasklist` + mock `powershell.exe` — the
  MariaDB lifecycle: already-running server left untouched, full
  start → ready → graceful-stop cycle, no-tasklist management disable,
  and dry-run reporting only.  CI runs it.
- **Byte-order detector fix in two suites.**  `byte_order_violations()` used
  a bare gawk `>=`, which coerces numeric-looking prefixes ("100", "100 ")
  to numbers and both false-flagged valid tables and could mask real
  violations.  The comparisons are forced back to bytes with a `""`
  concatenation; a numeric-prefix regression check was added to the prefix
  suite's invariants.  Exposed by the refreshed list (author
  "100 Рожева Татьяна"); `LC_ALL=C sort -c` and the integrity checker both
  confirm the generator output was always correctly byte-ordered.

## [v1.1.0] - 2026-09-03

**Library-catalog refactor release.**  The merge pipeline no longer depends
on an on-disk `Empty_Skeleton` tree: `bin/merge_books_into_skeleton.sh`
builds the author-prefix hierarchy in memory and writes straight into a
timestamped, pruned `BooksInput_<ts>` staging tree, and
`bin/merge_skeleton_into_books.sh` finalizes it with rsync (destination
wins, live `pv -l` progress bar).  Also ships the GitHub Actions CI +
version-automation workflow; the merge suites now run on the Linux CI
runner.  Suites green under WSL and CI.

- **Refactor branch `refactor/update-library-catalog`: the merge pipeline no
  longer uses the `Empty_Skeleton` folder.**  `bin/build_shell_nested_authors.sh`
  remains for `mkdir -p` scripts and the SQL nested-set table, but the book
  merge builds the prefix tree **in memory** from the flat author list and
  writes straight into a timestamped, pruned staging tree
  `<output-root>/BooksInput_<timestamp>` — only directories that receive a
  copied file are created, so the prune pass is gone by construction.

- **`bin/merge_books_into_skeleton.sh` v0.1.3 → 0.2.0** (with
  `lib/merge_books_functions.sh` 0.1.3 → 0.2.0).  The on-disk skeleton scan
  (`merge_collect_skeleton_dirs`) is replaced by `merge_build_prefix_index`:
  the same `LC_ALL=C` byte-sort + contiguous-range walk as the builder
  (SQL-mode semantics — every valid prefix, not just the deepest, because
  resolution needs ancestors too), with apostrophe→caret path substitution
  matching the old emitted directories.  The clean break drops `--skeleton`
  entirely; new flags `-i/--input-file` (required), `-o/--output-root`,
  `--timestamp`, `-m/--min-authors`, `-x/--max-prefix`; config gains
  `MERGE_INPUT_FILE`, `MERGE_OUTPUT_DIR`, `MERGE_MIN_AUTHORS`,
  `MERGE_MAX_PREFIX`.  An existing staging name is not an error: it is
  treated like the old persistent skeleton (duplicate/overwrite policy
  applies), so incremental re-runs work.  Ambiguity can no longer arise from
  a hand-built skeleton (each prefix has exactly one path); the code path is
  kept defensively.  Suite rewritten for the in-memory mode: **44/44 checks**
  green under WSL.

- **`bin/merge_skeleton_into_books.sh` v0.1.3 → 0.2.0.**  The three-step
  rename → prune → copy loop is replaced by a thin, validated **rsync**
  wrapper: `rsync -a --ignore-existing --itemize-changes` onto the Books
  library (destination wins, never overwrites, resumable), with the newest
  `BooksInput_*` auto-discovered under `--output-root`, path-safety guards,
  and a per-file TSV report (`copied` / `would-copy` / `kept-existing` /
  `would-keep`).  `--from-pruned` / `--no-rename` / `--no-prune` are gone;
  the rename/prune steps no longer exist.  Requires rsync on PATH; Windows
  metadata is excluded belt-and-braces.  Suite rewritten for the wrapper:
  **19/19 checks** green under WSL (skips cleanly without rsync).

- **`bin/merge_skeleton_into_books.sh` v0.2.0 → 0.2.1.**  The finalize step
  now shows a **live progress bar** on the terminal (`rsync -av
  --info=progress2`); the per-file itemize lines are captured via rsync's
  `--log-file` instead of stdout, so the TSV report stays exact while the
  screen stays usable.  After a successful merge the library is **pruned of
  empty directories** (`find ... -depth -mindepth 1 -type d -empty -delete`)
  as a safety net for interrupted runs — `--no-prune` / `MERGE_PRUNE_EMPTY_DIRS=false`
  disables it; a dry run only reports the count.

- **`bin/merge_skeleton_into_books.sh` v0.2.1 → 0.2.2.**  The live progress
  bar now pipes rsync's itemize listing through `pv -s <total-bytes>`
  (total from `du -sb` of the staging tree) with stdout discarded; when
  `pv` is not installed the run falls back to rsync's native
  `--info=progress2`.  The `--log-file` capture is unchanged, so the TSV
  report stays exact.  CI now installs pv (and rsync) so the merge suite
  exercises the pv path on GitHub.

- **`bin/merge_skeleton_into_books.sh` v0.2.2 → 0.2.3.**  The progress bar
  switches from `pv -s <bytes>` to `pv -l -s <item-count>` for an accurate
  percentage: pv counts listing lines (one per transferred file AND one
  per transferred directory, since rsync -a lists both), so the count is
  `find ... \( -type f -o -type d \) | wc -l`; a grep filter strips
  rsync's header/blank/summary lines before pv so the bar lands at exactly
  100%.  The `--log-file` capture and the `--info=progress2` fallback are
  unchanged.

- **First real finalize run (`BooksInput_20260903-140717` → `Books_01`).**
  Ran `bin/merge_skeleton_into_books.sh --target /mnt/c/Backup_Go7/Books_01
  --report-dir /mnt/c/Backup_Go7/merge-reports` against the newest staging
  tree (157 files, ~0.09 GB).  Result: **copied 0, kept-existing 157** —
  `Books_01` already contained every staged file (it was populated at the
  same time the staging tree was created), so `--ignore-existing` skipped
  everything; 0 empty dirs pruned; staging retained; report at
  `merge-reports/merge_skeleton_into_books_20260903-151230.tsv`.

- **Docs:** `docs/BOOK_LIBRARY_MERGE_PLAN.md` rewritten for the two-step
  pipeline (in-memory merge → rsync finalize); README tool sections, testing
  table, CI blurb, and repository layout updated; RELEASE_NOTES shipped
  tools and merge-tool prose updated.  Stale `bin/merge_skeleton_into_books.sh.bak`
  and `.01.bak` files removed.

- **New development workflow: GitHub Actions CI + version automation.**
  - `.github/workflows/ci.yml` runs on every push/PR: shell syntax check
    across `bin/*.sh` and `lib/*.awk`, the new version-sync suite, all three
    merge/finalize suites, and all five UTF-8 suites (Linux bash is
    multibyte-capable, so the WSL-only constraint no longer blocks CI).  A
    broken suite is now caught on day one instead of rotting unnoticed —
    which is exactly what happened to two suites after the layout refactor.
    The runner now installs `gawk` before the syntax step, since GitHub's
    `ubuntu-latest` image ships `mawk` but not `gawk`, and the awk lint
    (`gawk --lint`) previously failed the job in seconds with
    `gawk: command not found`.
  - **Tracked `lib/utf8_prefix_generator.awk`:** the broad `*utf8*`
    gitignore rule was silently excluding the AWK prefix-generator from the
    repository, so CI checkouts had no `lib/*.awk` at all — the syntax-check
    glob collapsed to the literal `lib/*.awk` and `gawk` died with "cannot
    open source file". The tool is now negated in `.gitignore` and tracked,
    and the syntax loop skips globs that match nothing (`[[ -f ]] ||
    continue`), so a future empty directory degrades to a clean pass instead
    of a cryptic `gawk` fatal.
  - **Fixed the two remaining suites broken by the layout refactor:**
    `tests/test_build_prefix_table.sh` and
    `tests/test_prefix_tree_visualizer.sh` still resolved fixtures via
    `TESTS_DIR="$SCRIPT_DIR/tests"` (pointing at `tests/tests/`) and the
    prefix-table suite read its version header from `$SCRIPT_DIR/$s`
    (`tests/bin/…`).  Both now resolve from `tests/` + `bin/` correctly,
    making all eight suites runnable again.
  - **Test-isolation fix in `tests/test_merge_skeleton_into_books.sh`:** the
    `cli_no_args` case ran the script with no flags, letting it inherit the
    real machine's config defaults — a stray `Empty_Skeleton` under
    `/mnt/c/Backup_Go7` once made it exit 0 and run a real finalize.  The
    case now injects guaranteed-missing `MERGE_SOURCE_DIR`/`MERGE_TARGET_DIR`/
    `MERGE_REPORT_DIR` so it must fail validation regardless of machine state.

- **New `bin/bump-version.sh` (v1.0.0).**  Bump one tool in a single command:
  header comment, lib twin (merge_books_into_skeleton), README release-table
  row (version + tag), and RELEASE_NOTES shipped-tools line — with shape
  validation and refusal of non-increases.  Historical mentions in the docs
  are left untouched; the new `tests/test_version_sync.sh` (7/7 green)
  verifies all tracked locations agree, so version drift becomes a test
  failure instead of a silent doc bug.

## [v1.0.0] - 2026-09-01

**First production release** of the author toolchain.  This tag marks the
whole repository as production-ready: the prefix-table generator, validator,
renderer, the nested directory-tree builder, and the book-library merge +
finalize tools, with their suites green under WSL.

- **`bin/build_shell_nested_authors.sh` v6.6.10 — apostrophes in directory
  names.**  Author names may contain an apostrophe (e.g. `О'Брайен`), which
  the prefix walker turned into a directory component ending in a quote
  (`mkdir -p О/О'`).  The SHELL output now substitutes a caret for every
  apostrophe (`mkdir -p О/О^`), keeping emitted paths clean and safe to
  copy-paste.  The SQL output is unchanged: it keeps the raw prefix and
  escapes single quotes for the SQL literal.  Both `mkdir` emission sites
  (max-depth and leaf) are covered; the substitution is a pure parameter
  expansion, so no subprocess is forked per row.
  - New fixture `tests/case_apostrophe.txt` plus SHELL and SQL goldens
    (`apostrophe_m6_x5.txt`, `apostrophe_m6_x5_sql.txt`) lock the behavior
    in; the SHELL golden asserts `mkdir -p О/О^`, the SQL golden keeps
    `('О/О''', …)`.
  - **Latent test-suite fixes from the layout refactor.**  The suite had
    been unrunnable since `1e75fbe` moved it into `tests/` and the tools
    into `bin/`: its `SCRIPT_DIR` path logic still assumed it lived at the
    repository root, and the sandbox/copy scratch names kept the `bin/`
    prefix (`copy_bin/…` instead of `copy_build_shell_nested_authors.sh`).
    Both are fixed (paths now resolve one level up via `../`, scratch
    names are basenames), the stray `tests/tests/` directory is removed,
    and the suite is green again under WSL: **30/30 checks** (was 28/28
    pre-refactor + 2 new apostrophe cases).

## [Unreleased] - 2026-08-31

- **Rename the backup root from `Backup_Nova3` to `Backup_Go7`** across the
  whole project: default directories, config files, usage examples,
  documentation (`README.md`, `RELEASE_NOTES.md`, `docs/BOOK_LIBRARY_MERGE_PLAN.md`),
  and the nested-authors suite's root-dir substitution.  The old name no
  longer appears in any tracked file.  Version bumps per the 0.0.1 rule:
  `bin/build_shell_nested_authors.sh` 6.6.8 → **6.6.9**,
  `bin/merge_books_into_skeleton.sh` 0.1.2 → **0.1.3**, and
  `bin/merge_skeleton_into_books.sh` 0.1.2 → **0.1.3**.

- **`bin/merge_skeleton_into_books.sh` v0.1.2.**  Finalize tool hardening and
  cleanup:
  - `set -euo pipefail` restored (it was disabled during debugging) so a failed
    `mv`, `cp`, or `find` aborts the run instead of silently continuing a
    half-finished merge.
  - The trailing report line is now an explicit `if` — a missing report can no
    longer flip the script's exit code.
  - `parse_arguments` simplified: uniform `--flag VALUE` and `--flag=VALUE`
    forms; the fragile `-s = DIR` and positional-argument forms are dropped
    (positional arguments now fail with a clear error).
  - Config and README examples aligned on `TARGET_DIR=/mnt/c/Backup_Go7/Books`
    (the docs previously showed a stray `/mnt/o/Books`).
  - Docs: version references bumped to 0.1.2, stray code fences removed from
    README and RELEASE_NOTES, the finalize config file listed in the repo
    layout, and `HH:MM` restored to the header timestamp.
  - Suite: 27/27 checks green.

- **`bin/merge_skeleton_into_books.sh` v0.1.1.**  Finalize tool improvements:
  - New flag `--from-pruned`: skip rename + prune when the source is already a
    cleared `BooksInput_<timestamp>` folder.
  - Auto-detection: if the source directory name starts with `BooksInput_`,
    rename and prune are skipped automatically (same effect as `--from-pruned`).
  - Default report directory changed to the fixed path
    `/mnt/c/Backup_Go7/merge-reports` so all reports are collected in one place.
  - Clear mode messages (`mode: from-pruned …` / `mode: auto-detected …`).
  - `RENAME` default now declared with the other configuration variables
    (avoids unbound-variable issues under `set -u`).
  - Suite `tests/test_merge_skeleton_into_books.sh` expanded and adjusted:
    dry-run, full run, `--no-rename`, `--from-pruned`, auto-detection,
    CLI, and version header.

## [Unreleased] - 2026-08-30

- **New finalize tool `bin/merge_skeleton_into_books.sh` (v0.1.0).**  Turns a
  populated author-prefix skeleton into the Books library in three safe steps:
  rename the skeleton to a timestamped staging folder `BooksInput_<ts>`,
  remove every empty directory inside it, then copy the remaining content into
  `Books` without ever overwriting an existing folder or file (the
  destination wins).  The staging folder is retained intact; only empty
  subdirectories are pruned.  `--dry-run` reports the three steps without
  changing anything.  Suite `tests/test_merge_skeleton_into_books.sh`:
  21/21 checks green (dry run, full run, no-rename, CLI, version).

- **Merge tool v0.1.2.**  Destination layout fixed to give each author its
  own folder under the deepest matching prefix, and Windows metadata is
  never copied:
  - **Author folder under the prefix.**  `Абби Линн/Magic The Gathering/…`
    now lands at `А/Аб/Абби Линн/…` instead of directly under `А/Аб/…`,
    so authors that share a prefix never mix their books.  When the matched
    skeleton path already is the author's own folder (from a prior run) the
    author is not appended twice.
  - **Skip list.**  `desktop.ini` and `Thumbs.db` (case-insensitive, any
    depth) are never copied and are reported as `skipped` with reason
    `Windows metadata file (skip list)`.  The list is configurable via
    `MERGE_SKIP_NAMES` (config or environment).
  - Config file documents the new key; suite grown to 45/45 checks.

- **Merge tool v0.1.1.**  `bin/merge_books_into_skeleton.sh` plus
  `lib/merge_books_functions.sh` copy every top-level author folder of a
  legacy archive into the deepest matching prefix directory of a pre-built
  skeleton, per `docs/BOOK_LIBRARY_MERGE_PLAN.md`:
  - The skeleton is the source of truth: prefixes are matched byte-wise against
    the author name (exact for UTF-8 in Cygwin and WSL bash), the longest
    match wins, and distinct paths sharing it are reported as ambiguous.
  - **Recursive series copy (default).**  Subfolders under an author are book
    series and are copied with their relative layout preserved
    (`Серия/том1.fb2` lands inside the author's prefix directory); empty
    subfolders are never created.  `--no-recursive` restores the direct-files-
    only behavior and records subfolders as skipped.
  - **Overwrite policy.**  Existing destination files are handled per
    `--overwrite never|ask|force` (default `never`): `force` replaces and
    records status `overwritten`, `ask` prompts per file (non-interactive
    runs behave like `never`).  A file copied twice from the same source is
    always skipped as a duplicate.
  - **Config file.**  `config/merge_books.conf` supplies defaults for the
    source, skeleton, report directory, recursion, and overwrite policy;
    every setting resolves flag > environment variable > config file > built-
    in default.  `--dry-run` is intentionally not configurable.
  - Copy-only: the source archive is never modified, and re-runs are
    idempotent (duplicate-name).  Mixed formats (`.fb2`, `.epub`, `.zip`,
    `.txt`, ...) are copied as-is.
  - Six TSV reports are written to `--report-dir`: `merge-manifest.tsv`,
    `unmatched-authors.tsv`, `ambiguous-authors.tsv`, `collisions.tsv`,
    `duplicates.tsv`, and `skipped-files.tsv`.
  - `--dry-run` resolves every author and writes the reports without touching
    the skeleton; run it first and review before a real copy.
  - New suite `tests/test_merge_books_into_skeleton.sh`: 42/42 checks green
    (dry run, full run, duplicate-name, collision, re-run idempotency,
    no-recursive, overwrite force/ask, config/env/flags precedence, ambiguous,
    CLI, version headers).  Unlike the UTF-8-slicing suites, it runs under
    both Cygwin/MSYS bash and WSL.

- Added `docs/BOOK_LIBRARY_MERGE_PLAN.md`, documenting the approved next
  phase: build the author-prefix skeleton, resolve archive authors to the
  deepest valid prefix directory, and safely copy mixed-format books from
  `C:\\Backup_Go7\\ToLoad` without overwriting existing filenames. The first
  implementation will use dry-run reports and will leave multi-author expansion
  out of scope.

- Reorganized the repository into a conventional Bash project layout:
  executable tools under `bin/`, reusable AWK code under `lib/`, regression
  suites under `tests/`, source data and SQL under `data/`, and documentation
  at the repository root.
- Updated script, test, and documentation references for the new paths.
- Kept archived/scratch directories and the pre-existing local cleanup changes
  separate from the active toolchain.

## [release] - 2026-08-13

- **Root-only layout finalized.**  The `release/` snapshot directory was moved
  to the repository root earlier, but the changelog's release workflow and the
  three shell suites still assumed the old snapshot model.  The workflow
  section now documents the root-only layout, and each suite's
  `release_snapshot_matches_working` diff (which compared the script against a
  `release/` copy one level up and would now fail) is replaced by the
  version-header check.
- **Integration path fix.**  `tests/test_build_prefix_table.sh`'s real-data
  integration group pointed `data/fixtures/authors_list_from_db.txt` and
  `bin/prefix_table_integrity.sh` at `$SCRIPT_DIR/../…`; it now points at the
  repository root and runs instead of skipping.
- **Removed a stray empty `1` file** from the repository root.
- **Tagged the release.**  Tool-prefixed tags `build_prefix_table-1.0.4`,
  `prefix_table_integrity-1.2.1`, and `utf8_prefix_generator-1.1` now name each
  tool's released version.
- **Suites green under WSL (96/96 checks):** prefix table 34/34, nested-authors
  28/28, visualizer 12/12, AWK generator 11/11, e2e pipeline 11/11.  (The three
  shell suites each report one fewer check than the historical 35/29/13
  figures — the obsolete release-snapshot diff was removed.)

## [lib/utf8_prefix_generator.awk 1.1] - 2026-08-13

- **`utf8_prefix` off-by-one fix.**  The prefix slicer broke at a character's
  lead byte instead of past its continuation bytes, so under a byte locale
  (`LC_ALL=C`) every prefix ending in a multi-byte character was sliced in
  half (e.g. `аб` became `а` plus a stray lead byte).  It now ends on a
  character boundary in both gawk string modes; UTF-8-locale output is
  unchanged (the AWK-parity group is still green).
- **New direct regression suite (`tests/test_utf8_prefix_generator.sh`).**  Unlike
  the parity group — which only compares this script against the newer
  generator, so a bug they share could still pass — this asserts the AWK
  script's own rows: multi-byte / 3-byte / 4-byte prefix slicing, `maxlen`
  capping, space-preserving multi-word authors, `count`/`start`/`end` ranges,
  and byte-locale correctness.
- Suite: **11/11 checks** green under WSL.

## [toolchain] - 2026-08-13

- **Restored `bin/prefix_table_integrity.sh` to the repository root.**  The
  validator (v1.2.1) had been parked in `_Save_Stuff/` and was absent from the
  active tree, so the generator suite's real-data integrity cross-check
  silently skipped.  It is once again a first-class toolchain component, living
  next to the generator whose output it validates.
- **New end-to-end pipeline suite (`tests/test_e2e_pipeline.sh`).**  Chains the three
  stages — `bin/build_prefix_table.sh` → `bin/prefix_table_integrity.sh` →
  `bin/prefix_tree_visualizer.sh` — on the real 6,088-author list.  Asserts the
  generated table is non-empty and in strict byte order, that the validator
  reports 0 criticals and checks exactly the emitted row count, that the
  renderer draws a multi-level tree (the utf8_chop fix), and that a concrete
  prefix's count survives generator → renderer intact.  This locks out the
  cross-tool format drift no single per-tool suite can see.
- Suite: **11/11 checks** green under WSL on the real author list.

## [bin/prefix_tree_visualizer.sh 2.8.1] - 2026-08-11

First release of the tree renderer, integrated into the toolchain.

- Moves into the release package: `release/bin/prefix_tree_visualizer.sh` (version
  kept in the header comment), the regression suite
  (`release/tests/test_prefix_tree_visualizer.sh`), and its fixtures/goldens under
  `release/tests/` (`viz_mini.txt`, `viz_spaces.txt`).  The working script
  stays at the repository root.
- **utf8_chop fix (2.8)**: the parent-prefix helper returned the reversed tail
  instead of everything except the last character, so every child was attached
  to a nonexistent parent and the tree never descended below the roots (e.g.
  `"Журн` hung under nothing, `WA` wrongly under `A`).  Fixed to iterate the
  characters in order.
- Version scheme converted to the shared 0.0.1 ladder: header carries
  `Version:` + `Last updated:`, usage prints `v2.8.1`, and the suite asserts
  the `2.8.x` pattern.
- Suite: **13/13 checks** — golden renders (full, Cyrillic filter, depth 2),
  descent regression for the utf8_chop fix (punctuation and Cyrillic branches
  reach their leaves), filter isolation, depth truncation, CLI usage errors,
  plus a release-integrity check that the snapshot is byte-identical to the
  working script.

## [bin/build_prefix_table.sh 1.0.4] - 2026-08-11

- **Startup banner**: every successful run prints
  `bin/build_prefix_table.sh v<version> (pre-order trie walker)` to **stderr**
  only — stdout stays byte-identical (it carries the table, often redirected
  straight into `tmp_SORTED_AUTHORS`).  A stale copy is instantly
  recognizable: it prints an older version or no banner at all.
- The regression suite now asserts the banner (version + walker variant) on
  stderr and that it never leaks into stdout.

## [bin/build_prefix_table.sh 1.0.3] - 2026-08-11

- New fixture `case_quotes.txt` + golden `quotes_x5.txt`: punctuation-leading
  names (`"Журнал …"`, `(Максимов)`) sort before all Cyrillic in byte order
  — the exact boundary the historical level-major walker violated (the
  4 byte-order warnings seen on real data).  Regression-locked.

## [bin/build_prefix_table.sh 1.0.2] - 2026-08-11

First release of the prefix-table generator, integrated into the toolchain.

- Moves into the release package: `release/bin/build_prefix_table.sh` (version kept
  in the header comment), the regression suite
  (`release/tests/test_build_prefix_table.sh`), and its fixtures/goldens under
  `release/tests/`.  The working script stays at the repository root.
- Generates the toolchain's prefix table (`tmp_SORTED_AUTHORS` format
  `prefix<TAB>count<TAB>start<TAB>end`) with the same core logic as the tree
  builder: normalize → `LC_ALL=C` byte sort → sorted-range prefix-tree walk.
- **Byte-ordered by construction**: the walk emits rows in pre-order of the
  prefix trie, which *is* lexicographic byte order.  The historical table
  (AWK hash-order dump from a locale-sorted list) carried 6,483 byte-order
  warnings in the integrity checker; the generator's output has zero.  Verified
  on the real 6,088-author list: 0 critical, 0 byte-order violations.
- **AWK parity**: emits identical rows to the original
  `lib/utf8_prefix_generator.awk` on the same byte-sorted input (checked in the
  suite).
- **Normalization**: CRLF endings, blank lines, and a leading UTF-8 BOM are
  stripped before sorting; all three yield byte-identical output.
- Per-prefix counts verified against the historical table: 10,151 rows, 10,151
  shared prefixes, zero count mismatches.
- Suite: **32/32 checks** — golden files, structural invariants (byte order,
  `count == end - start + 1`, unique prefixes, valid ranges), AWK parity,
  CRLF/BOM handling, CLI forms and error paths, real-data integration, plus a
  release-integrity check that the snapshot is byte-identical to the working
  script.

## [6.6.8] - 2026-08-11

Release of the final, tested state of `bin/build_shell_nested_authors.sh`.  No
functional changes since 6.6.7; the version increment marks the script as
complete and release-ready.

- The `V06` variant is retired; the canonical script is `bin/build_shell_nested_authors.sh`.
- Release package lives in `release/`: the snapshot `bin/build_shell_nested_authors.sh`
  (version kept in the header comment, not the file name), this changelog, and a
  self-contained regression suite (`release/tests/test_build_shell_nested_authors.sh`).
- Full regression suite green: **29/29 checks** against the release snapshot
  (`wsl.exe bash release/tests/test_build_shell_nested_authors.sh`), including a
  release-integrity check that the snapshot is byte-identical to the working script.
- Tagged `v6.6.8`.

## Development & release workflow

The design supports ongoing work on more tools in this repository.  Every
released tool follows the same pattern:

1. **Develop** against the working script at the repository root (e.g.
   `bin/build_prefix_table.sh`); it is both the source of truth and the released
   artifact — there is no separate `release/` snapshot.
2. **Bump the version** in the header comment by `0.0.1` per iteration (e.g.
   `6.6.8` → `6.6.9` for the tree builder, `1.0.3` → `1.0.4` for the prefix
   table, `2.8.1` → `2.8.2` for the visualizer) and update the `Last updated`
   timestamp.
3. **Run the relevant test suite(s)** under WSL.
4. **Commit** with a clear message and **tag** with the tool-prefixed name.
