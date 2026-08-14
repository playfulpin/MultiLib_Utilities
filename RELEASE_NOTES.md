# Author Toolchain — v6.6.8 / toolchain milestone

A Bash + AWK toolchain that turns a flat author list into UTF-8-safe,
byte-ordered prefix structures: a prefix table, its integrity check, a rendered
prefix tree, and a nested directory hierarchy — all validated against a real
6,088-author dataset.

## Shipped tools

- `build_shell_nested_authors.sh` **6.6.8** — nested directory-tree builder (`mkdir -p` / SQL)
- `build_prefix_table.sh` **1.0.4** — pre-order trie prefix-table generator
- `prefix_table_integrity.sh` **1.2.1** — ultra-strict table validator
- `prefix_tree_visualizer.sh` **2.8.1** — Unicode tree renderer
- `utf8_prefix_generator.awk` **1.1** — original AWK generator (parity reference)

## Highlights

- Deterministic `LC_ALL=C` byte-order output — zero byte-order violations on real data.
- Multi-byte prefix-slicing fixes (`utf8_chop`, `utf8_prefix`) so trees descend through every level under byte locales.
- New end-to-end pipeline suite locks out cross-tool format drift.
- Root-only layout finalized — the `release/` snapshot model is retired; the root script is the released artifact.
- Tool-prefixed release tags: `build_prefix_table-1.0.4`, `prefix_table_integrity-1.2.1`, `utf8_prefix_generator-1.1` (plus the earlier `v6.6.8`, `v2.8.1`).

## Testing

96/96 checks green under WSL across five suites — prefix table 34, nested-authors 28, visualizer 12, AWK generator 11, e2e pipeline 11.
