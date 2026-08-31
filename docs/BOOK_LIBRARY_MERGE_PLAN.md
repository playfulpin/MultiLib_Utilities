# Book library skeleton and merge plan

**Status:** Implemented (pipeline: merge v0.1.2 + finalize v0.1.0)  
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
an additional directory named after each author; the merge tool adds that
folder below the matched prefix.

## Phase 2: resolve an archive author

The merge tool will use the direct folder names under `ToLoad/Author/` as the
source author names. It will inspect the existing skeleton and select the
**deepest valid prefix directory** whose path corresponds to the beginning of
the author name, then place a folder named after the author below it.

Example:

```text
Source author:  Толстой Лев Николаевич
Destination:   Т/То/Толс/Толстой Лев Николаевич/
```

The skeleton itself holds only prefix directories; the author folder is a
merge-time extension below the matched prefix, so authors sharing a prefix
stay separate. If the matched prefix is already the author's own folder (from
a previous run), the author is not appended twice.

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

The implementation:

- processes direct author folders under `Author/`;
- gives each author its own **folder under the deepest matching prefix**, so
  authors that share a prefix never mix their books:
  `Абби Линн/Magic The Gathering/…` lands at
  `А/Аб/Абби Линн/Magic The Gathering/…`;
- copies every file of an author **recursively by default**: subfolders are
  book series and keep their relative layout inside the author folder;
- `--no-recursive` copies direct files only and records subfolders as skipped;
- **never copies Windows metadata** (`desktop.ini`, `Thumbs.db` by default,
  configurable via `MERGE_SKIP_NAMES`);
- empty subfolders are never created;
- copies files rather than moving or linking them;
- supports mixed book formats without unpacking archives;
- preserves source filenames and the series layout;
- leaves the source archive unchanged;
- copies into the deepest valid prefix directory;
- never overwrites without permission (policy `never` by default);
- remains safe to repeat (re-runs see author folders already in the skeleton).

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

The whole pipeline below is implemented (see `CHANGELOG.md`):

```text
bin/build_shell_nested_authors.sh        build the prefix skeleton (6.6.8)
bin/merge_books_into_skeleton.sh         fill it from the archive (v0.1.2)
lib/merge_books_functions.sh             shared functions for the merge tool
bin/merge_skeleton_into_books.sh         finalize into the Books library (v0.1.0)
```

The merge suite covers normal authors, Cyrillic names, duplicate filenames,
collisions, unmatched authors, ambiguous matches, recursive series copy,
`--no-recursive`, overwrite policies, skip list (desktop.ini / Thumbs.db),
config-file loading, mixed extensions, dry-run behavior, and repeated
execution (45/45 checks).  The finalize suite is 21/21 checks.

Statuses used in the merge reports: `copied`, `would-copy` (dry run),
`overwritten`, `duplicate-name` (destination name already existed),
`duplicate` (same source copied twice), `collision` (destination name written
this run by a different source), `unmatched-author`, `ambiguous-author`, and
`skipped` (failed copies, subfolders under `--no-recursive`, or Windows
metadata matched by the skip list).

## Finalize step: merge the populated skeleton into Books

`bin/merge_skeleton_into_books.sh` (v0.1.0) finalizes the populated skeleton
into the Books library in three safe steps:

1. rename the skeleton to a timestamped staging folder `BooksInput_<ts>`;
2. remove every empty directory inside the staging folder;
3. copy the remaining content into `Books`, never overwriting an existing
   folder or file (the destination wins).

```bash
./bin/merge_skeleton_into_books.sh \
  --source /mnt/c/Backup_Nova3/Empty_Skeleton \
  --target /mnt/c/Backup_Nova3/Books \
  --report-dir /mnt/c/Backup_Nova3/merge-reports \
  --dry-run
```

The staging folder is retained intact (the input is not consumed); only empty
subdirectories are pruned.  A per-file TSV report records `copied` / `kept-
existing` (or `would-copy` / `would-keep` in a dry run).  `--no-rename` and
`--no-prune` are escape hatches.  `--dry-run` is always run first.
