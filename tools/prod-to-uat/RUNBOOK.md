# prod-to-uat runbook

One command on UAT: **export on prod (SSH) -> copy the zip to UAT -> load it into the UAT DuckLake (db-import) -> compare (pivot-compare)**.
The export runs on the prod server next to the data. Only one finished zip crosses the tunnel.

```
UAT  ./run-all.sh configs/nstd.env
      1 export   ssh prod: export-on-prod.sh   -> /prod/export_out/nstd_20261118_101500.zip (+ .sha256)
      2 copy     scp the zip to UAT, check the checksum
      3 load     db-import (SOURCE_TYPE="csv"): --check first, then the real run
      4 compare  pivot-compare (optional)
```

## 1. What must exist

| Where | What |
|---|---|
| PROD | `export-on-prod.sh`, its own `export.env`, `psql`, `gzip`, `sha256sum`, and `zip` or `python3`. A read-only database user. No DuckDB, no bundle |
| PROD | the password in `~/.pgpass` of the SSH user (`chmod 600`), or an environment variable named in `PG_PASSWORD_ENV` |
| UAT | this tool, the db-import tool (with its `bundle/`) and optionally pivot-compare |
| UAT to PROD | the tunnel open, and SSH **key login** (no password prompt) for `PROD_SSH_USER` |

## 2. One-time setup on prod

Upload these files into one folder on prod (the destination folder is `<prod folder>/prod-to-uat/`):

| Local file | Remote destination folder |
|---|---|
| `tools/prod-to-uat/export-on-prod.sh` | `<prod folder>/prod-to-uat/` |
| `tools/prod-to-uat/export.example.env` | `<prod folder>/prod-to-uat/` |

Then on prod [bash]:
```bash
cd <prod folder>/prod-to-uat
dos2unix export-on-prod.sh export.example.env
chmod +x export-on-prod.sh
cp export.example.env export.env       # edit: PGHOST, PGUSER, PGDATABASE, OUT_ROOT
printf '%s:%s:%s:%s:%s\n' <db host> 5432 gsb <db user> '<password>' >> ~/.pgpass; chmod 600 ~/.pgpass
grep -c "RESULT_ZIP" export-on-prod.sh                        # must print 1 or more
```
Try it by hand first, read only [bash]:
```bash
./export-on-prod.sh --config export.env --tables KPI_NS_QRLY_NODE_CEM_ERS_P --from "2026-10-25" --to "2026-10-26" --name try1 --check
```
It must end with `everything is fine. Nothing was written.`

## 3. One-time setup on UAT

Upload `tools/prod-to-uat/` into `<UAT apps folder>/gsb-utility-tools/prod-to-uat/` (next to `db-import` and `pivot-compare`), then [bash]:
```bash
cd <UAT apps folder>/gsb-utility-tools/prod-to-uat
dos2unix run-all.sh export-on-prod.sh config.example.env tests/*.sh
chmod +x run-all.sh
bash tests/test_export.sh | tail -1        # passed: N   failed: 0
bash tests/test_run_all.sh | tail -1       # passed: N   failed: 0
mkdir -p configs && cp config.example.env configs/nstd.env      # edit it (section 4)
```
The db-import config used by the load (`DB_IMPORT_CONFIG`) is a normal db-import csv config (db-import RUNBOOK section 3.6, example E). Use `PERIOD_FROM="auto"`, `PERIOD_TO="auto"` and `TABLES="auto"` there: the load then takes exactly what the zip holds.

## 4. The settings (`configs/nstd.env`)

| Setting | Meaning |
|---|---|
| `PROD_SSH_HOST`, `PROD_SSH_USER`, `PROD_SSH_PORT`, `PROD_SSH_KEY` | how UAT logs in to prod |
| `PROD_EXPORT_SCRIPT`, `PROD_EXPORT_CONFIG`, `PROD_OUT_ROOT` | where the export script, its config and the zip are, on prod |
| `TABLES`, `PERIOD_FROM`, `PERIOD_TO` | what to export (set here once; the export gets them from this file) |
| `ZIP_NAME_PREFIX` | the zip is `<prefix>_<date>_<time>.zip` |
| `LOCAL_ZIP_DIR` | where the zip lands on UAT |
| `DB_IMPORT_DIR`, `DB_IMPORT_CONFIG` | the load. This tool sets `SOURCE_CSV_PATH` itself to the zip it copied (in a copy of your config; yours is not changed) |
| `COMPARE`, `PIVOT_COMPARE_DIR`, `PIVOT_COMPARE_CONFIG` | the optional comparison |
| `STEPS` | run only some steps |

`PERIOD_TO` is not included. A date alone means 00:00:00. The period is Sydney wall-clock text, cut in hourly files.

## 5. Run (UAT)

Set the UAT target password for the load (the variable name is `TARGET_PASSWORD_ENV` in the db-import config) [bash]:
```bash
read -rs TARGET_PGPASSWORD; export TARGET_PGPASSWORD
```
Then, one at a time [bash]:
```bash
./run-all.sh --check   configs/nstd.env      # reads only: SSH login, the export's check on prod, disk, configs
./run-all.sh --dry-run configs/nstd.env      # real export and copy; the load is rolled back; no compare
./run-all.sh           configs/nstd.env      # the whole chain (asks "Start? type yes")
```
Each run writes `reports/<date>_<job>/` with `run-all.log`, `summary.txt` (steps, seconds, checksum, rows) and the db-import config copy it used.

## 6. Exit codes

| Code | Meaning |
|---|---|
| 0 | every step ok (the comparison is IDENTICAL, or was not run) |
| 1 | a step failed; the later steps did not run |
| 2 | bad setup or config; nothing was done |
| 3 | the chain is ok, the comparison says DIFFERENT |
| 4 | the chain is ok, the comparison says NOT COMPARABLE |

## 7. When a step fails

The log says how to continue. The zip name (`--name`) ties the steps of one run together:

| Failed step | What to do |
|---|---|
| export | read the `ERROR` line. No zip is made after a failed chunk. Continue with `./run-all.sh configs/nstd.env --name <zip name> --steps export --resume` (finished hours are kept) |
| copy | nothing is overwritten and a damaged copy is removed. Re-run `--name <zip name> --steps copy` |
| load | `db-import --check` runs first: if it stops, nothing was loaded. Re-run `--name <zip name> --steps load` (db-import's own backup and rollback apply: see its RUNBOOK section 8) |
| compare | `--name <zip name> --steps compare` |

## 8. Good to know

- **The password is never written anywhere by this tool.** The prod database password comes from `~/.pgpass` or from the variable named in `PG_PASSWORD_ENV`; it is not in the config, the log or the report.
- **Nothing is overwritten.** A zip name that exists on prod or on UAT is refused: use a new `--name`.
- **`--check` writes nothing.** Run it first, every time the config changes.
- **An hour without rows** still gets a header-only file (`SKIP_EMPTY="no"`), so db-import sees no gap in the period.
- **Daylight saving:** the hourly files are cut on the wall-clock text, so the day the clocks change still has every hour.
- **One export config per prod user/database;** the tables and period always come from the UAT config.

## 9. Checklist

- [ ] The tunnel is open and `./run-all.sh --check` ends with `everything is fine`
- [ ] The prod folder has enough free disk (`MIN_FREE_MB`), and so does `LOCAL_ZIP_DIR`
- [ ] `TARGET_PGPASSWORD` (or the name in the db-import config) is exported in this terminal
- [ ] `--dry-run` was read before the real run
- [ ] After the run: `summary.txt` shows every step `OK`; note the zip name and checksum
