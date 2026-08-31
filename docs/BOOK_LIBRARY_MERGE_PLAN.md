# Book library skeleton and merge plan

**Status:** Implemented (v0.1.0)  
**Updated:** 2026-08-30

## Goal

Build an author-prefix directory skeleton with the existing tools, then copy
books from the existing archive into the deepest valid prefix directory for
each author.

The source archive is:

```text
C:\Backup_Nova3\ToLoad
```

From WSL2, use:

```text
/mnt/c/Backup_Nova3/ToLoad
```

The archive contains mixed book formats. Author folders already exist, but use
a different structure from the new skeleton:

```text
ToLoad/
└── Author/
    ├── <author-name>/
    │   ├── book files
    │   └── optional nested folders
    └── ...
```

## Phase 1: build the skeleton

Use `bin/build_shell_nested_authors.sh` with the canonical author list:

```bash
cd /home/mike/GIT_ROOT/MultiLib_Utilities

./bin/build_shell_nested_authors.sh \
  -i data/fixtures/authors_list_from_db.txt \
  -m 10 \
  -x 5 \
  -r /mnt/c/Backup_Nova3/Library \
  -c ON \
  > /tmp/build-author-skeleton.sh

bash /tmp/build-author-skeleton.sh
```

Always test with a temporary destination first. The source archive must not be
modified.

The skeleton builder creates only valid prefix directories. It does not create
an additional directory named after each author.

## Phase 2: resolve an archive author

The merge tool will use the direct folder names under `ToLoad/Author/` as the
source author names. It will inspect the existing skeleton and select the
**deepest valid prefix directory** whose path corresponds to the beginning of
the author name.

Example:

```text
Source author:  Толстой Лев Николаевич
Destination:   Т/То/Толс/
```

No additional author-specific directory is created below `Т/То/Толс/`.

The skeleton is the source of truth for valid destination paths. If no matching
path exists, the author is reported as unmatched and no files are copied. If a
match is ambiguous, the author is reported and no files are copied until the
ambiguity is resolved.

## Phase 3: copy books

The command is:

```bash
./bin/merge_books_into_skeleton.sh \
  --source /mnt/c/Backup_Nova3/ToLoad/Author \
  --skeleton /mnt/c/Backup_Nova3/Library \
  --report-dir /mnt/c/Backup_Nova3/merge-reports \
  --dry-run
```

The implementation (v0.1.1):

- processes direct author folders under `Author/`;
- copies every file of an author **recursively by default**: subfolders are
  book series and keep their relative layout inside the destination prefix
  directory (`Серия/том1.fb2` lands next to the author's other books);
- `--no-recursive` copies direct files only and records subfolders as skipped;
- empty subfolders are never created;
- copies files rather than moving or linking them;
- supports mixed book formats without unpacking archives;
- preserves source filenames and the series layout;
- leaves the source archive unchanged;
- copies into the deepest valid prefix directory;
- never overwrites without permission (policy `never` by default);
- remains safe to repeat.

Multi-author expansion is deliberately out of scope for this first merge
operation. It can be added later when the metadata and identity rules are
confirmed.

## Duplicate, collision, and overwrite policy

Duplicate detection uses destination filename matching:

- If the destination filename does not exist, copy the file.
- If the same filename already exists, the **overwrite policy** decides:
  - `never` (default) — skip the copy and record it;
  - `ask` — prompt per file (non-interactive runs behave like `never`);
  - `force` — replace it and record status `overwritten`.
- A file written twice by the same source is always skipped as a duplicate.
- Same-name cases from different sources are recorded as collisions.
- Record every skipped duplicate.

Filename-only comparison is not content-safe: unrelated books may share a
filename. A future improvement should use size plus SHA-256 verification before
considering files identical.

## Reports and manifest

The merge operation should write a report directory containing:

```text
merge-manifest.tsv
unmatched-authors.tsv
ambiguous-authors.tsv
collisions.tsv
duplicates.tsv
skipped-files.tsv
```

The manifest should record at least:

```text
processed_at  source_author  source_file  destination_file  status  reason
```

Possible statuses include `copied`, `duplicate-name`, `collision`,
`unmatched-author`, `ambiguous-author`, and `skipped`.

## Configuration

`config/merge_books.conf` supplies defaults for the source, skeleton, report
directory, recursive behavior, and overwrite policy. Every setting resolves
**flag > environment variable > config file > built-in default**. `--dry-run`
is deliberately not configurable — it stays a command-line safety gate.

## Safety and rollout

Run the following sequence:

1. Generate the skeleton in a temporary directory.
2. Inspect its prefix paths and confirm the minimum-author policy.
3. Run the merge tool with `--dry-run`.
4. Review unmatched authors, ambiguous matches, collisions, and skipped files.
5. Run the real copy only after the dry-run report is acceptable.
6. Preserve the manifest for audit and future resume operations.

`--overwrite=force` is implemented and reviewed, but treat it as the exception:
`never` is the safe default and `ask` prompts per file.

## Implementation

The files below were implemented in v0.1.0 (see `CHANGELOG.md`):

```text
bin/merge_books_into_skeleton.sh
lib/merge_books_functions.sh
tests/test_merge_books_into_skeleton.sh
```

The suite covers normal authors, Cyrillic names, duplicate filenames,
collisions, unmatched authors, ambiguous matches, recursive series copy,
`--no-recursive`, overwrite policies, config-file loading, mixed extensions,
dry-run behavior, and repeated execution (42/42 checks).

Statuses used in the reports: `copied`, `would-copy` (dry run),
`overwritten`, `duplicate-name` (destination name already existed),
`duplicate` (same source copied twice), `collision` (destination name written
this run by a different source), `unmatched-author`, `ambiguous-author`, and
`skipped` (failed copies, or subfolders under `--no-recursive`).
