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
bin/build_prefix_table.sh ──> bin/prefix_table_integrity.sh ──> bin/prefix_tree_visualizer.sh
   (generate table)          (validate table)              (render tree)

bin/build_shell_nested_authors.sh
   (build a nested directory tree directly from names)

bin/merge_books_into_skeleton.sh
   (copy a legacy book archive into the skeleton, safely)

bin/merge_skeleton_into_books.sh
   (rename, prune empties, and finalize the skeleton into the Books library)
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
- **`gawk`** — required by `bin/prefix_tree_visualizer.sh` and by the AWK parity
  checks.

## Tools

### `bin/build_prefix_table.sh`

Generates the prefix table from a flat author list via a pre-order prefix-trie
walk over the byte-sorted names, so the rows are byte-ordered by construction.

```bash
./bin/build_prefix_table.sh <input_file> [<max_prefix_length>]        # positional
./bin/build_prefix_table.sh -i INPUT_FILE [-x NUM] [-o FILE] [-d ON|OFF]
```

Options: `-x/--max-prefix` (default 5), `-o/--output` (write to a file instead
of stdout), `-d/--debugger` (stderr diagnostics).

```bash
./bin/build_prefix_table.sh data/fixtures/authors_list_from_db.txt 5 > tmp_SORTED_AUTHORS
```

### `bin/prefix_table_integrity.sh`

Ultra-strict validator for the prefix table. Reports problems by severity and
exits non-zero if any critical problem is found.

```bash
./bin/prefix_table_integrity.sh [SEVERITY] <prefix_table> <max_prefix_length>
./bin/prefix_table_integrity.sh -t TABLE [-x NUM] [-s SEVERITY]
```

Severities: `all` (default), `critical`, `warnings`, `info`.

```bash
./bin/prefix_table_integrity.sh -t tmp_SORTED_AUTHORS -x 5
```

### `bin/prefix_tree_visualizer.sh`

Renders the prefix table as a Unicode tree (`├──`, `└──`, `│`), grouped by
category (Symbols, Digits, ASCII, Cyrillic, Other) with true Russian
alphabetical ordering, per-node counts/ranges, depth limiting, and filtering.

```bash
./bin/prefix_tree_visualizer.sh tmp_SORTED_AUTHORS [--depth N] [--filter CATEGORY]
```

### `bin/build_shell_nested_authors.sh`

Emits `mkdir -p` commands (or SQL) that build a nested directory hierarchy from
the author names. A level is only created when its prefix is shared by at least
`MINIMUM_AUTHORS` authors, and only the deepest valid directory of each branch
is printed.

```bash
./bin/build_shell_nested_authors.sh <input_file> <minimum_authors> <max_prefix_length>
./bin/build_shell_nested_authors.sh -i INPUT_FILE [-m NUM] [-x NUM] [-d ON|OFF] [-f SHELL|SQL] [-r PATH] [-c ON|OFF]
```

Options: `-m/--min-authors` (default 10), `-x/--max-prefix` (default 5),
`-f/--format` (`SHELL` or `SQL`), `-r/--root-dir`, `-c/--clean-run`.

```bash
./bin/build_shell_nested_authors.sh -i data/fixtures/authors_list_from_db.txt -m 10 -x 5
```

### `bin/merge_books_into_skeleton.sh`

Copies the files of every top-level author folder in a legacy archive into a
directory named after the author, placed under the **deepest valid prefix
** of a pre-built skeleton:

```text
source:  Абби Линн/Magic The Gathering/0Мироходец.zip
dest:    А/Аб/Абби Линн/Magic The Gathering/0Мироходец.zip
```

Book-series subfolders are copied recursively by default, preserving their
relative layout. Windows metadata files (`desktop.ini`, `Thumbs.db` by
default) are never copied. The skeleton itself is never modified; existing
destination files are never overwritten unless the user allows it. See
`docs/BOOK_LIBRARY_MERGE_PLAN.md` for the full design.

```bash
./bin/merge_books_into_skeleton.sh \
    --source /mnt/c/Backup_Nova3/ToLoad/Author \
    --skeleton /mnt/c/Backup_Nova3/Library \
    --report-dir /mnt/c/Backup_Nova3/merge-reports \
    --dry-run
```

Options: `-s/--source`, `-k/--skeleton`, `-r/--report-dir` (default
`$PWD/merge-reports`), `--config FILE`, `--recursive` / `--no-recursive`,
`--overwrite never|ask|force`, `--dry-run` (resolve and report, copy
nothing), `-v/--version`, `-h/--help`.

Every setting resolves **flag > environment variable > config file > built-in
default**. The optional `config/merge_books.conf` holds the source, skeleton,
report directory, recursive behavior, overwrite policy, and the skip list
(`MERGE_SKIP_NAMES`); the same keys work as environment variables
(`MERGE_SOURCE_DIR`, `MERGE_SKELETON_ROOT`, ...). `--dry-run` is
intentionally not configurable.

Reports are written as TSV files: `merge-manifest.tsv`,
`unmatched-authors.tsv`, `ambiguous-authors.tsv`, `collisions.tsv`,
`duplicates.tsv`, and `skipped-files.tsv`. Always run `--dry-run` first and
review the reports before a real copy.

Unlike the UTF-8-slicing tools, this script compares prefixes byte-wise
(exact for UTF-8), so it runs under both Cygwin/MSYS bash and WSL.

### `bin/merge_skeleton_into_books.sh`

The finalize step: after the merge tool has populated the skeleton, turn it
into the Books library in three safe steps:

1. rename the skeleton to a timestamped staging folder `BooksInput_<ts>`;
2. remove every empty directory inside it;
3. copy the remaining content into `Books`, **never overwriting** an existing
   folder or file (the destination wins).

```bash
./bin/merge_skeleton_into_books.sh \
    --source /mnt/c/Backup_Nova3/Empty_Skeleton \
    --target /mnt/c/Backup_Nova3/Books \
    --dry-run
```

Options: `-s/--source`, `-t/--target`, `--timestamp=STAMP`, `--report-dir=DIR`,
`--no-rename`, `--no-prune`, `--dry-run`, `-v/--version`, `-h/--help`. The
staging folder is retained intact (nothing is consumed); only empty
subdirectories are removed. A TSV report is written per run.

### `lib/utf8_prefix_generator.awk`

The original AWK generator, kept as a parity reference against
`bin/build_prefix_table.sh`. Emits the same `prefix<TAB>count<TAB>start<TAB>end`
rows (in hash order — sort before comparing).

```bash
gawk -v maxlen=5 -F '\n' -f lib/utf8_prefix_generator.awk <sorted_input>
```

## Testing

Each tool has a self-contained regression suite, plus one end-to-end suite that
chains the whole pipeline. All suites must run from WSL:

```bash
wsl.exe bash tests/test_build_prefix_table.sh        # generator: goldens, invariants, parity, CLI
wsl.exe bash tests/test_build_shell_nested_authors.sh
wsl.exe bash tests/test_prefix_tree_visualizer.sh    # renderer: goldens, descent, filters, depth, CLI
wsl.exe bash tests/test_utf8_prefix_generator.sh     # AWK generator: direct edge-case tests
wsl.exe bash tests/test_e2e_pipeline.sh              # generator -> validator -> renderer on real data
bash tests/test_merge_books_into_skeleton.sh         # archive -> skeleton merge (runs anywhere)
bash tests/test_merge_skeleton_into_books.sh        # skeleton -> Books finalize (runs anywhere)
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
| `bin/build_prefix_table.sh` | 1.0.4 | `build_prefix_table-1.0.4` |
| `bin/prefix_table_integrity.sh` | 1.2.1 | `prefix_table_integrity-1.2.1` |
| `bin/prefix_tree_visualizer.sh` | 2.8.1 | `v2.8.1` |
| `bin/build_shell_nested_authors.sh` | 6.6.8 | `v6.6.8` |
| `bin/merge_books_into_skeleton.sh` | 0.1.2 | `merge_books_into_skeleton-0.1.2` |
| `bin/merge_skeleton_into_books.sh` | 0.1.0 | `merge_skeleton_into_books-0.1.0` |
| `lib/utf8_prefix_generator.awk` | 1.1 | `utf8_prefix_generator-1.1` |

`v2.8.1` and `v6.6.8` predate the tool-prefixed convention.

To cut a release: bump the header version, run the WSL test suites (see
[Testing](#testing)), commit, then tag with the tool-prefixed name. See
`CHANGELOG.md` for the full history and step-by-step workflow.

## Repository layout

```
bin/build_prefix_table.sh           prefix-table generator (working script)
bin/prefix_table_integrity.sh       prefix-table validator
bin/prefix_tree_visualizer.sh       prefix-tree renderer
bin/build_shell_nested_authors.sh   nested-directory builder
bin/merge_books_into_skeleton.sh    archive -> skeleton merge tool
bin/merge_skeleton_into_books.sh    skeleton -> Books finalize tool
lib/merge_books_functions.sh        shared functions for the merge tool
lib/utf8_prefix_generator.awk       original AWK generator (parity reference)
config/merge_books.conf             defaults for the merge tool (paths + behavior)

tests/test_*.sh                 regression suites (one per tool + e2e)
tests/                          fixtures and golden files

docs/BOOK_LIBRARY_MERGE_PLAN.md        skeleton + merge design document

data/fixtures/authors_list_from_db.txt        real author list (6,088 names)
data/sql/CTE_table.sql / data/sql/populate_tree.sql   nested-set dictionary table (schema + data)

CHANGELOG.md                    full release history
_Old_Stuff/ , _Save_Stuff/      archived/scratch files (git-ignored)
```

See `CHANGELOG.md` for the full release history and the step-by-step release
workflow.
