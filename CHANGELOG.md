# Changelog

All notable changes to the author-toolchain scripts in this repository:
`bin/build_shell_nested_authors.sh` (directory-tree builder),
`bin/build_prefix_table.sh` (prefix-table generator),
`bin/prefix_tree_visualizer.sh` (tree renderer),
`bin/merge_books_into_skeleton.sh`, and
`bin/merge_skeleton_into_books.sh`.

## [Unreleased] - 2026-09-01

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
