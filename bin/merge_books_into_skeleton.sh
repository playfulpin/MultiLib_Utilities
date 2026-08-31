#!/usr/bin/env bash

###############################################################################
# bin/merge_books_into_skeleton.sh
#
# Version:       0.1.1
# Last updated:  2026-08-30 20:25
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Merge a legacy book archive into a pre-built author-prefix skeleton.
#   Every top-level folder of the source archive is treated as an author;
#   its files are copied into the deepest skeleton prefix directory that
#   matches the beginning of the author name.  Book-series subfolders are
#   copied recursively by default, preserving their relative layout.
#
#   The skeleton is the source of truth and is never modified (no new
#   directories, no unapproved overwrites).  See
#   docs/BOOK_LIBRARY_MERGE_PLAN.md for the full design.
#
# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
#   Every setting resolves flag > env var > config file > built-in default.
#   The optional config file is config/merge_books.conf (keys:
#   MERGE_SOURCE_DIR, MERGE_SKELETON_ROOT, MERGE_REPORT_DIR,
#   MERGE_RECURSIVE, MERGE_OVERWRITE).  --dry-run is intentionally not
#   configurable.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/merge_books_into_skeleton.sh \
#       --source /mnt/c/Backup_Nova3/ToLoad/Author \
#       --skeleton /mnt/c/Backup_Nova3/Library \
#       --report-dir /mnt/c/Backup_Nova3/merge-reports \
#       --dry-run
#
#   Always run --dry-run first and review the reports before a real copy.
#   The real copy omits --dry-run.  Use --no-recursive to copy only direct
#   files, and --overwrite=force to replace existing destination files.
#
# -----------------------------------------------------------------------------
# REPORTS (written to REPORT_DIR)
# -----------------------------------------------------------------------------
#   merge-manifest.tsv      one row per processed source child
#   unmatched-authors.tsv   authors with no matching skeleton prefix
#   ambiguous-authors.tsv   authors whose longest prefix has several paths
#   duplicates.tsv          destination name already existed / copied twice
#   collisions.tsv          same destination name written by 2 sources in-run
#   skipped-files.tsv       every non-copied row (folders, failures, ...)
#
#   Row format (TSV):
#       processed_at<TAB>source_author<TAB>source_file<TAB>destination_file<TAB>status<TAB>reason
#
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/merge_books_functions.sh
source "$SCRIPT_DIR/../lib/merge_books_functions.sh"

merge_main "$@"
