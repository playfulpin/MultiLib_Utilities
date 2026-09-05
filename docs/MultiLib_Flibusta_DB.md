# MultiLib / Flibusta database — reference

> **Scope:** everything we know about the MariaDB instance that backs the
> MultiLib desktop app and the Flibusta catalog — the `flibusta`,
> `privetelib` and `mllbr_main` databases, their tables, relationships,
> schema, how the data gets loaded and updated, the toolchain that
> maintains it, and the hard-won implementation details.
>
> **Updated:** 2026-09-04
> **Companion docs:** `docs/REPRESENTATION_PLAN.md` (the personal-library
> representation plan this DB serves), `docs/NEXT.md` (resume notes),
> `docs/Flibusta_DB_findings.txt` (the original md5 idea).

---

## Table of contents

1. [Overview](#1-overview)
   1.1 [Environment at a glance](#11-environment-at-a-glance)
   1.2 [The three libraries](#12-the-three-libraries)
   1.3 [Who writes what](#13-who-writes-what)
2. [Database topology](#2-database-topology)
   2.1 [Databases](#21-databases)
   2.2 [The 17-table ml\* schema](#22-the-17-table-ml-schema)
   2.3 [mllbr_main — the app's own schema](#23-mllbr_main--the-apps-own-schema)
3. [Table reference](#3-table-reference)
   3.1 [mlbook — the catalog hub](#31-mlbook--the-catalog-hub)
   3.2 [Reference (name) tables](#32-reference-name-tables)
   3.3 [Join tables](#33-join-tables)
   3.4 [Attached data](#34-attached-data)
   3.5 [Enrichment gaps: mlcoverpage / mldescription](#35-enrichment-gaps-mlcoverpage--mldescription)
   3.6 [App-owned tables](#36-app-owned-tables)
4. [Relationships and data model](#4-relationships-and-data-model)
   4.1 [Entity-relationship summary](#41-entity-relationship-summary)
   4.2 [The genre tree](#42-the-genre-tree)
   4.3 [Key strategy: AUTO_INCREMENT, no foreign keys](#43-key-strategy-auto_increment-no-foreign-keys)
5. [The lib\* dump schema](#5-the-lib-dump-schema)
   5.1 [Table-by-table](#51-table-by-table)
   5.2 [Load order](#52-load-order)
   5.3 [Where the lib\* tables go](#53-where-the-lib-tables-go)
6. [Loading and update logic](#6-loading-and-update-logic)
   6.1 [BookTracker-import pipeline](#61-booktracker-import-pipeline)
   6.2 [The six ingest stages](#62-the-six-ingest-stages)
   6.3 [mlrating: per-user librate → per-book aggregate](#63-mlrating-per-user-librate--per-book-aggregate)
   6.4 [MultiLib_Utilities tools](#64-multilib_utilities-tools)
   6.5 [Data flow end to end](#65-data-flow-end-to-end)
7. [Key findings and implementation details](#7-key-findings-and-implementation-details)
   7.1 [md5 matching: the strongest lookup tier](#71-md5-matching-the-strongest-lookup-tier)
   7.2 [filename / arcname are not archive names](#72-filename--arcname-are-not-archive-names)
   7.3 [Covers and descriptions are empty](#73-covers-and-descriptions-are-empty)
   7.4 [Duplicate md5s and multi-author books](#74-duplicate-md5s-and-multi-author-books)
   7.5 [Charset: pinning the client](#75-charset-pinning-the-client)
   7.6 [WSL2 ↔ Windows MariaDB lifecycle](#76-wsl2--windows-mariadb-lifecycle)
   7.7 [The mysql_upgrade incident](#77-the-mysql_upgrade-incident)
   7.8 [MyISAM crash and recovery](#78-myisam-crash-and-recovery)
8. [Connection contract and invariants](#8-connection-contract-and-invariants)
   8.1 [Connection contract](#81-connection-contract)
   8.2 [Invariants](#82-invariants)
9. [Appendix: snapshots](#9-appendix-snapshots)
   9.1 [Row counts](#91-row-counts)
   9.2 [mlrating distribution](#92-mlrating-distribution)
   9.3 [Index inventory (mlbook)](#93-index-inventory-mlbook)

---

## 1. Overview

The MultiLib desktop app (`C:\MultiLib\`, `MultiLib.exe`) models **a
library = a MySQL/MariaDB database with the 17-table `ml*` schema**. It
switches between libraries via `CurrentLibName` in `MultiLib.ini`
(`[MySQL] root@localhost:3306`, no password). The app never touches
`flibusta`'s raw dump tables — it reads only the `ml*` catalog shape.

The **Flibusta catalog** lives in the `flibusta` database (869,130 books
at the last load). The **personal library** lives in `privetelib` — an
empty sibling library created in-app with the Flibusta plugin, now
populated from the on-disk `Books` collection by
`bin/populate_privetelib.sh`. A third database, `mllbr_main`, is the
app's original built-in library and uses a *different*, smaller schema.

### 1.1 Environment at a glance

| Item | Value |
|---|---|
| Server | MariaDB **10.4.7** portable Windows build |
| Executable | `C:\mariadb-10.4.7-winx64\bin\mysqld.exe --console` |
| Host / port | `127.0.0.1:3306` (TCP; WSL2 talks to the Windows host) |
| User | `root`, no password (local development box) |
| Client | WSL2 Ubuntu `mysql` CLI (Ubuntu package) |
| Storage engine | **MyISAM** everywhere in the ml\* schema (no InnoDB FKs) |
| Collations | `utf8_general_ci` for the ml\* tables, `utf8_unicode_ci` for `mlactual` |
| Databases | `flibusta`, `privetelib`, `mllbr_main` (+ system DBs) |

### 1.2 The three libraries

| Database | Role | Schema | Populated by |
|---|---|---|---|
| `flibusta` | The full catalog — read-only source for everything | 17-table `ml*` | BookTracker-import ingest pipeline |
| `privetelib` | The **personal** library (the end-user's own collection) | Same 17-table `ml*` | `bin/populate_privetelib.sh` from the `Books` folder |
| `mllbr_main` | The app's original built-in library | Different, 4-table schema (`mldownload`, `mlgenrelist`, `mlgroup`, `mlgroupname`) | The app itself |

### 1.3 Who writes what

* **BookTracker-import** writes `flibusta` (loads the dumps, converts
  `lib*` → `ml*`, drops the staging tables).
* **MultiLib_Utilities tools** (export, reconcile, estimate, backup,
  populate) **never write `flibusta` or `mllbr_main`**. The populate tool
  writes only the managed catalog tables inside `privetelib`.
* **The app itself** owns `mlactual`, `mldownloaddata`, `mlnews*`,
  `mluser*` in any ml\* library — the tools leave those rows alone.

---

## 2. Database topology

### 2.1 Databases

```
MariaDB 10.4.7 (127.0.0.1:3306)
├── flibusta          # the catalog (17 ml* tables)
├── privetelib        # the personal library (same 17 ml* tables)
├── mllbr_main        # the app's original library (4 tables)
├── mysql             # server system tables
├── information_schema
└── performance_schema
```

### 2.2 The 17-table ml\* schema

`flibusta` and `privetelib` share the same 17 tables (verified
column-identical for all 9 catalog tables on 2026-09-04; the populate
tool re-verifies parity on every run). They fall into five groups:

| Group | Tables | Purpose |
|---|---|---|
| Hub | `mlbook` | One row per book — the center of the model |
| Reference names | `mlauthorname`, `mlgenrename`, `mlseqname` | Name dictionaries for authors, genres, series |
| Joins | `mlauthor`, `mlgenre`, `mlseq` | Many-to-many links book ↔ author / genre / series |
| Attached data | `mlrating`, `mlcustinfo` | Per-book rating and custom info |
| Enrichment gaps | `mlcoverpage`, `mldescription` | **Empty** in the loaded dump (see [7.3](#73-covers-and-descriptions-are-empty)) |
| App-owned | `mlactual`, `mldownloaddata`, `mlnews`, `mlnewsname`, `mluserkeyword`, `mluserprim` | Rows the app itself writes; tools never touch them |

### 2.3 mllbr_main — the app's own schema

The app's original library is *not* an `ml*` library — it uses a
different, minimal schema:

| Table | Rows (2026-09-04) | Purpose |
|---|---|---|
| `mldownload` | 0 | Download records |
| `mlgenrelist` | 109 | Genre dictionary |
| `mlgroup` | 0 | Group records |
| `mlgroupname` | 3 | Group names |

This is why the app supports "switching libraries": the Flibusta plugin
creates a *second* library (`privetelib`) with the full `ml*` schema,
and the app's UI can point at either.

---

## 3. Table reference

All columns below are from the live `flibusta` schema (26 columns in
`mlbook`), verified on 2026-09-04. Types are abbreviated
(`int(11)`, `varchar(n)`, `char(n)`, `datetime`, `binary(1)`).

### 3.1 mlbook — the catalog hub

**Purpose:** one row per book. Everything else hangs off `bookid`.

**Key:** `bookid` INT AUTO_INCREMENT PRIMARY KEY (sequence at ~887,686
in the dump source; the loaded table holds 869,130 rows).

| Column | Type | Notes |
|---|---|---|
| `bookid` | int | PK, auto-increment |
| `library` | varchar(64) | Source library name (`'flibusta'` in the catalog; `'privetelib'` in the personal library) |
| `title` | varchar(255) | Book title |
| `lang` | varchar(10) | Language code (indexed) |
| `date_in` | datetime | Date the book entered the catalog |
| `filename` | varchar(255) | **Transliterated** librusec-style name in the catalog (indexed) — *not* the archive filename; see [7.2](#72-filename--arcname-are-not-archive-names). In `privetelib` (v1.1.1+) it holds the **same catalog value** — the app displays it. |
| `filesize` | int | Size in bytes (decompressed FB2 size in the catalog; on-disk file size in `privetelib`) |
| `arcname` | varchar(255) | Zip member name; **empty (0%) in the catalog**, populated in `privetelib` |
| `ext` | varchar(5) | Content format, `'fb2'` (indexed) |
| `deleted` | char(1) | Deleted flag (indexed) |
| `md5` | char(32) | Hex md5 of the **decompressed FB2 content** — 100% populated, non-unique index (see [7.1](#71-md5-matching-the-strongest-lookup-tier)) |
| `srclang` | varchar(10) | Source language |
| `date_wr` | char(32) | Written date (free-form) |
| `keywords` | varchar(255) | Keywords |
| `di_progused` | varchar(255) | Producing program |
| `di_date` | char(32) | Document date |
| `di_srcurl` | varchar(255) | Source URL |
| `di_srcosr` | varchar(100) | Source origin |
| `di_author` | varchar(100) | Document author |
| `di_id` | varchar(254) | Document id |
| `di_version` | varchar(10) | Document version |
| `pi_bookname` | varchar(255) | Publication: book name |
| `pi_publisher` | varchar(100) | Publication: publisher |
| `pi_city` | varchar(50) | Publication: city |
| `pi_year` | varchar(10) | Publication: year |
| `pi_isbn` | varchar(100) | Publication: ISBN |

### 3.2 Reference (name) tables

Name dictionaries. Each row is one author / genre / series; the join
tables reference their ids.

#### mlauthorname

**Purpose:** author names and catalog-wide counts. **Key:** `authorid`
INT AUTO_INCREMENT PRIMARY KEY.

| Column | Type | Notes |
|---|---|---|
| `authorid` | int unsigned | PK, auto-increment |
| `FirstName` / `MiddleName` / `LastName` | varchar(99) | Name parts |
| `NickName` | varchar(33) | Pen name |
| `FullName` | varchar(200) | Canonical display name (indexed) — the field the reconcile tool matches disk folders against |
| `Email` | varchar(255) | Nullable |
| `TotalCount` | int | Books by this author in the catalog |
| `NormalCount` | int | Non-deleted books by this author |

#### mlgenrename

**Purpose:** genre names, forming a **tree** via `parentgenreid`.
**Key:** `genreid` INT AUTO_INCREMENT PRIMARY KEY.

| Column | Type | Notes |
|---|---|---|
| `genreid` | int | PK, auto-increment |
| `parentgenreid` | int | **Self-reference** to another row of this table (or NULL) — see [4.2](#42-the-genre-tree) |
| `genrecode` | varchar(30) | Machine code (indexed), e.g. `sf_hard` |
| `genrenamerus` | varchar(100) | Russian display name (indexed) |
| `TotalCount` / `NormalCount` | int | Catalog book counts per genre |

Only 296 rows — the genre taxonomy is small.

#### mlseqname

**Purpose:** series names. **Key:** `seqid` INT UNSIGNED AUTO_INCREMENT
PRIMARY KEY, `seqname` varchar(254) **UNIQUE**.

| Column | Type |
|---|---|
| `seqid` | int unsigned (PK) |
| `seqname` | varchar(254), UNIQUE |
| `TotalCount` / `NormalCount` | int |

### 3.3 Join tables

Pure many-to-many links. Each row has its own auto-increment PK **plus**
the two foreign ids; there are **no FK constraints** (MyISAM), so the
ids are meaningful only by convention — which is why the populate tool
regenerates them (see [4.3](#43-key-strategy-auto_increment-no-foreign-keys)).

#### mlauthor — book ↔ author

| Column | Type | Notes |
|---|---|---|
| `la_id` | int | PK, auto-increment |
| `bookid` | int unsigned | → `mlbook.bookid` (indexed) |
| `authorid` | int unsigned | → `mlauthorname.authorid` (indexed) |
| `role` | binary(1) | Role byte, `'a'` (author) |

A book can have **multiple** rows (multi-author books — every sampled
book had exactly 2 authors). `flibusta` holds 1,073,467 rows.

#### mlgenre — book ↔ genre

| Column | Type |
|---|---|
| `gn_id` | int (PK, auto-increment) |
| `bookid` | int unsigned (indexed) |
| `genreid` | int unsigned (indexed) |

`flibusta` holds 1,374,515 rows (a book typically has 2–3 genres).

#### mlseq — book ↔ series (with position)

| Column | Type | Notes |
|---|---|---|
| `sq_id` | int | PK, auto-increment |
| `bookid` | int (indexed) | → `mlbook.bookid` |
| `seqid` | int (indexed) | → `mlseqname.seqid` |
| `seqnum` | int | Position **within** the series |

`flibusta` holds 446,629 rows.

### 3.4 Attached data

#### mlrating — the per-book aggregate rating

**Purpose:** exactly one row per *rated* book (361,761 rows ↔ 361,761
distinct bookids). Built by
`BookTracker-import/sql/Flibusta_Load_mlrating.sql` from the raw
per-user `librate` table (see [6.3](#63-mlrating-per-user-librate--per-book-aggregate)).

| Column | Type | Notes |
|---|---|---|
| `rt_id` | int unsigned | PK, auto-increment |
| `bookid` | int | → `mlbook.bookid` (indexed) |
| `rating` | char(1) | `'1'`–`'5'` (indexed) |

The dump definition uses `ROW_FORMAT=FIXED`, `AVG_ROW_LENGTH=12`,
`AUTO_INCREMENT=340117`, MyISAM.

#### mlcustinfo — per-book custom info

| Column | Type |
|---|---|
| `ci_id` | int (PK, auto-increment) |
| `bookid` | int (indexed) |
| `di_history` | varchar(2048) |
| `custominfo` | varchar(2048) |

`flibusta` holds 163,161 rows (books that carry custom info).

### 3.5 Enrichment gaps: mlcoverpage / mldescription

Both tables exist in the schema but are **empty** in the loaded dump —
covers and descriptions are shipped in the *extended-data torrents*,
which the current pipeline does not load. This means "enrichment comes
free" does **not** hold for covers/descriptions; the real enrichment in
the loaded catalog is ratings, series, genres, and `mlcustinfo`. See
[7.3](#73-covers-and-descriptions-are-empty).

### 3.6 App-owned tables

`mlactual`, `mldownloaddata`, `mlnews`, `mlnewsname`, `mluserkeyword`,
`mluserprim` — all empty in `flibusta` (0 rows) and all **owned by the
app**: it writes them as the user works (downloads, news, user keyword
priming). The MultiLib_Utilities tools never touch them, so app-written
rows survive population runs.

---

## 4. Relationships and data model

### 4.1 Entity-relationship summary

```
                    mlauthorname (authors)
                         ▲
                         │ authorid
mlbook ──┬── 1:N ── mlauthor (book↔author join)
         │
         ├── 1:N ── mlgenre ── N:1 ── mlgenrename (genres, tree)
         │              │
         │              └── parentgenreid ── self → mlgenrename
         │
         ├── 1:N ── mlseq ── N:1 ── mlseqname (series)   (+ seqnum = position)
         │
         ├── 1:0..1 ── mlrating   (per-book aggregate rating)
         ├── 1:0..1 ── mlcustinfo (custom info)
         └── 1:0..1 ── mlcoverpage / mldescription (future: extended torrents)
```

All links are **by convention** — MyISAM has no FK enforcement, so
referential integrity is maintained by the loaders and by the populate
tool's key-capture discipline (below).

### 4.2 The genre tree

`mlgenrename.parentgenreid` points at another row of the same table
(`NULL` for roots). Example from the live data: `sf_hard` has parent
`sf`. The populate tool remaps these references to the *freshly
generated* genre ids when the parent genre is part of the personal
library, and writes `NULL` when the parent is not used — and it emits
genres **parent-first** so the parent's captured id exists before the
child references it.

### 4.3 Key strategy: AUTO_INCREMENT, no foreign keys

Every table generates its own ids (`AUTO_INCREMENT`), including the join
tables (`la_id`, `gn_id`, `sq_id`, `rt_id`, `ci_id`). The Flibusta dump
loader itself follows this pattern: generate via the sequence, then
store the id explicitly in the dump (the ids are stable artifacts of the
loader — `libavtorname` authorids, `libbook` bookids, etc.).

**Consequence for `privetelib`:** copying flibusta's ids wholesale
(the v1.0.0 populate) broke the app's key bookkeeping — the app showed
catalog basics but no books. The v1.1.0 populate therefore regenerates
every key: `INSERT` one row → capture `LAST_INSERT_ID()` into a session
variable (`@bid_<old>`, `@aid_<old>`, `@gid_<old>`, `@sid_<old>`) →
child rows reference only captured variables, and `TRUNCATE` at the top
of the one-session script resets the counters for a clean rebuild. See
`bin/populate_privetelib.sh` and [6.4](#64-multilib_utilities-tools).

---

## 5. The lib\* dump schema

The `flibusta` database is loaded from the official Flibusta SQL dumps
(`lib.*.sql.gz` from the `FlibustaSQL` torrent). These **source tables**
are a flat, loader-oriented mirror of the catalog — some are pure joins,
some are the dictionaries that later become the `ml*` reference tables.
The dumps were inspected (CREATE TABLE + insert samples) on 2026-09-04.

### 5.1 Table-by-table

| Dump file | Table (in DB) | Key construction | Role |
|---|---|---|---|
| `lib.libavtor.sql` | `libavtor` | `(BookId, AvtorId)` composite PK + `Pos`; **no** auto-inc | Pure join rows book ↔ author |
| `lib.libavtorname.sql` | `libavtorname` | `AvtorId` AUTO_INCREMENT (seq ≈ 344,676), ids **stored explicitly** in the dump (`VALUES (1,'','','Коллектив авторов',…)`) | Author name dictionary → `mlauthorname` |
| `lib.libbook.sql` | `libbook` | `BookId` AUTO_INCREMENT (seq ≈ 887,686), `md5 binary(32)` UNIQUE; **no filename column** | Book core → `mlbook` (minus filename) |
| `lib.libfilename.sql` | `libfilename` | `BookId` PK + `FileName` (transliterated, latin1) | Separate filename lookup → `mlbook.filename` |
| `lib.libgenre.sql` | `libgenre` | `Id` AUTO_INCREMENT (≈1.7M) + `(BookId, GenreId)` UNIQUE | Book ↔ genre join → `mlgenre` |
| `lib.libgenrelist.sql` | `libgenrelist` | `GenreId` AUTO_INCREMENT, PK `(GenreId, GenreCode)`, UNIQUE `GenreCode` | Genre dictionary → `mlgenrename` |
| `lib.libjoinedbooks.sql` | `libjoinedbooks` | `Id` AUTO_INCREMENT | **Merge redirects** (`BadId` → `GoodId`); not needed for a personal copy |
| `lib.librate.sql` | `librate` | `ID` AUTO_INCREMENT (≈2.9M), `BookId`, `UserId`, `Rate` | **Per-user** ratings → aggregated into `mlrating` |
| `lib.librecs.sql` | `librecs` | — (recommendations uid → bid) | Not needed |
| `lib.libseq.sql` | `libseq` | `(BookId, SeqId)` composite PK | Book ↔ series join → `mlseq` |
| `lib.libseqname.sql` | `libseqname` | `SeqId` AUTO_INCREMENT, `SeqName` UNIQUE | Series dictionary → `mlseqname` |
| `lib.libtranslator.sql` | `libtranslator` | `(BookId, TranslatorId)` composite PK | Translators; no `ml*` counterpart in the 9 managed tables |

### 5.2 Load order

The ingest pipeline loads the dumps in this exact order (it matters only
for MyISAM table creation, not for FK correctness — the loader relies on
`FOREIGN_KEY_CHECKS=0`):

```
lib.libavtor → lib.libavtorname → lib.libbook → lib.libfilename →
lib.libgenre → lib.libgenrelist → lib.libjoinedbooks → lib.librate →
lib.librecs → lib.libseq → lib.libseqname → lib.libtranslator
```

Note the order is **not** dependency-ordered (`libavtor` references
`AvtorId` before `libavtorname` exists) — it works because MyISAM does
not enforce FKs. The `ml*` schema the app reads is strictly
dependency-ordered instead.

### 5.3 Where the lib\* tables go

After a full ingest run, `flibusta` contains **only the 17 `ml*`
tables** — the `lib*` staging tables are consumed and dropped: the
convert stage (`lib.convert.sql`) rebuilds the `ml*` catalog from them,
and the cleanup stage drops `librating`, `librate`, `libjoinedbooks`,
`librecs`, `libtranslator`. Verified 2026-09-04: the inventory shows no
`lib*` table remaining. This is also why re-aggregating `mlrating` from
`librate` is no longer possible — the aggregate in `mlrating` is the
authoritative source (see [6.3](#63-mlrating-per-user-librate--per-book-aggregate)).

---

## 6. Loading and update logic

### 6.1 BookTracker-import pipeline

The catalog is refreshed from the Flibusta tracker by the
`BookTracker-import` project (`bin/booktracker-import.sh` →
`bin/booktracker-extract.sh` → `bin/booktracker-ingest.sh`,
orchestrated by `bin/booktracker-sync.sh`):

```
booktracker-import.sh   fetch .torrent files (INPX, dumps, monthly archives)
        │
booktracker-extract.sh  aria2c download + decompress .sql.gz → mysql_feeds/
        │
booktracker-ingest.sh   load .sql files into the flibusta database (6 stages)
```

* `import` — downloads the small `.torrent` files from booktracker.org
  into `torrents/`.
* `extract` — downloads the payloads (`.sql.gz` dumps → `mysql_feeds/`
  as plain `.sql`; `.inpx` files → `inpx/`; monthly book archives →
  `book_archives/`).
* `ingest` — runs the six database stages below.

### 6.2 The six ingest stages

`bin/booktracker-ingest.sh` tracks each stage in a state file, so a
re-run skips completed stages (`--force` re-runs them):

| # | Stage | What runs | Result |
|---|---|---|---|
| 1 | `load` | Load the 12 `lib.*.sql` dumps in [5.2](#52-load-order) order | Raw `lib*` tables present |
| 2 | `convert` | `sql/lib.convert.sql` | `lib*` → `ml*` catalog rebuild (drops the consumed `lib*` tables) |
| 3 | `base` | `sql/createtable.sql` | Base tables (`mlactual`, `mldownloaddata`, …) |
| 4 | `rating` | `sql/Flibusta_Load_mlrating.sql` | `mlrating` from `librate` (see below) |
| 5 | `check` | Row-count verification | `mlbook=869130 mlrating=361761` etc. |
| 6 | `cleanup` | `DROP` leftover tables | Drops `librating librate libjoinedbooks librecs libtranslator` |

The whole ingest is wrapped in a MariaDB lifecycle: the server is
started (elevated PowerShell, no UAC when WSL2 is elevated), used, then
gracefully shut down (`SHUTDOWN`, falling back to `taskkill /F`).

### 6.3 mlrating: per-user librate → per-book aggregate

`BookTracker-import/sql/Flibusta_Load_mlrating.sql`:

1. Creates an intermediate `librating` table (`rt_id` auto-inc,
   `bookid`, `rating` CHAR(1)) and fills it with
   `INSERT IGNORE … SELECT 0, BookId, ROUND(AVG(CONVERT(Rate, UNSIGNED)))
   FROM librate GROUP BY bookid` — i.e. **one row per bookid**, the
   rounded mean of all user ratings.
2. Creates `mlrating` (same shape, MyISAM `ROW_FORMAT=FIXED`, indexes on
   `bookid` and `rating`) and copies `librating` into it.

`librate` is per-**user**; `mlrating` is per-**book**. The cleanup stage
drops `librate`, so `mlrating` is the only rating source that survives.
The personal-library populate tool copies the books' rows straight from
`flibusta.mlrating` — identical semantics without re-aggregation.

### 6.4 MultiLib_Utilities tools

All tools share the same connection contract ([8.1](#81-connection-contract))
and MariaDB lifecycle (`lib/mariadb_lifecycle.sh`), and none of them
writes `flibusta`:

| Tool | Database reads | Writes | Purpose |
|---|---|---|---|
| `bin/export_authors_from_db.sh` | `mlauthorname` (via `data/sql/qry_*.sql`) | none | Regenerate the author-list fixture from the catalog |
| `bin/reconcile_library.sh` | `mlauthorname` snapshot | none | Collection progress: disk `Books` folders vs recommended-author list |
| `bin/estimate_download_size.sh` | `mlbook.filesize` per author | none | Size the next to-collect round |
| `bin/backup_privetelib.sh` | — | mysqldump of `privetelib` | Safety net: backup / verify / restore / list |
| `bin/populate_privetelib.sh` | `flibusta.mlbook` (md5 map + catalog rows), `mlauthor`, `mlauthorname`, `mlgenre`, `mlgenrename`, `mlseq`, `mlseqname`, `mlrating`, `mlcustinfo` | `privetelib` managed tables (fresh keys) | Rebuild the personal library from the `Books` folder |

**populate_privetelib.sh data flow** (v1.1.0, fresh keys):

```
Books folder ──walk──▶ hash each file (zip → decompressed FB2 md5;
                       loose .fb2 → file md5) + arcname + size
        │
flibusta.mlbook ──one read──▶ (md5, bookid) map (869k rows, joined locally)
        │
resolve: file md5 → bookid (duplicates → lowest bookid)
        │
flibusta (chunked reads, POP_CHUNK=500) ──▶ one SQL script, one session:
        │     TRUNCATE the 9 managed tables
        │     INSERT mlauthorname  (fresh @aid_* per author)
        │     INSERT mlgenrename   (fresh @gid_*; ancestor categories pulled
        │                           in, parent remap, parent-first)
        │     INSERT mlseqname     (fresh @sid_* per series)
        │     INSERT mlbook        (fresh @bid_*; catalog filename,
        │                           on-disk arcname/filesize)
        │     INSERT mlauthor / mlgenre / mlseq     (reference captured vars)
        │     INSERT mlrating / mlcustinfo          (reference captured vars)
        ▼
privetelib rebuilt — only books on disk; flibusta never written
```

### 6.5 Data flow end to end

```
Flibusta tracker torrents
   │  (booktracker-import.sh)
   ▼
torrents/ → (booktracker-extract.sh, aria2c) → mysql_feeds/*.sql
   │  (booktracker-ingest.sh)
   ▼
flibusta (17 ml* tables: 869k books, 1.07M author links, 361k ratings…)
   │
   ├── export_authors_from_db.sh ──▶ author list fixture (5707 / 13396 names)
   ├── estimate_download_size.sh ──▶ to-collect round sizing
   │
   └── populate_privetelib.sh (md5 match against mlbook.md5)
         │
         ▼
privetelib (the personal library the MultiLib app opens)
   │
   └── reconcile_library.sh ──▶ collection-progress report vs the Books folder
```

---

## 7. Key findings and implementation details

### 7.1 md5 matching: the strongest lookup tier

* `mlbook.md5` is **100% populated** — 869,130 / 869,130 rows.
* It hashes the **decompressed FB2 content**: `zcat file.zip | md5sum`
  equals `unzip -p file.zip | md5sum`, and both resolve to exactly one
  bookid; a loose `.fb2` file's plain md5 also resolves.
* The column has a **non-unique index** (`md5`), but the populate tool
  still pulls the whole `(md5, bookid)` map once and joins locally —
  one query instead of 2,156 per-file lookups, and it reveals duplicate
  md5s (same book stored twice in the catalog).
* Result on the real collection: **2,148 / 2,156 files (99.6%)**
  resolved exactly — vs 96.2% for the previous author/series/title
  ladder. The 8 unmatched files were content-level mismatches (7
  Bушков «Пиранья» volumes + 1 Bulychev — a different edition/
  normalization in the catalog).

### 7.2 filename / arcname are not archive names

* `mlbook.filename` is **transliterated** librusec-style
  (`Aarh_Andrej_Aida`), and `mlbook.arcname` is **0% populated** — you
  cannot match on-disk archive names against them.
* The on-disk filenames in the monthly archives are
  `series-number + title` (e.g. `01-Первое дело.zip`, `0Мироходец.zip`);
  a title-fallback matcher should strip `^[0-9]+[ -]*` before comparing
  to `mlbook.title`.
* `libfilename` (the source table) is the transliteration lookup —
  a separate side table, not part of `mlbook`.
* In `privetelib`, the populate tool deliberately **overwrites** these
  with the real relative path and zip member name so the app can open
  the files.

### 7.3 Covers and descriptions are empty

`mlcoverpage` and `mldescription` are both empty (0 rows) in the loaded
`flibusta` — covers/descriptions require the separate **extended-data
torrents**, which the pipeline does not load. Real enrichment in the
loaded catalog: ratings (361,761), series (80,744 names), genres (296),
`mlcustinfo` (163,161). Loading the extended torrents and re-running
the populate tool would populate them automatically (they are in the
managed set once populated).

### 7.4 Duplicate md5s and multi-author books

* **Duplicate md5s:** the catalog can hold the same book content under
  several bookids. The populate tool keeps the **lowest** bookid and
  counts the collisions.
* **Multi-author books:** `mlauthor` holds one row per (book, author) —
  every sampled book had exactly 2 authors. Author counts therefore
  exceed book counts (1,073,467 links for 869,130 books).

### 7.5 Charset: pinning the client

The Windows server may transcode to its own default charset (cp1251)
if the client does not pin it. Every tool sends
`--default-character-set=utf8 --init-command="SET NAMES utf8"` so the
Cyrillic payloads round-trip as UTF-8. Raw reads use
`-B --skip-column-names --raw`; `mysql -B` renders SQL `NULL` as the
literal text `NULL` (the populate generator relies on this).

### 7.6 WSL2 ↔ Windows MariaDB lifecycle

* Server: `C:\mariadb-10.4.7-winx64\bin\mysqld.exe --console`, started
  elevated via PowerShell `Start-Process … -Verb RunAs` (no UAC prompt
  when WSL2 runs elevated).
* **WSL2 mirrored-networking quirk:** a `mysql` connect to
  `127.0.0.1:3306` can block indefinitely instead of failing fast —
  every probe/connect is bounded with `--connect-timeout` (and
  `timeout` for tools whose clients don't accept that flag, e.g.
  `mysqldump` in 10.4).
* The shared `lib/mariadb_lifecycle.sh` provides
  `mariadb_maybe_start` / `mariadb_stop_if_started`: a server that was
  already running is left untouched; one the tool started is shut down
  gracefully on exit (`SHUTDOWN`, then `taskkill /F` fallback after
  `MARIA_STOP_TIMEOUT`).
* After several start/stop cycles the `--console` instance can keep
  running but stop answering (the user's "minimized window, still
  working" quirk); fix is `taskkill /F /IM mysqld.exe` and a fresh
  start, possibly with `MARIA_START_TIMEOUT=120` for MyISAM recovery.

### 7.7 The mysql_upgrade incident

After the first dump load, the server logged:
`Column count of mysql.proc is wrong. Expected 21, found 20. Created
with MariaDB 50150, now running 100407` — the portable data directory
predated the 10.4 server. `mysql_upgrade --force` (an ingest `--upgrade`
mode) repaired it (all `mysql.*` and `flibusta.*` tables checked OK,
`FLUSH PRIVILEGES` completed).

### 7.8 MyISAM crash and recovery

* After an unclean shutdown MyISAM tables are marked crashed
  (`'.\flibusta\mlauthor' is marked as crashed and should be repaired`)
  — the server auto-checks them; `mysql_upgrade`/`REPAIR TABLE` clears
  the flags.
* `privetelib.mlcustinfo.frm` was once corrupt (error 1033 on LOCK
  TABLES); repaired by recreating the empty table from the valid schema:
  `CREATE TABLE privetelib.mlcustinfo LIKE flibusta.mlcustinfo`.
  The backup tool now makes such repairs safe.

---

## 8. Connection contract and invariants

### 8.1 Connection contract

The exact client invocation every tool builds (password only via
`MYSQL_PWD`, never on the command line):

```
mysql -h 127.0.0.1 --protocol=TCP -P 3306 -u root \
      --default-character-set=utf8 \
      --init-command="SET NAMES utf8" \
      --connect-timeout=<10> \
      -B --skip-column-names --raw   # for reads
```

Env contract: `MYSQL_CLIENT`, `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`,
`MYSQL_PASSWORD` (→ `MYSQL_PWD`), `MYSQL_EXTRA_ARGS`,
`MYSQL_CONNECT_TIMEOUT`, `MARIA_*` (lifecycle: `MARIA_EXE`,
`MARIA_BIN_DIR`, `MARIA_START_TIMEOUT`, `MARIA_READY_TIMEOUT`,
`MARIA_STOP_TIMEOUT`).

### 8.2 Invariants

1. **`flibusta` and `mllbr_main` are never written** by MultiLib_Utilities.
2. The tools manage **only** the catalog tables they populate in
   `privetelib`; app-owned tables (`mlactual`, `mldownloaddata`,
   `mlnews*`, `mluser*`) are never touched.
3. Population is a **clean rebuild**: managed tables are
   `TRUNCATE`-and-reloaded per run — idempotent by construction.
4. **Keys are regenerated** per run in `privetelib`; flibusta ids are
   used only as the lookup source during the walk.
5. A column-parity mismatch on **any** managed table aborts the run
   before any `TRUNCATE` (all-or-nothing — a partial rebuild would leave
   dangling key references).
6. Every tool writes a per-run TSV report to its report dir
   (`/mnt/c/Backup_Go7/merge-reports/` by default).
7. Take a `backup_privetelib.sh` backup before re-populating a
   non-empty `privetelib` (restore is safe: it backs up first and
   refuses non-empty overwrites without `--force`).

---

## 9. Appendix: snapshots

### 9.1 Row counts

Taken 2026-09-04 (information_schema `TABLE_ROWS`; MyISAM counts are
engine-accurate).

**flibusta (catalog):**

| Table | Rows |
|---|---|
| mlbook | 869,130 |
| mlauthor | 1,073,467 |
| mlgenre | 1,374,515 |
| mlseq | 446,629 |
| mlrating | 361,761 |
| mlcustinfo | 163,161 |
| mlauthorname | 216,491 |
| mlseqname | 80,744 |
| mlgenrename | 296 |
| mlcoverpage / mldescription / mlactual / mldownloaddata / mlnews / mlnewsname / mluserkeyword / mluserprim | 0 |

**privetelib (personal library, after the v1.0.0 populate — stale, v1.1.0
rebuild pending):** mlbook 2,138 · mlauthor 2,798 · mlgenre 5,468 ·
mlseq 2,619 · mlrating 1,948 · mlcustinfo 757 · mlauthorname 216,491
(the v1.0.0 whole-table copy) · mlseqname 80,744 · mlgenrename 296.

**mllbr_main (app's own):** mlgenrelist 109 · mlgroupname 3 ·
mldownload 0 · mlgroup 0.

### 9.2 mlrating distribution

| rating | books |
|---|---|
| 1 | 67,067 |
| 2 | 57,001 |
| 3 | 79,368 |
| 4 | 82,584 |
| 5 | 75,741 |
| **total (distinct bookids)** | **361,761** |

### 9.3 Index inventory (mlbook)

| Index | Columns |
|---|---|
| PRIMARY | bookid |
| deleted | deleted |
| ext | ext |
| filename | filename |
| lang | lang |
| md5 | md5 (non-unique) |

---

*End of reference. Keep this document in sync with the tools and the
live schema — the populate tool's parity check re-verifies the 9 managed
tables on every run.*