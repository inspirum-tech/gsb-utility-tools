# db-import: evidence

Environment of the tests below: Windows 11, Git Bash, GNU bash 5.2.37 (msys). **No psql, no DuckDB, no database on this PC.**
Dev server (for the later tests): bash 5.1.8, psql 18.1, DuckDB v1.5.5 (Variegata) d8cdaa33fd.

## Summary

| Claim | Verdict |
|---|---|
| Script and helper scripts have valid bash syntax | ✅ confirmed (`bash -n`) |
| Pure logic: period parsing, quoting, table list, config rules, generated SQL (Postgres engine and DuckDB engine) | ✅ 57 / 57 checks pass |
| Bad config is refused before any connection, nothing written | ✅ confirmed for 5 cases |
| Postgres -> Postgres import on real data (80445 rows: replace, backup, dry-run rollback, row-for-row equal to source) | ✅ confirmed on dev, section 4 |
| Repeat run, failure rollback, NULL / empty / special characters, window edge, stop / append, FULL_COPY_TABLES, SOURCE=TARGET mapping | ✅ 44 / 44 checks pass on dev (section 5) |
| `--check` / `--dry-run` change nothing | ✅ confirmed on dev, section 4 |
| DuckLake -> Postgres on real data (40921 rows, Sydney time zone, replace, backup, dry-run rollback, sums equal to source) | ✅ confirmed on dev, section 6 |
| DuckDB file -> DuckDB file on real data (40921 rows, Sydney time zone, replace, backup, dry-run rollback, row for row equal) | ✅ confirmed on dev, section 7 |
| DuckLake as target, parquet source | ⏳ untested (code written; same code path as above except the ATTACH / read_parquet line) |
| `ON_ERROR=continue`, the interactive prod confirmation | ⏳ untested |
| Offline bundle: built on dev, its self-check loads every extension with an empty HOME and auto-download off; db-import then ran from `bundle/` only | ✅ confirmed on dev (section 6). Not tested: a server that really has no network, and a copy of the bundle on another machine |
| Behaviour on uat / prod | ⏳ untestable by us (no access); same software as dev per the user |

## 1. Syntax

Command: `bash -n db-import.sh && bash -n prepare-bundle.sh && bash -n tests/dev_scratch_test.sh`
Output: `ALL_SYNTAX_OK`. Line endings: `grep -c $'\r'` printed 0 for every file. Verdict ✅

## 2. Logic tests

Command: `bash tests/test_functions.sh`
Output (last line): `passed: 57   failed: 0`. Verdict ✅

Bugs this test found and that were fixed before this result (kept for the record):
- `libpq_val` doubled a backslash differently on bash 5.2 than expected; replaced the `${s//x/y}` form with `sed`
  (dev has bash 5.1: a backslash in that replacement is not portable between versions).
- `build_duck_sql` used `$i` in the same `local` line that sets it (unbound variable).
- One test expectation was wrong (SQL-level quote doubling of a password); the generated text was correct:
  `ATTACH 'ducklake:postgres:dbname=ducklake host=h port=5432 user=u password=''p\''w d''' AS src (DATA_PATH '/d', METADATA_SCHEMA 'metadata', READ_ONLY);`
  for the password `p'w d`.

## 3. Refusals before connecting (nothing written)

| Case | Output | Exit |
|---|---|---|
| password variable not exported | `ERROR: SOURCE_PASSWORD_ENV=SOURCE_PGPASSWORD, but the environment variable SOURCE_PGPASSWORD is empty or not exported` | 2 |
| `PERIOD_FROM=01/11/2026` | `ERROR: PERIOD_FROM '01/11/2026' is not valid. Use YYYY-MM-DD or YYYY-MM-DD HH:MM[:SS]` | 2 |
| `PERIOD_TO` earlier than `PERIOD_FROM` | `ERROR: PERIOD_FROM (2026-11-01 00:00:00) must be earlier than PERIOD_TO (2026-10-01 00:00:00)` | 2 |
| source and target the same table | `ERROR: source and target are the same table (...). Check SOURCE_* / TARGET_*` | 2 |
| `TARGET_ENV="staging"` | `ERROR: TARGET_ENV must be dev, uat or prod (...)` | 2 |
| valid config, but no `psql` on this PC | `ERROR: psql not found` (after validation, before any connection) | 2 |

Verdict ✅. A throwaway `reports/` folder created by the last case was deleted.

## 4. Dev server, real data, Postgres -> Postgres (2026-11-12)

Environment: dev server, bash 5.1.8, psql 18.1, database `gsb`, run as `sudo -u postgres` (local socket, no password).
Source (read only): `gsb_data_kpi_pivot."KPI_NS_QRLY_NODE_CEM_ERS_P"` (partitioned table, real OLD data).
Target (scratch, created for this test): `dbimport_demo."KPI_NS_QRLY_NODE_CEM_ERS_P"`, same columns. Backup schema: `dbimport_demo_bak`.
Config: `configs/demo_pg.env`, period `2026-10-25` up to `2026-10-25 02:00`, `LOAD_MODE=replace`, `BACKUP=on`.

BEFORE (query: hourly counts of the target):
```
 2026-10-25 01:00:00 |    5 | 2000-01-01 00:00:00     (5 "old" rows inside the window, marked)
 2026-10-25 03:00:00 |    5 | 2000-01-01 00:00:00     (5 rows outside the window, must survive)
```
Source rows in the window, from the hourly counts: 40221 + 40224 = 80445.

| Step | Command | Output (verbatim, shortened) | Verdict |
|---|---|---|---|
| `--check` | `sudo -u postgres bash db-import.sh --check configs/demo_pg.env` | `1 KPI_NS_QRLY_NODE_CEM_ERS_P ... window 80445 5 KPI_NS_QRLY_NODE_CEM_ERS_P_bak_20261112_230041` then `check only: nothing was changed` | ✅ source count equals the hand-calculated 80445 |
| `--dry-run` | `... --dry-run configs/demo_pg.env` | `DRY-RUN OK (rolled back): target rows in the period 5 -> 80445 (source 80445), backup rows 5, 0s` | ✅ |
| after the dry run | hourly count query + `count(*)` of schema `dbimport_demo_bak` | same two rows as BEFORE (5 / 5, both marked 2000-01-01); `backup_schemas_left 0` | ✅ the rollback left nothing behind |
| real run | `... configs/demo_pg.env` | `OK: target rows in the period 5 -> 80445 (source 80445), backup rows 5, 0s` and `finished: all tables OK` | ✅ |

AFTER (same hourly query):
```
 2026-10-25 00:00:00 | 40221 | 2026-10-25 13:13:40.91
 2026-10-25 01:00:00 | 40224 | 2026-10-25 13:30:56.669
 2026-10-25 03:00:00 |     5 | 2000-01-01 00:00:00
```
Data check (EXCEPT in both directions over the window): `in_source_not_target 0`, `in_target_not_source 0`.
Backup: one table `KPI_NS_QRLY_NODE_CEM_ERS_P_bak_20261112_230154` with 5 rows.

Verdict ✅: the 5 old in-window rows were replaced (marker gone), the 5 rows outside the window survived, the 80445 rows equal the source,
the replaced rows are in the backup, and a dry run changes nothing.

Not covered by this run (covered by `tests/dev_scratch_test.sh`, run next): repeat run (no duplicates), `BACKUP=off`, a failing import rolled back,
NULL / empty string / quotes and commas in text, a row exactly at `PERIOD_TO`, `LOAD_MODE=stop` / `append`, refusals.

## 5. Dev server, scratch tests (2026-11-12): `tests/dev_scratch_test.sh`

Command: `sudo -u postgres env TEST_HOST= TEST_PORT= bash tests/dev_scratch_test.sh 2>&1 | tee docs/dev_test_output.txt`
Output: `docs/dev_test_output.txt` on the dev server (complete, verbatim). Last line: `passed: 44   failed: 0`.

First run was `passed: 35 failed: 1`. The one failure ("target-only column gets its default": expected 4, got 5) was a **mistake in the test, not in the script**: it counted
the whole target table, and the row from before the window (ID 91) also has `EXTRA='x'`. The test now counts only the window rows; the second run passes.

| Section | Result |
|---|---|
| A `--check`, B `--dry-run` (nothing changed, backup table rolled back too) | ✅ |
| C real run: window replaced, row before the window survived, row exactly at `PERIOD_TO` not imported, NULL stays NULL, empty string stays empty, comma / quote / apostrophe text exact, target-only column gets its default, backup holds the 3 replaced rows | ✅ |
| D repeat run: still 4 rows in the window (no duplicates), second backup table | ✅ |
| E `BACKUP=off`: no new backup table | ✅ |
| F failing import (CHECK constraint on the target): exit 1, target unchanged, kept row still there, no backup left | ✅ |
| G `LOAD_MODE=stop` refuses (exit 2, nothing changed); `append` gives 8 rows | ✅ |
| H missing target table, bad date: exit 2 | ✅ |
| I no time column: refused (exit 2, target unchanged) unless in `FULL_COPY_TABLES`, then the whole table is replaced (3 rows) and the 2 old rows are in the backup | ✅ |
| J `TABLES="T1=T1M"`: target table with another name filled (4 rows) | ✅ |

## 6. Dev server, real data, DuckLake -> Postgres, offline bundle (2026-11-12)

Environment: dev, DuckDB v1.5.5, run as osssupport, DuckDB and extensions from `bundle/` only (`OFFLINE=yes`), target over TCP (192.168.50.218).
Facts found first (read-only): DuckLake catalog `gsb`, schema `gsb_data_kpi_pivot_dev_V2` (not `..._dev`), table `KPI_NS_QRLY_NODE_CEM_ERS_NEW_P`, 8 columns, `PERIOD_START_TIME` and
`UPDATE_TIMESTAMP` are `TIMESTAMP WITH TIME ZONE` (displayed +11). The Postgres OLD tables use plain `timestamp`. So the `TIMEZONE` setting was added.
Source (read only): that DuckLake table. Target (scratch): `dbimport_demo."KPI_NS_QRLY_NODE_CEM_ERS_NEW_P"` with plain `timestamp` columns. Config: `configs/demo_dl.env`,
`TIMEZONE=Australia/Sydney`, period `2026-10-25` up to `2026-10-25 02:00`.

BEFORE: 3 rows: 2 marked "old in window" (00:15, 01:15) and 1 "outside window" (05:00), all `UPDATE_TIMESTAMP = 2000-01-01`.

| Step | Output (verbatim, shortened) | Verdict |
|---|---|---|
| bundle built by `./prepare-bundle.sh` | `DuckDB v1.5.5 ...` `Bundle ready in .../bundle` (duckdb 61.9 MB, ducklake, icu, json, parquet, postgres_scanner, SHA256SUMS, VERSION); its self-check (empty HOME, auto-download off) passed | ✅ |
| first `--check` | `ERROR: source table KPI_NS_QRLY_NODE_CEM_ERS_NEW_P has no columns` | ❌ a bug of mine: DuckDB `-csv` mode quotes a value that contains a comma, so the `SCOL,0,NAME` lines were not recognised. Fixed: `-list` mode. Nothing was changed by it |
| `--check` after the fix | `... window 40921 2 KPI_NS_QRLY_NODE_CEM_ERS_NEW_P_bak_20261112_233646` and `check only: nothing was changed` | ✅ 40921 = 40200 + 721 (the hourly counts of the Sydney window) |
| `--dry-run` | `DRY-RUN OK (rolled back): target rows in the period 2 -> 40921 (source 40921), backup rows 2, 4s` | ✅ |
| after the dry run | 3 rows, first 00:15:00, last 05:00:00, min update_ts 2000-01-01; 0 backup tables left | ✅ rollback left nothing behind |
| real run | `OK: target rows in the period 2 -> 40921 (source 40921), backup rows 2, 4s` and `finished: all tables OK` | ✅ |

AFTER (Postgres target): `rows 40922 | first 2026-10-25 00:00:00 | last 2026-10-25 05:00:00 | marked_rows_left 1 | sum_site_id 24566303209 | sum_k131 10097026145.000`;
the one marked row left is `outside window`; backup table `..._bak_20261112_233802` has 2 rows.
Source (DuckLake, same Sydney window): `rows 40921 | sum_site_id 24566303206 | sum_k131 10097026145.0`.
Compare: 40922 - 1 outside row = 40921 ✅; 24566303209 - 3 (the outside row's SITE_ID) = 24566303206 ✅; sum_k131 equal ✅.
The first imported time is `2026-10-25 00:00:00` (Sydney local), not `2026-10-24 13:00`: the time zone handling is right. ✅

Verdict ✅. Other finding: NEW (40200 + 721 rows) and OLD (40221 + 40224 ...) hold different data for the same day: it is the new calculator's output, not a tool problem.
Problem met on the way (not a tool bug): the report folder `/tmp/dbimport_reports` was created by the `postgres` user in an earlier run, so a run as `osssupport` could not write there; a separate `REPORT_DIR` fixed it.

## 7. Dev server, DuckDB file -> DuckDB file, real data (2026-11-12)

Environment: dev, DuckDB v1.5.5 from `bundle/`, run as osssupport, `OFFLINE=yes`. This case needs no extension at all (`extensions needed:` is empty).
Source: `/tmp/dbimport_duck_test/source.duckdb`, a copy of the real DuckLake table `KPI_NS_QRLY_NODE_CEM_ERS_NEW_P` for 2026-10-25 (40921 rows; read-only copy, DuckLake untouched).
Target: `/tmp/dbimport_duck_test/target.duckdb`, same structure, 3 marked rows: 2 "old in window" (00:15, 01:15), 1 "outside window" (05:00), all `UPDATE_TIMESTAMP = 2000-01-01`.
Config: `configs/demo_dd.env`, `TIMEZONE=Australia/Sydney`, period `2026-10-25` up to `2026-10-25 02:00`.

| Step | Output (verbatim, shortened) | Verdict |
|---|---|---|
| `--check` | `... window 40921 2 KPI_NS_QRLY_NODE_CEM_ERS_NEW_P_bak_20261112_235021` and `check only: nothing was changed` | ✅ |
| `--dry-run` | `DRY-RUN OK (rolled back): target rows in the period 2 -> 40921 (source 40921), backup rows 2, 0s` | ✅ |
| after the dry run (read-only attach) | `rows 3, first 2026-10-25 00:15:00+11, last 2026-10-25 05:00:00+11`, `backup_tables_left 0` | ✅ rollback left nothing behind |
| real run | `OK: target rows in the period 2 -> 40921 (source 40921), backup rows 2, 0s` and `finished: all tables OK` | ✅ |

AFTER: `in_source_not_target 0`, `in_target_not_source 0` (EXCEPT both ways over the window);
`rows 40922 | first 2026-10-25 00:00:00+11 | last 2026-10-25 05:00:00+11 | outside_row_kept 1 | old_rows_left 0`;
backup table `KPI_NS_QRLY_NODE_CEM_ERS_NEW_P_bak_20261112_235141` with 2 rows.
Verdict ✅: old rows replaced, the outside row survived, all 40921 rows equal the source, the replaced rows are in the backup, a dry run changes nothing.

## 8. Still to run

Not tested on a database: DuckLake as a target, a parquet source, `ON_ERROR=continue`, the interactive prod confirmation, and a server that really has no network.
