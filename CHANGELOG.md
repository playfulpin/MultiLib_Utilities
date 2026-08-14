# Changelog

All notable changes to the author-toolchain scripts in this repository:
`build_shell_nested_authors.sh` (directory-tree builder),
`build_prefix_table.sh` (prefix-table generator), and
`prefix_tree_visualizer.sh` (tree renderer).

## [utf8_prefix_generator.awk 1.1] - 2026-08-13

- **`utf8_prefix` off-by-one fix.**  The prefix slicer broke at a character's
  lead byte instead of past its continuation bytes, so under a byte locale
  (`LC_ALL=C`) every prefix ending in a multi-byte character was sliced in
  half (e.g. `аб` became `а` plus a stray lead byte).  It now ends on a
  character boundary in both gawk string modes; UTF-8-locale output is
  unchanged (the AWK-parity group is still green).
- **New direct regression suite (`test_utf8_prefix_generator.sh`).**  Unlike
  the parity group — which only compares this script against the newer
  generator, so a bug they share could still pass — this asserts the AWK
  script's own rows: multi-byte / 3-byte / 4-byte prefix slicing, `maxlen`
  capping, space-preserving multi-word authors, `count`/`start`/`end` ranges,
  and byte-locale correctness.
- Suite: **11/11 checks** green under WSL.

## [toolchain] - 2026-08-13

- **Restored `prefix_table_integrity.sh` to the repository root.**  The
  validator (v1.2.1) had been parked in `_Save_Stuff/` and was absent from the
  active tree, so the generator suite's real-data integrity cross-check
  silently skipped.  It is once again a first-class toolchain component, living
  next to the generator whose output it validates.
- **New end-to-end pipeline suite (`test_e2e_pipeline.sh`).**  Chains the three
  stages — `build_prefix_table.sh` → `prefix_table_integrity.sh` →
  `prefix_tree_visualizer.sh` — on the real 6,088-author list.  Asserts the
  generated table is non-empty and in strict byte order, that the validator
  reports 0 criticals and checks exactly the emitted row count, that the
  renderer draws a multi-level tree (the utf8_chop fix), and that a concrete
  prefix's count survives generator → renderer intact.  This locks out the
  cross-tool format drift no single per-tool suite can see.
- Suite: **11/11 checks** green under WSL on the real author list.

## [prefix_tree_visualizer.sh 2.8.1] - 2026-08-11

First release of the tree renderer, integrated into the toolchain.

- Moves into the release package: `release/prefix_tree_visualizer.sh` (version
  kept in the header comment), the regression suite
  (`release/test_prefix_tree_visualizer.sh`), and its fixtures/goldens under
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

## [build_prefix_table.sh 1.0.4] - 2026-08-11

- **Startup banner**: every successful run prints
  `build_prefix_table.sh v<version> (pre-order trie walker)` to **stderr**
  only — stdout stays byte-identical (it carries the table, often redirected
  straight into `tmp_SORTED_AUTHORS`).  A stale copy is instantly
  recognizable: it prints an older version or no banner at all.
- The regression suite now asserts the banner (version + walker variant) on
  stderr and that it never leaks into stdout.

## [build_prefix_table.sh 1.0.3] - 2026-08-11

- New fixture `case_quotes.txt` + golden `quotes_x5.txt`: punctuation-leading
  names (`"Журнал …"`, `(Максимов)`) sort before all Cyrillic in byte order
  — the exact boundary the historical level-major walker violated (the
  4 byte-order warnings seen on real data).  Regression-locked.

## [build_prefix_table.sh 1.0.2] - 2026-08-11

First release of the prefix-table generator, integrated into the toolchain.

- Moves into the release package: `release/build_prefix_table.sh` (version kept
  in the header comment), the regression suite
  (`release/test_build_prefix_table.sh`), and its fixtures/goldens under
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
  `utf8_prefix_generator.awk` on the same byte-sorted input (checked in the
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

Release of the final, tested state of `build_shell_nested_authors.sh`.  No
functional changes since 6.6.7; the version increment marks the script as
complete and release-ready.

- The `V06` variant is retired; the canonical script is `build_shell_nested_authors.sh`.
- Release package lives in `release/`: the snapshot `build_shell_nested_authors.sh`
  (version kept in the header comment, not the file name), this changelog, and a
  self-contained regression suite (`release/test_build_shell_nested_authors.sh`).
- Full regression suite green: **29/29 checks** against the release snapshot
  (`wsl.exe bash release/test_build_shell_nested_authors.sh`), including a
  release-integrity check that the snapshot is byte-identical to the working script.
- Tagged `v6.6.8`.

## Development & release workflow

The design supports ongoing work on more tools in this repository.  Every
released tool follows the same pattern:

1. **Develop** against the working script at the repository root (e.g.
   `build_prefix_table.sh`); it is the source of truth.
2. **Bump the version** in the header comment by `0.0.1` per iteration (e.g.
   `6.6.8` → `6.6.9` for the tree builder, `1.0.2` → `1.0.3` for the prefix
   table, `2.8.1` → `2.8.2` for the visualizer) and update the `Last updated`
   timestamp.
3. **Refresh the release snapshot**: copy the working script over its twin in
   `release/` (`release/build_shell_nested_authors.sh`,
   `release/build_prefix_table.sh`, `release/prefix_tree_visualizer.sh`).
4. **Validate**: run the release suites
   (`wsl.exe bash release/test_build_shell_nested_authors.sh`,
   `wsl.exe bash release/test_build_prefix_table.sh`, and
   `wsl.exe bash release/test_prefix_tree_visualizer.sh`) — each suite diffs
   its snapshot against the working script (release-integrity check) and runs
   every golden, CLI, and behavioral check against the snapshot.
5. **Commit and tag**: commit the changes, then tag the release
   (`v6.6.9`, or a tag naming the tool's version).

The suites fail loudly when a snapshot drifts from its working script, so a
release can never silently go stale.

## [6.6.7] - 2026-08-11

- `-c/--clean-run=ON` output now leads with `rm -rf <root>` + `mkdir -p <root>` +
  `cd <root>` before the `mkdir -p` tree, so *running the generated script*
  destroys and rebuilds the root (the `rm` precedes the `cd` — after wiping, the
  shell's cwd is a deleted inode).
- New end-to-end test executes the generated clean-run script and verifies the
  rebuilt tree (`д/де`, `В/Ва/Ван`) with stray files gone.

## [6.6.6] - 2026-08-11

- `ROOT_DIRECTORY` is no longer a hardcoded constant.  Resolution order
  (industry standard): `-r/--root-dir=PATH` flag → `ROOT_DIRECTORY` environment
  variable → built-in default (`/mnt/c/Backup_Nova3/Empty_Skeleton`).
- New `-c/--clean-run=ON|OFF` flag (default `OFF`): destroys and rebuilds
  `ROOT_DIRECTORY` before generating, so the emitted commands build a pristine
  hierarchy.
- Safety guard: refuses to clean empty, `/`, `//`, `$HOME`, or anything under
  `$HOME`.

## [6.6.5] - 2026-08-11

- Semver versioning started — the header carries `Version:` + `Last updated`
  (with hours and minutes), incremented in `0.0.1` steps per iteration.
- Version is printed in `-h` help, derived from the header via `SCRIPT_VERSION`
  (single source of truth — no second edit on bump).
- DEBUG output reformatted into aligned columns: `input file` line, per-prefix
  rows (`prefix='…' authors=…`), and `HH:MM:SS (Ns)` elapsed time.  All
  diagnostics go to stderr only; stdout stays byte-identical.
- Test suite asserts the version header follows the `6.6.x` pattern.

## Earlier history (pre-semver, accumulated during development)

- CLI: positional (`input min max`) *and* named options (`-i/-m/-x`, with `=`
  attached, isolated, or spaced forms; `--` ends option parsing; unknown flags
  fail loudly).  Defaults `-m 10 -x 5`.
- `-d/--debugger=ON|OFF` (stderr diagnostics, case-insensitive values) and
  `-f/--format=SHELL|SQL` (SQL renders the tree as `dictionary_nested_set`
  rows with `word`/`lft`/`rgt` nested-set numbering).
- Deterministic `LC_ALL=C` byte-order sort — locale collation interleaves case
  variants (`В`/`в`), which produced duplicate `mkdir` lines and silently
  dropped valid prefixes like `Ван`.
- Space-terminated prefixes (`де `) are word boundaries, never directory
  levels — `д/де`, never `д/де/де `.
- O(N·max_depth) range-based tree walk over the sorted author list (the earlier
  version rescanning the whole list per node scaled superlinearly).
- Regression suite with stored golden files: word boundaries, case variants,
  duplicates, CRLF + blank lines, edge cases, SQL goldens, debug mode, CLI
  forms, root resolution, and clean-run behavior.

---

## Usage

```
./build_shell_nested_authors.sh --input-file=FILE [OPTIONS]
```

| Option | Description | Default |
|---|---|---|
| `-i, --input-file=FILE` | Author names, one per line (required) | — |
| `-m, --min-authors=NUM` | Minimum authors for a prefix to become a directory | 10 |
| `-x, --max-prefix=NUM` | Maximum prefix (tree depth) length | 5 |
| `-d, --debugger=ON\|OFF` | Stderr diagnostics | OFF |
| `-f, --format=TYPE` | Output format: `SHELL` or `SQL` | SHELL |
| `-r, --root-dir=PATH` | Root directory for the hierarchy | `ROOT_DIRECTORY` env var, else built-in |
| `-c, --clean-run=ON\|OFF` | Destroy and rebuild the root before/during generation | OFF |
| `-h, --help` | Show help (exits 1) | — |

The script emits `cd …` + `mkdir -p …` commands (or SQL statements); run the
output through `bash` to build the tree.  Requires a multibyte-capable bash
(e.g. WSL) to slice UTF-8 prefixes correctly.
