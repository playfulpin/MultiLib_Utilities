# Author Toolchain — current milestone

A Bash + AWK toolchain that turns a flat author list into UTF-8-safe,
byte-ordered prefix structures: a prefix table, its integrity check, a rendered
prefix tree, and a nested directory hierarchy — all validated against a real
6,088-author dataset.  It also provides safe tools for merging a legacy book
archive into an author-prefix skeleton and finalizing that skeleton into the
Books library.

## Shipped tools

- `bin/build_shell_nested_authors.sh` **6.6.8** — nested directory-tree builder (`mkdir -p` / SQL)
- `bin/build_prefix_table.sh` **1.0.4** — pre-order trie prefix-table generator
- `bin/prefix_table_integrity.sh` **1.2.1** — ultra-strict table validator
- `bin/prefix_tree_visualizer.sh` **2.8.1** — Unicode tree renderer
- `lib/utf8_prefix_generator.awk` **1.1** — original AWK generator (parity reference)
- `bin/merge_books_into_skeleton.sh` **0.1.2** — safely copy a legacy archive into the skeleton
- `bin/merge_skeleton_into_books.sh` **0.1.2** — finalize the skeleton into the Books library

## Highlights

- Deterministic `LC_ALL=C` byte-order output — zero byte-order violations on real data.
- Multi-byte prefix-slicing fixes (`utf8_chop`, `utf8_prefix`) so trees descend through every level under byte locales.
- New end-to-end pipeline suite locks out cross-tool format drift.
- Root-only layout finalized — the `release/` snapshot model is retired; the root script is the released artifact.
- Tool-prefixed release tags: `build_prefix_table-1.0.4`, `prefix_table_integrity-1.2.1`, `utf8_prefix_generator-1.1` (plus the earlier `v6.6.8`, `v2.8.1`).

### Book-library merge tools

- **`merge_books_into_skeleton.sh` (0.1.2)**  
  Copies every top-level author folder from a legacy archive into the deepest
  matching prefix of a pre-built skeleton.  Supports recursive series copy,
  configurable overwrite policy, skip-list for Windows metadata, dry-run
  reports, and config-file / environment overrides.

- **`merge_skeleton_into_books.sh` (0.1.2)**  
  Finalizes a populated skeleton into the Books library in three safe steps
  (rename → prune empty directories → copy without overwriting).  
  New in 0.1.2:
  - `--from-pruned` flag to start after the prune step
  - Auto-detection of `BooksInput_*` source names (skips rename + prune)
  - Fixed default report directory: `/mnt/c/Backup_Nova3/merge-reports`
  - `set -euo pipefail` restored (hardens rename/prune/copy against partial
    failures) and CLI parsing simplified to uniform `--flag VALUE` forms
  - Config and examples aligned on `/mnt/c/Backup_Nova3/Books`

## Testing

- Prefix-table family: 96/96 checks green under WSL (prefix table 34, nested-authors 28, visualizer 12, AWK generator 11, e2e pipeline 11).
- Merge tools: suites run under both Cygwin/MSYS bash and WSL.
  - `test_merge_books_into_skeleton.sh` — full coverage of dry-run, overwrite policies, config/env precedence, etc.
  - `test_merge_skeleton_into_books.sh` — dry-run, full run, `--no-rename`, `--from-pruned`, auto-detection, CLI, version header.
