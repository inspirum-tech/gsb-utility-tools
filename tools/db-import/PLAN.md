# db-import: plan

Status: **Plan signed off by the user (2026-11-12). Code written on branch `feature/db-import`; tested only for logic so far (see docs/EVIDENCE.md). Dev-server tests are the next step.**

## Progress log

| Phase | Status |
|---|---|
| 1 Sign-off | ✅ done 2026-11-12 (all parking-lot items answered) |
| 2 Postgres -> Postgres path + config + report | ✅ done, tested on dev (docs/EVIDENCE.md sections 4 and 5) |
| 3 Test on dev (scratch schema, before/after evidence) | ✅ done: 44 / 44 scratch checks and a real-data run (80445 rows) |
| 4 DuckDB paths | ✅ DuckLake -> Postgres and DuckDB file -> DuckDB file tested on real data (40921 rows); DuckLake target and parquet source not yet run |
| 5 `prepare-bundle.sh` + offline test | ✅ bundle built on dev and used by the run; ⏳ not tested on a machine with no network |
| 6 README + RUNBOOK, UAT/prod checklist | ✅ README and RUNBOOK.md written (2026-11-12); the runbook has not been followed by someone else yet |

### 2026-11-12 ✅ code written
- Branch `feature/db-import` created from the current HEAD (not from `main`, so the pivot-compare files stay in the working tree). Nothing committed.
- Files: `db-import.sh`, `prepare-bundle.sh`, `config.example.env`, `README.md`, `tests/test_functions.sh`, `tests/dev_scratch_test.sh`, `.gitignore`.
- Decision: the SQL for a table is built as one script and runs in one transaction; the row-count check and `ROLLBACK` on mismatch are inside it. Reason: a half-copied table must never be left behind.
- Decision: Postgres -> Postgres streams with `\copy ... FROM PROGRAM 'psql <source> -f <file>'` (csv format). Reason: one target transaction, no CSV file on disk, NULL and empty string stay different.
- Decision: passwords only through environment variables named in the config (`*_PASSWORD_ENV`) or `~/.pgpass`; DuckDB gets the SQL (with the password) through stdin, never as a file or argument.
- Mistakes caught by the logic tests and fixed: see docs/EVIDENCE.md section 2.
- **Next action:** upload the folder to the dev server, run `tests/dev_scratch_test.sh`, paste the output.

## Goal

One config-driven script that copies tables (one time period) from a source database to a target
database. Source and target can be any environment (dev, uat, prod) and either Postgres or DuckDB
(DuckDB file, DuckLake, parquet). Same command every time; only the config changes. Works on UAT and
prod, which have **no internet**. Fully standalone: shares no file with the other tools.

### Worked example (prod Postgres -> uat Postgres)

```
./db-import.sh configs/prod_to_uat.env           # real run
./db-import.sh --dry-run configs/prod_to_uat.env # does everything, then ROLLBACK
```

| | Before | After |
|---|---|---|
| source `gsb_data_prd."KPI_CALCULATED_LTE"` rows with `START_TIME` in 2026-11-01..2026-11-02 | 120 | 120 (never changed) |
| target same table, same window | 100 | 120 (the 100 old rows removed, 120 inserted, one transaction) |
| target backup `import_backup."KPI_CALCULATED_LTE_bak_20261112_101500"` | none | 100 rows (the rows that were replaced) |

## Agreed scope (decisions)

| Question | Decision | Source |
|---|---|---|
| One script or two? | One script. `SOURCE_TYPE` / `TARGET_TYPE` in the config choose the engine. | user |
| Engines | Postgres and DuckDB (file, DuckLake, parquet), any combination | user |
| Postgres -> Postgres | `psql` only (bash + psql, same as counter-def-to-v2-migration, known to run on UAT) | agreed |
| Anything with DuckDB | DuckDB CLI, extensions loaded only from a local `bundle/` folder, never downloaded | agreed |
| Standalone | Imports nothing from other tools. Own config, own README, own helper scripts | user |
| Rows already in target for the period | **Replace the period** (delete window + insert, one transaction). `LOAD_MODE=replace` default; `append` and `stop` also available | user (option A) |
| Table with no time column | Only if listed in `FULL_COPY_TABLES`. Wiped and reloaded in one transaction with a backup. Not listed = script stops | user (option A). User says all tables have a time column, so this list is normally empty |
| Time column name | `TIME_COLUMN` default for all tables, `TABLE_TIME_COLUMNS=TABLE:COLUMN,...` for exceptions | Verified on dev (parking lot P1): all 24 `KPI_NS_QRLY_*_ERS_P` tables use `PERIOD_START_TIME`, type `timestamp without time zone`. Default is that; overrides only for other table families |
| Offline | `prepare-bundle.sh` run once on dev (has internet) builds `bundle/` + `.sha256`; copied to UAT/prod with the tool. UAT/prod have the same Postgres and DuckDB as dev (user) | user + dedup project pattern |
| Passwords | Never in config or logs. Config names an env var (`SOURCE_PASSWORD_ENV=...`) or `~/.pgpass` is used | CLAUDE.md |
| Backup of replaced rows | Config switch `BACKUP=on|off`, default `on`: backup table in the target DB (`BACKUP_SCHEMA`, default `import_backup`). `off` = no backup and a printed warning. Stops before writing if `on` and the table cannot be created | user (parking lot P2) |
| Never commit | I do not commit | CLAUDE.md |

## What I verified from the repo

| Claim | Result | Where |
|---|---|---|
| counter-def tool runs on UAT with only bash + psql | Confirmed by its README ("No internet and nothing else is needed") | `counter-def-to-v2-migration/README.md:72` |
| parser-trigger needs a pip package | Confirmed (`nats-py==2.10.0`), so not safe to assume on UAT | `parser-trigger/README.md` |
| Offline pattern of the dedup project | Build on dev, prefetch DuckDB extensions (ducklake, postgres, parquet, json, icu), fail the build if any is missing, ship with `.sha256`, verify on the far side | `gsb-dedup-service-component/docker/Dockerfile`, `save-image.sh`, `load-image.sh` (read only, not changed) |
| Extension files only work with the DuckDB version that fetched them | Stated in the dedup Dockerfile; so the bundle records the DuckDB version and the script checks it | same |
| Your manual import (psql `\copy` from CSV) | Seen in `IMPORT TABLES TO DEV DB 1.txt`; the new tool replaces it | repo root |
| psql, duckdb on this PC | **Not installed here**, so real tests run on the dev server | checked with `which` |

## How it works

### Postgres -> Postgres (psql only, no CSV file, one transaction on the target)

```
BEGIN;
-- 1. backup rows about to be replaced
CREATE TABLE import_backup."T_bak_<ts>" AS SELECT * FROM target.T WHERE <time col> in window;
-- 2. delete the window
DELETE FROM target.T WHERE <time col> >= :from AND <time col> < :to;
-- 3. stream the source rows straight in (psql on the source runs as a program of the target psql)
\copy target.T (<common columns>) FROM PROGRAM 'psql <source> -c "\copy (SELECT <cols> FROM T WHERE window) TO STDOUT"'
-- 4. check: rows inserted = rows counted in the source for the same window, else ROLLBACK
COMMIT;   -- (or ROLLBACK when --dry-run or any check fails)
```

### Anything with DuckDB

The same steps through the DuckDB CLI: `extension_directory` = `bundle/extensions`, auto-install and
auto-load switched off, `ATTACH` the source and target (postgres, ducklake or a DuckDB file), then
`BEGIN; backup; DELETE; INSERT ... SELECT; checks; COMMIT`. A parquet source is read with `read_parquet`.

### Safety checks (run before any write, in this order)

1. Config complete, no password in it, `TIME_COLUMN` exists on both sides.
2. Source and target are not the same table in the same database.
3. Target table exists (the script never creates it). Every source column is in the target (else stop; extra target columns are filled by their defaults and listed in the report).
4. Offline: the bundle exists, its checksum matches, its DuckDB version matches the DuckDB used (only when DuckDB is involved).
5. Print a one-line summary of source -> target and the window, and for `prod` as the target require `--yes` or typing the target database name.
6. Counts before (source window, target window), then after, written to the report.

## Files (all inside `tools/db-import/`)

| File | Purpose |
|---|---|
| `db-import.sh` | The script |
| `config.example.env` | Documented template, copied per job |
| `configs/` | One config per job (gitignored when it holds hosts you do not want pushed; decide at sign-off) |
| `prepare-bundle.sh` | Run once on dev: builds `bundle/` (extensions, DuckDB version file) and `.sha256` |
| `README.md` | Usage and offline steps |
| `RUNBOOK.md` | Step-by-step for UAT/prod, one command at a time |
| `PLAN.md`, `parking-lot.md`, `docs/` | Tracking and evidence |
| `tests/` | Throwaway test schema scripts (scratch objects only) |

## Phases

| # | Phase | Blocked by |
|---|---|---|
| 1 | Sign off this plan | you |
| 2 | Postgres -> Postgres path + config + report | 1 |
| 3 | Test on dev server with a scratch schema (before/after evidence) | 2, dev access |
| 4 | DuckDB paths (duckdb file, DuckLake, parquet) | 3 |
| 5 | `prepare-bundle.sh` + offline test (run with `--network`-less check: delete `~/.duckdb`, run, must still work) | 4 |
| 6 | README + RUNBOOK, UAT/prod checklist | 5 |

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Wrong target (prod) overwritten | High | backup of replaced rows, dry-run, `--yes`/typed confirmation for prod, summary line before the write |
| Partial copy leaves target half-changed | High | single transaction, row-count check inside it, ROLLBACK on mismatch |
| Backup table needs create-rights in a scratch schema | Medium | `BACKUP_SCHEMA` in config; if it cannot be created the script stops before writing (parking lot P2) |
| Time zone: window edges land on the wrong day when the column is `timestamptz` | Medium | session `TimeZone` set from config (default UTC) on both sides, window is `>= from AND < to` |
| `numeric` / type differences between Postgres and DuckDB | Medium | cast to text on the source side where the types differ (CLAUDE.md lesson); verified with a test table |
| Extension/DuckDB version mismatch offline | Medium | bundle records the version, script checks it before running |
| CRLF line endings after upload | Low | script checks itself and prints the `dos2unix` fix |
| Large tables, long runtime | Medium | streaming (no temp file); report shows elapsed time. Per-day chunking can be added later |

## Open items

See `parking-lot.md`. Each has a fallback so nothing blocks the work.

### 2026-11-12 ✅ tested on dev
- Postgres -> Postgres with real data (NODE_CEM, 80445 rows) and DuckLake -> Postgres with real data (40921 rows) both verified row for row / by sums; dry-run rollback verified on both engines; 44 / 44 scratch checks.
- ❌ -> ✅ DuckDB `-csv` quoted lines containing a comma, so the column list was not read ("has no columns"). Changed to `-list` mode. No data was touched by the failed run (it stopped in the read-only preflight).
- 📝 Decision (new, from real data): added `TIMEZONE` (default UTC). DuckLake `PERIOD_START_TIME` is `timestamptz` (Sydney, +11), the Postgres OLD column is a plain `timestamp`. Without it a "2026-10-25" window meant midnight UTC = 11:00 Sydney and the copied values shifted by 11 hours. Applied to both engines; verified: first imported time is 2026-10-25 00:00:00.
- 📝 Test-only mistake found and fixed: a wrong expectation in `dev_scratch_test.sh` (counted the whole table); not a script bug.
- 📝 Correction to my notes: the DuckLake NEW schema is `gsb_data_kpi_pivot_dev_V2`, not `..._dev`.
- Scratch objects still on dev (all ours): schemas `dbimport_demo`, `dbimport_demo_bak`; files in `/tmp/dbimport_reports*`. Removal needs the user's OK (CLAUDE.md).
- **Next action:** remove the scratch objects (with OK), write RUNBOOK.md for uat / prod, then the user decides whether to test DuckDB-file / DuckLake-target / parquet.

