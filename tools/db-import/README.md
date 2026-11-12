# db-import

One config-driven script that copies tables, for one time period, from a source database to a target
database. Source and target can be any environment (dev, uat, prod) and Postgres or DuckDB. Same command
every time; only the config changes. Works on servers with **no internet**. Standalone: it shares no file
with the other tools in this repository.

Status and decisions: [PLAN.md](PLAN.md), open items: [parking-lot.md](parking-lot.md).

## Quick start

```bash
cp config.example.env configs/prod_to_uat.env      # edit it: hosts, schemas, TABLES, PERIOD_FROM / PERIOD_TO
export SOURCE_PGPASSWORD='...'  TARGET_PGPASSWORD='...'   # the names are set in the config; or use ~/.pgpass

./db-import.sh --check   configs/prod_to_uat.env   # read only: connects, compares columns, counts rows, prints the plan
./db-import.sh --dry-run configs/prod_to_uat.env   # does the whole import in a transaction, runs the checks, ROLLBACK
./db-import.sh           configs/prod_to_uat.env   # real run
```

Example of what a real run does for one table (`LOAD_MODE=replace`, `BACKUP=on`), period 2026-11-01 up to 2026-11-03:

| Step | Rows |
|---|---|
| source `KPI_NS_QRLY_CELL_LTE_ERS_P` with `PERIOD_START_TIME` in the period | 120 |
| target, same period, before | 100 |
| backup `import_backup."KPI_NS_QRLY_CELL_LTE_ERS_P_bak_20261112_101500"` | 100 (the rows that are replaced) |
| target, same period, after (the 100 old rows deleted, 120 inserted) | 120 |

All of it is one transaction per table. The row count is checked inside the transaction; if it does not
match, the table is rolled back and nothing is left behind (not even the backup).

## Which engine runs

| Source -> target | Engine | Needs on the server |
|---|---|---|
| Postgres -> Postgres | `psql` only. The target `psql` runs the source `psql` as a program and streams the rows (csv), no file | bash 4+, psql |
| anything with DuckDB / DuckLake / parquet | the DuckDB CLI, extensions from `bundle/` | bash 4+, `bundle/` (it holds the DuckDB binary) |

You never choose the engine: `SOURCE_TYPE` and `TARGET_TYPE` in the config decide.
Source types: `postgres`, `duckdb` (file), `ducklake`, `parquet`. Target types: `postgres`, `duckdb`, `ducklake`.

## Offline (uat / prod have no internet)

DuckDB extension files only work with the DuckDB version that downloaded them, and uat / prod cannot
download anything, so the extensions travel with the tool. Only needed when DuckDB is involved.

1. On **dev** (has internet), once per DuckDB version: `./prepare-bundle.sh --tar`
   It builds `bundle/` (DuckDB binary, the postgres / ducklake / parquet / json / icu extensions, `VERSION`, `SHA256SUMS`)
   and proves they load with no `~/.duckdb` and auto-download off. `--tar` also writes
   `db-import-bundle-<version>-<date>.tar.gz` and a `.sha256`.
2. Copy the db-import folder (with `bundle/`) to uat / prod.
3. There, `OFFLINE="yes"` (the default) makes DuckDB load extensions **only** from `bundle/`. Before it touches data the
   script checks that the bundle exists, its checksums match (a half-copied bundle is caught) and its DuckDB version matches.
   It never tries to download anything. `OFFLINE="no"` is for dev only.

Postgres -> Postgres needs no bundle.

## Config

Everything is in the config file; [config.example.env](config.example.env) documents every setting. The main ones:

| Setting | Meaning |
|---|---|
| `SOURCE_*`, `TARGET_*` | type, host, port, database, user, schema, and `*_PASSWORD_ENV` (the **name** of an environment variable holding the password; empty = `~/.pgpass`). Never put a password in the file |
| `TARGET_ENV` | `dev`, `uat` or `prod`. For `prod` the script asks you to type the database name (or pass `--yes`) |
| `TABLES` | `A,B` or `SOURCE=TARGET`. Target tables must already exist (the script never creates them) |
| `PERIOD_FROM`, `PERIOD_TO` | `PERIOD_FROM <= TIME_COLUMN < PERIOD_TO`. A date alone = 00:00:00; `YYYY-MM-DD HH:MM[:SS]` also accepted; anything else is refused |
| `TIMEZONE` | default `UTC`. The zone the period is written in and the zone used for `timestamp with time zone` columns (also when copying them into a plain `timestamp` column). The gsb pivot data is Sydney time, so use `Australia/Sydney`. Found on dev: DuckLake `PERIOD_START_TIME` is `timestamptz`, the Postgres OLD one is a plain `timestamp` |
| `TIME_COLUMN` | default `PERIOD_START_TIME` (checked on dev for the 24 `KPI_NS_QRLY_*_ERS_P` tables). `TABLE_TIME_COLUMNS=T:COL` for a table that differs |
| `FULL_COPY_TABLES` | tables with no time column that are replaced whole. A table without the time column that is not listed stops the run |
| `LOAD_MODE` | `replace` (default), `append`, `stop` |
| `BACKUP` | `on` (default) or `off`. On = the replaced rows are saved in `BACKUP_SCHEMA."<table>_bak_<date_time>"` in the target database. Off = no backup, a warning is printed |
| `ON_ERROR` | `stop` (default) or `continue` with the next table |
| `OFFLINE` | `yes` (default) or `no` |

## Safety checks (before anything is written)

Config valid and no password in it, period valid, source != target table, every table exists on both sides, every source column is in
the target, time column on both sides, row counts printed, bundle checked (DuckDB engine), confirmation for a prod target.
Any problem stops the run with a message and **nothing changed**.

## What a run leaves behind

`reports/<date_time>_<job>/`: `run.log`, `summary.csv` (rows before / after / backup per table, status, seconds) and
`config_used.env` (a copy of the config, no secrets in it).

Exit code: 0 all good, 1 a table failed (rolled back), 2 refused before writing.

## Undo a run

If `BACKUP=on`: put the saved rows back (example for the table above, period 2026-11-01 up to 2026-11-03):

```sql
BEGIN;
DELETE FROM gsb_data."KPI_NS_QRLY_CELL_LTE_ERS_P" WHERE "PERIOD_START_TIME" >= '2026-11-01' AND "PERIOD_START_TIME" < '2026-11-03';
INSERT INTO gsb_data."KPI_NS_QRLY_CELL_LTE_ERS_P" SELECT * FROM import_backup."KPI_NS_QRLY_CELL_LTE_ERS_P_bak_20261112_101500";
COMMIT;
```
(`SELECT *` works because the backup is a copy of the table's own columns. Drop the backup tables when you no longer need them.)

## Upload / server notes

Files uploaded from Windows can arrive with CRLF line endings, which breaks bash scripts. After every upload run
`dos2unix db-import.sh prepare-bundle.sh configs/*.env tests/*.sh` and `chmod +x *.sh`, then check with `grep -c $'\r' db-import.sh` (must print 0).
DuckDB on dev reads `~/.duckdbrc`; the script starts DuckDB with `-init /dev/null`, so that file is ignored.

## Tests

- `bash tests/test_functions.sh`: the logic (periods, quoting, config rules, the generated SQL). No database needed.
- `bash tests/dev_scratch_test.sh`: Postgres -> Postgres on dev with scratch schemas it creates and drops itself.
- DuckDB / DuckLake paths and the offline bundle: see `docs/EVIDENCE.md` for what has and has not been run.
