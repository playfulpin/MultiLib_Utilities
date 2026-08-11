# Changelog

All notable changes to `build_shell_nested_authors.sh`.

## [6.6.8] - 2026-08-11

Release of the final, tested state.  No functional changes since 6.6.7; the
version increment marks the script as complete and release-ready.

- Full regression suite green: **45/45 checks** (`wsl.exe bash test_build_shell_nested_authors.sh`).
- Syntax-verified (`bash -n`), version `6.6.8` confirmed in header and `-h` output.

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
