# Author Toolchain

A collection of Bash + AWK scripts that turn a flat list of author names into
a UTF-8-safe, byte-ordered prefix structure — a prefix table, an integrity
check on that table, a rendered prefix tree, and a nested directory hierarchy.

Everything here operates on UTF-8 names (Russian/Cyrillic, ASCII, and other
scripts) and depends on one hard contract: **the author list is sorted in
`LC_ALL=C` byte order**, which keeps identical prefixes contiguous.

## Pipeline

Two families of tools live here:

```
build_prefix_table.sh ──> prefix_table_integrity.sh ──> prefix_tree_visualizer.sh
   (generate table)          (validate table)              (render tree)

build_shell_nested_authors.sh
   (build a nested directory tree directly from names)
```

The canonical prefix table format is TAB-separated with four columns:

```
prefix<TAB>count<TAB>start<TAB>end
```

where `prefix` is a name prefix, `count` is the number of authors sharing it,
and `[start..end]` is the contiguous 0-based index range those authors occupy
in the byte-sorted list (`end` is inclusive, so `count == end - start + 1`).

## Requirements

- **A multibyte-capable Bash.** The scripts slice UTF-8 prefixes character by
  character; Cygwin/MSYS Bash slices bytes and is rejected by the suites. Use
  **WSL** (`wsl.exe bash …`).
- **`gawk`** — required by `prefix_tree_visualizer.sh` and by the AWK parity
  checks.

## Tools

### `build_prefix_table.sh`

Generates the prefix table from a flat author list via a pre-order prefix-trie
walk over the byte-sorted names, so the rows are byte-ordered by construction.

```bash
./build_prefix_table.sh <input_file> [<max_prefix_length>]        # positional
./build_prefix_table.sh -i INPUT_FILE [-x NUM] [-o FILE] [-d ON|OFF]
```

Options: `-x/--max-prefix` (default 5), `-o/--output` (write to a file instead
of stdout), `-d/--debugger` (stderr diagnostics).

```bash
./build_prefix_table.sh authors_list_from_db.txt 5 > tmp_SORTED_AUTHORS
```

### `prefix_table_integrity.sh`

Ultra-strict validator for the prefix table. Reports problems by severity and
exits non-zero if any critical problem is found.

```bash
./prefix_table_integrity.sh [SEVERITY] <prefix_table> <max_prefix_length>
./prefix_table_integrity.sh -t TABLE [-x NUM] [-s SEVERITY]
```

Severities: `all` (default), `critical`, `warnings`, `info`.

```bash
./prefix_table_integrity.sh -t tmp_SORTED_AUTHORS -x 5
```

### `prefix_tree_visualizer.sh`

Renders the prefix table as a Unicode tree (`├──`, `└──`, `│`), grouped by
category (Symbols, Digits, ASCII, Cyrillic, Other) with true Russian
alphabetical ordering, per-node counts/ranges, depth limiting, and filtering.

```bash
./prefix_tree_visualizer.sh tmp_SORTED_AUTHORS [--depth N] [--filter CATEGORY]
```

### `build_shell_nested_authors.sh`

Emits `mkdir -p` commands (or SQL) that build a nested directory hierarchy from
the author names. A level is only created when its prefix is shared by at least
`MINIMUM_AUTHORS` authors, and only the deepest valid directory of each branch
is printed.

```bash
./build_shell_nested_authors.sh <input_file> <minimum_authors> <max_prefix_length>
./build_shell_nested_authors.sh -i INPUT_FILE [-m NUM] [-x NUM] [-d ON|OFF] [-f SHELL|SQL] [-r PATH] [-c ON|OFF]
```

Options: `-m/--min-authors` (default 10), `-x/--max-prefix` (default 5),
`-f/--format` (`SHELL` or `SQL`), `-r/--root-dir`, `-c/--clean-run`.

```bash
./build_shell_nested_authors.sh -i authors_list_from_db.txt -m 10 -x 5
```

### `utf8_prefix_generator.awk`

The original AWK generator, kept as a parity reference against
`build_prefix_table.sh`. Emits the same `prefix<TAB>count<TAB>start<TAB>end`
rows (in hash order — sort before comparing).

```bash
gawk -v maxlen=5 -F '\n' -f utf8_prefix_generator.awk <sorted_input>
```

## Testing

Each tool has a self-contained regression suite, plus one end-to-end suite that
chains the whole pipeline. All suites must run from WSL:

```bash
wsl.exe bash test_build_prefix_table.sh        # generator: goldens, invariants, parity, CLI
wsl.exe bash test_build_shell_nested_authors.sh
wsl.exe bash test_prefix_tree_visualizer.sh    # renderer: goldens, descent, filters, depth, CLI
wsl.exe bash test_utf8_prefix_generator.sh     # AWK generator: direct edge-case tests
wsl.exe bash test_e2e_pipeline.sh              # generator -> validator -> renderer on real data
```

Suites write nothing to the repository; each builds its scratch files in a
temporary directory. The golden-based suites accept `--regen` to refresh their
golden files.

## Releases & versioning

Each script's version lives in its header comment (`# Version:`), which the
script also prints in `-h` — a single source of truth, bumped `0.0.1` per
iteration. The working script at the repository root is the released artifact;
there is no separate `release/` snapshot to maintain.

Releases are tagged with a tool-prefixed name:

| Tool | Version | Tag |
|---|---|---|
| `build_prefix_table.sh` | 1.0.4 | `build_prefix_table-1.0.4` |
| `prefix_table_integrity.sh` | 1.2.1 | `prefix_table_integrity-1.2.1` |
| `prefix_tree_visualizer.sh` | 2.8.1 | `v2.8.1` |
| `build_shell_nested_authors.sh` | 6.6.8 | `v6.6.8` |
| `utf8_prefix_generator.awk` | 1.1 | `utf8_prefix_generator-1.1` |

`v2.8.1` and `v6.6.8` predate the tool-prefixed convention.

To cut a release: bump the header version, run the WSL test suites (see
[Testing](#testing)), commit, then tag with the tool-prefixed name. See
`CHANGELOG.md` for the full history and step-by-step workflow.

## Repository layout

```
build_prefix_table.sh           prefix-table generator (working script)
prefix_table_integrity.sh       prefix-table validator
prefix_tree_visualizer.sh       prefix-tree renderer
build_shell_nested_authors.sh   nested-directory builder
utf8_prefix_generator.awk       original AWK generator (parity reference)

test_*.sh                       regression suites (one per tool + e2e)
tests/                          fixtures and golden files

authors_list_from_db.txt        real author list (6,088 names)
CTE_table.sql / populate_tree.sql   nested-set dictionary table (schema + data)

CHANGELOG.md                    full release history
_Old_Stuff/ , _Save_Stuff/      archived/scratch files (git-ignored)
```

See `CHANGELOG.md` for the full release history and the step-by-step release
workflow.
