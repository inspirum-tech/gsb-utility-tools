# Prod to UAT full flow runbook

For the person who runs the flow on UAT. You do not need anyone's help: follow the steps in order.

**What it does, in one line.** One command on UAT that exports pivot tables on the prod server (over SSH), copies the zip to UAT,
loads it into the UAT DuckLake, and compares it with the new calculator's output, then writes a report you can share.

```
UAT   ./run-all.sh configs/<job>.env
        1 EXPORT   logs in to prod over SSH and runs export-on-prod.sh there (next to the data)
                   prod Postgres tables -> hourly .csv.gz files + _manifest.csv -> ONE zip + its .sha256
        2 COPY     scp copies the zip to UAT and checks the checksum
        3 LOAD     db-import checks the zip, backs up the old rows, replaces the rows of the period in the UAT DuckLake
        4 COMPARE  pivot-compare compares the loaded prod data (OLD) with the new calculator's output (NEW)
                   -> Word report + Excel + zip
```

Each step starts only when the step before it ended without error. If a step fails, the later steps do not run.

**Example.** Tables `KPI_NS_QRLY_NODE_CEM_ERS_P` and `KPI_NS_QRLY_NODE_IST_ERS_P`, period 2026-10-25 00:00 to 02:00.
The export makes 4 files (CEM hour 00 = 40,221 rows, CEM hour 01 = 40,224, IST hour 00 = 72,164, IST hour 01 = 72,170) and one zip with 224,779 rows.
The load replaces those rows in the UAT DuckLake (the old rows are saved in a backup table first). The comparison then reads that loaded data and the new calculator's data from the same DuckLake.

## Contents

1. [The parts, and where each one runs](#1-the-parts-and-where-each-one-runs)
2. [What you need before you start](#2-what-you-need-before-you-start)
3. [One-time setup on PROD](#3-one-time-setup-on-prod)
4. [One-time setup on UAT](#4-one-time-setup-on-uat)
5. [The four config files: every setting](#5-the-four-config-files-every-setting)
6. [Run it](#6-run-it)
7. [Check the result](#7-check-the-result)
8. [Change the job: what to edit for what you want](#8-change-the-job-what-to-edit-for-what-you-want)
9. [When something goes wrong](#9-when-something-goes-wrong)
10. [Undo and clean up](#10-undo-and-clean-up)
11. [Checklist](#11-checklist)

---

## 1. The parts, and where each one runs

| Part | Runs on | What it is | You create or edit it? |
|---|---|---|---|
| `export-on-prod.sh` | PROD | reads the Postgres pivot tables, writes the zip | upload once |
| `export.env` | PROD | the prod database connection (no password) | create once from `export.example.env` |
| `~/.pgpass` | PROD | the prod database password | create once |
| `run-all.sh` | UAT | the one command that runs the four steps | upload once |
| `configs/<job>.env` (the **run-all config**) | UAT | SSH, tables, period, folders, which steps | one per job |
| `db-import` tool + `bundle/` | UAT | loads the zip into the DuckLake | upload once |
| `db-import/configs/<job>_load.env` (the **db-import config**) | UAT | the DuckLake target, schema, backup | one per job |
| `pivot-compare` tool | UAT | compares OLD and NEW | upload once |
| `pivot-compare/<job>_compare.env` + `<job>_pairs.csv` (the **pivot-compare config** and **pairs file**) | UAT | what to compare, which period | one per job |

Folder layout on UAT (the three tools are side by side):

```
<UAT apps folder>/gsb-utility-tools/
    prod-to-uat/        this tool   (run-all.sh, configs/, reports/, tests/)
    db-import/          with its bundle/ folder inside
    pivot-compare/
```

Every run writes a report folder `prod-to-uat/reports/<date_time>_<job>/` with `run-all.log` (everything printed), `summary.txt` (steps, seconds, checksum, rows),
`config_used.env` (a copy of your run-all config) and `db-import.env` (the db-import config this run really used).

## 2. What you need before you start

Collect these values first. Ask the owner named in the last column for any you do not have.

| What | Example | Who knows |
|---|---|---|
| The prod server (or the tunnel address) that UAT logs in to, the SSH port and the SSH user | host `<prod or tunnel host>`, port `22`, user `<user>` | the team that opens the tunnel |
| An SSH **key** that logs in to prod without a password, and the tunnel **open** | `/home/<you>/.ssh/<key>` | the same team (they add your public key to the prod user) |
| A folder on prod where the export script, its config and the zip may live | `/<prod folder>/prod-to-uat/` and `/<prod folder>/export_out/` | the prod admin |
| The prod database: host, port, database (`gsb`), schema (`gsb_data_kpi_pivot`), a **read-only** user and its password | | the prod DBA |
| The exact prod table names to export | `KPI_NS_QRLY_NODE_CEM_ERS_P`, ... | the calculator owners |
| The UAT DuckLake: Postgres host, port, database (`ducklake`), user, password, the **data folder**, the metadata schema (`metadata`), the **catalog name** in `~/.duckdbrc` (`gsb`), and the schema to load into | | the UAT DBA |
| The UAT schema and table names of the **new calculator's** output | `KPI_NS_QRLY_NODE_CEM_ERS_NEW_P` | the calculator owners |

What each machine needs installed:

| Machine | Needs | Check |
|---|---|---|
| PROD | `bash`, `psql`, `gzip`, `sha256sum`, and `zip` **or** `python3`. No DuckDB, no bundle | `which psql gzip sha256sum zip python3` |
| UAT | `bash` 4 or newer, `ssh`, `scp`, `sha256sum`, `unzip` **or** `python3`, `dos2unix`, free disk in `LOCAL_ZIP_DIR` for the zip, and in the load's work folder (`CSV_WORK_DIR`, default `/tmp`) for the zip's unzipped files (about the size of the zip). The root disk of a server can be small: check `df -h /` | `bash --version \| head -1`, `which ssh scp unzip python3 dos2unix` |
| UAT | the `db-import/bundle/` folder (the DuckDB program and its extensions `ducklake` and `postgres_scanner`) | step 4.2 |
| UAT | the DuckDB program for pivot-compare, and `~/.duckdbrc` that attaches the DuckLake catalog | step 4.5 |

No internet is needed on any of them.

## 3. One-time setup on PROD

**3.1 Upload two files.** Upload from your PC (WinTerm, "Upload To Current Folder"). The destination is a folder, not a file name.

| Local file | Remote destination folder (overwrite if it exists) |
|---|---|
| `tools/prod-to-uat/export-on-prod.sh` | `<prod folder>/prod-to-uat/` |
| `tools/prod-to-uat/export.example.env` | `<prod folder>/prod-to-uat/` |

**3.2 Fix and prepare** [bash, on prod]:
```bash
cd <prod folder>/prod-to-uat
dos2unix export-on-prod.sh export.example.env          # files from Windows have the wrong line endings otherwise
chmod +x export-on-prod.sh
cp export.example.env export.env
grep -c "RESULT_ZIP" export-on-prod.sh                  # must print 1 or more (the upload landed and is the new version)
mkdir -p <prod folder>/export_out
```
Edit `export.env` (section 5.1): `PGHOST`, `PGUSER`, `PGDATABASE`, `OUT_ROOT`.

**3.3 The database password.** Put it in `~/.pgpass` of the user that UAT logs in as (so it is never in a file in git, never typed, never printed) [bash, on prod]:
```bash
printf '%s:%s:%s:%s:%s\n' <db host> 5432 gsb <db user> '<password>' >> ~/.pgpass
chmod 600 ~/.pgpass
```
(Or, instead, name an environment variable in `PG_PASSWORD_ENV` in `export.env`. A password in `~/.pgpass` also works when `run-all.sh` starts the export over SSH, so it is the recommended way.)

**3.4 Try the export by hand, read only** [bash, on prod]:
```bash
./export-on-prod.sh --config export.env --tables <one real table> --from "2026-10-25" --to "2026-10-26" --name try1 --check
```
It must end with `everything is fine. Nothing was written.`, and the table line shows the rows in the period, for example
`OK     gsb_data_kpi_pivot.<table>: time column PERIOD_START_TIME, <N> row(s) in the period`.

## 4. One-time setup on UAT

**4.1 Upload the tools.** Upload each folder into `<UAT apps folder>/gsb-utility-tools/` (the destination folder is that path; each folder must land as `.../gsb-utility-tools/<tool>/`, not one level deeper).

| Local folder | Remote destination folder |
|---|---|
| `tools/prod-to-uat/` | `<UAT apps folder>/gsb-utility-tools/` |
| `tools/db-import/` (skip it if the new db-import is already there) | `<UAT apps folder>/gsb-utility-tools/` |
| `tools/pivot-compare/` (skip it if it is already there) | `<UAT apps folder>/gsb-utility-tools/` |

Then fix the line endings and prove the upload [bash, on UAT]:
```bash
cd <UAT apps folder>/gsb-utility-tools
(cd prod-to-uat  && dos2unix run-all.sh export-on-prod.sh config.example.env export.example.env tests/*.sh && chmod +x run-all.sh export-on-prod.sh)
(cd db-import    && dos2unix db-import.sh prepare-bundle.sh config.example.env tests/*.sh && chmod +x db-import.sh prepare-bundle.sh tests/*.sh)
(cd pivot-compare && dos2unix run.sh *.env *.csv scripts/*.py scripts/*.sh sql/*.sql)
ls -la prod-to-uat/run-all.sh db-import/db-import.sh pivot-compare/run.sh      # all three exist
grep -c "RESULT_ZIP" prod-to-uat/export-on-prod.sh                              # 1 or more
```

**4.2 The `db-import/bundle/` folder.** It is **not in git**. Without it the load stops with `offline bundle not found`.
Copy the whole `bundle/` folder from a working db-import folder on UAT (for example the older db-import that is already there), or from dev:
```bash
cp -r <old db-import folder>/bundle <UAT apps folder>/gsb-utility-tools/db-import/
```
Check that it holds the two extensions the DuckLake needs [bash, on UAT]:
```bash
ls <UAT apps folder>/gsb-utility-tools/db-import/bundle/extensions/*/*/ | grep -E "ducklake|postgres_scanner"
```
Both names must be listed. If `ducklake` is missing, the load stops with `extension 'ducklake' is not in the bundle`: you copied an older bundle built for another job. Copy the complete bundle from dev
(`db-import-bundle-<version>.tar.gz` with its `.sha256`; check with `sha256sum -c`, then `tar -xzf`). **Never run `prepare-bundle.sh` on UAT:** it needs internet.

**4.3 Run the self-tests** (no database, no SSH, nothing is written outside the tool folder) [bash, on UAT]:
```bash
cd <UAT apps folder>/gsb-utility-tools/prod-to-uat
bash tests/test_export.sh | tail -1        # passed: 68   failed: 0
bash tests/test_run_all.sh | tail -1       # passed: 78   failed: 0
```
`failed` must be 0 in both. If not, do not go on: send the output to the tool owner.

**4.4 SSH to prod with a key.** The tunnel must be open. Test it exactly as `run-all.sh` does (no password prompt allowed) [bash, on UAT]:
```bash
ssh -i <key file> -p <port> -o BatchMode=yes <PROD_SSH_USER>@<PROD_SSH_HOST> "echo ok"
```
It must print `ok` and nothing else. If it asks for a password or says `Permission denied`, the key is not set up on prod: ask the team that opens the tunnel.

**4.5 The DuckLake catalog (for the comparison).** pivot-compare reads the UAT DuckLake through the catalog that DuckDB attaches from `~/.duckdbrc` [bash, on UAT]:
```bash
<path to the duckdb program> -c "select database_name from duckdb_databases();"
```
The list must contain the catalog name you will put in `OLD_CATALOG` and `NEW_CATALOG` (on dev it is `gsb`). If it does not, ask the UAT DBA for the `ATTACH` line for `~/.duckdbrc`.

**4.6 Create the four configs** (section 5), each one from its example, and edit them.

## 5. The four config files: every setting

Rules for every config file: plain `NAME="value"` lines, **no spaces around `=`**, lines that start with `#` are comments, **no passwords in any config**.
After each change, run the checks in section 6 before you run anything for real.

### 5.1 PROD: `export.env` (the database connection)

Copy from `export.example.env` and edit. Used by `export-on-prod.sh`.

| Setting | Meaning | Example | Change it when | Verify |
|---|---|---|---|---|
| `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` | the prod Postgres | `PGDATABASE="gsb"` | the database or user changes | export `--check` says `connected to the database` |
| `PG_PASSWORD_ENV` | the **name** of an environment variable that holds the password. Empty = use `~/.pgpass` | `""` | you do not use `~/.pgpass` | same |
| `SCHEMA` | the schema of the pivot tables | `gsb_data_kpi_pivot` | the tables live in another schema | the `--check` table lines |
| `TS_COL` | the time column (all tables) | `PERIOD_START_TIME` | the tables use another name | `--check` says `time column ...` |
| `TABLE_TIME_COLUMNS` | for a table whose time column has another name: `TABLE_A:COL,TABLE_B:COL` | (not set) | one table differs | `--check` |
| `OUT_ROOT` | the folder on prod where the zip is written | `/<prod folder>/export_out` | the folder changes | `--check` says `OUT_ROOT ... is writable, N MB free` |
| `STEP_HOURS` | one file per table per this many hours | `1` | **keep 1** unless told otherwise | the file names |
| `TZ_MODE` | `LITERAL` = the time column is a plain timestamp, compared as written (the pivot tables) | `LITERAL` | only if told: `SYD_LOCAL_ON_UTC_TS`, `SYD_LOCAL_ON_TZ_COL` | `--check` row count |
| `SKIP_EMPTY` | `no` = an hour without rows still gets a header-only file, so the load sees no gap | `no` | keep `no` | the load `--check` has no `no file for ...` line |
| `MIN_FREE_MB` | stop if `OUT_ROOT` has less free space | `1024` | bigger exports | `--check` |
| `RESUME` | `yes` = continue an earlier run of the same name (also `--resume`) | `no` | prefer the `--resume` option | |

The tables, the period and the zip name are **not** set here when `run-all.sh` starts the export: it passes them from the run-all config.

### 5.2 UAT: the run-all config `configs/<job>.env`

Copy from `config.example.env`. Used by `run-all.sh`.

```bash
cd <UAT apps folder>/gsb-utility-tools/prod-to-uat
mkdir -p configs
cp config.example.env configs/nstd_prod_to_uat.env
vi configs/nstd_prod_to_uat.env
```

| Setting | Meaning | Example | Change it when | Verify |
|---|---|---|---|---|
| `JOB_NAME` | the name of this job (letters, digits, `_`, `-`) | `nstd_prod_to_uat` | a new job | the report folder name |
| `REMOTE_MODE` | `ssh` (real). `local` runs the "prod" step on this machine: **only for tests** | `ssh` | never on UAT | `--check` first line |
| `PROD_SSH_HOST`, `PROD_SSH_USER`, `PROD_SSH_PORT` | how UAT logs in to prod | `22` | the tunnel or user changes | step 4.4 prints `ok`; `--check` says `can log in to prod without a password prompt` |
| `PROD_SSH_KEY` | the private key file on UAT (key login only). Empty = the default key | `/home/<you>/.ssh/<key>` | the key changes | `--check` |
| `SSH_CONNECT_TIMEOUT` | seconds to wait for the connection | `15` | a slow tunnel | |
| `PROD_EXPORT_SCRIPT` | the full path of `export-on-prod.sh` **on prod** | `/<prod folder>/prod-to-uat/export-on-prod.sh` | the folder on prod changes | `--check` says `the export script exists on prod` |
| `PROD_EXPORT_CONFIG` | the full path of `export.env` **on prod** | `/<prod folder>/prod-to-uat/export.env` | same | `--check` says `the export config exists on prod` |
| `PROD_OUT_ROOT` | the folder on prod for the zip (same as `OUT_ROOT`) | `/<prod folder>/export_out` | same | the export check says writable |
| `TABLES` | the prod table names to export, comma separated. **One zip holds all of them** | `KPI_NS_QRLY_NODE_CEM_ERS_P,KPI_NS_QRLY_NODE_IST_ERS_P` | which application or tables | the export check lists one `OK` line per table with its row count |
| `PERIOD_FROM`, `PERIOD_TO` | `PERIOD_FROM <= time < PERIOD_TO`, as **Sydney wall-clock text** (a date alone means 00:00:00; `"2026-10-25 03:15"` also works) | `2026-10-25` and `2026-10-25 02:00` | the period to bring over | the export check shows the period and the rows in it |
| `ZIP_NAME_PREFIX` | the zip is called `<prefix>_<date>_<time>.zip` | `nstd` | a new job | `summary.txt` |
| `LOCAL_ZIP_DIR` | where the zip lands on UAT | `/data/upload` | the folder changes | `--check` says `... is writable, N MB free` |
| `DB_IMPORT_DIR` | the db-import tool folder (default: `../db-import`) | | the tool is elsewhere | `--check` |
| `DB_IMPORT_CONFIG` | the db-import config (section 5.3). It must set `SOURCE_TYPE="csv"` | `.../db-import/configs/nstd_load.env` | a new target | `--check` says `sets SOURCE_TYPE=csv` |
| `COMPARE` | `yes` runs pivot-compare after the load. `no` skips it | `yes` | you want or do not want the comparison | the step list at the top of `--check` |
| `PIVOT_COMPARE_DIR` | the pivot-compare folder (default: `../pivot-compare`) | | elsewhere | |
| `PIVOT_COMPARE_CONFIG` | the pivot-compare config (section 5.4) | `.../pivot-compare/nstd_compare.env` | a new comparison | `--check` says `pivot-compare config ...` |
| `STEPS` (optional) | run only some steps, e.g. `copy,load,compare` (also `--steps`) | | a re-run | |
| `MIN_FREE_MB` (optional) | free disk needed besides the zip, on UAT and prod | `1024` | big zips | |
| `REPORT_DIR` (optional) | where the run reports go (default `./reports`) | | | |

Rules checked at start: names use letters, digits, `_` and `-`; **paths must not contain spaces** (letters, digits and `_ . / : @ + -` only).
A zip name that already exists on prod or on UAT is refused: nothing is overwritten.

### 5.3 UAT: the db-import config `db-import/configs/<job>_load.env`

This is the config of the **load**. `run-all.sh` adds the line `SOURCE_CSV_PATH` (the zip it copied) to **its own copy** of this file for each run, so you never set the zip here.

```bash
cd <UAT apps folder>/gsb-utility-tools/db-import
vi configs/nstd_load.env
```
```bash
JOB_NAME="nstd_load"
SOURCE_TYPE="csv"
TARGET_TYPE="ducklake"
TARGET_ENV="uat"
TARGET_HOST="<UAT DuckLake Postgres host>"
TARGET_PORT="5432"
TARGET_DB="ducklake"
TARGET_USER="<user>"
TARGET_PASSWORD_ENV="TARGET_PGPASSWORD"
TARGET_DUCKLAKE_DATA_PATH="<the DuckLake data folder>"
TARGET_DUCKLAKE_METADATA_SCHEMA="metadata"
TARGET_SCHEMA="<the schema to load into>"
TARGET_STRUCTURE="strict"
TABLES="auto"
PERIOD_FROM="auto"
PERIOD_TO="auto"
TIMEZONE="Australia/Sydney"
BACKUP="on"
BACKUP_SCHEMA="<the schema for the backups>"
OFFLINE="yes"
REPORT_DIR="/tmp/dbimport_reports_<your user>"
```

| Setting | Meaning | Change it when | Verify |
|---|---|---|---|
| `SOURCE_TYPE="csv"` | the load reads the zip. **Must stay `csv`** | never | `run-all --check` |
| `TARGET_TYPE="ducklake"`, `TARGET_ENV` | the target type and its **real** environment (`dev`, `uat` or `prod`) | the target changes | the db-import `--check` first lines |
| `TARGET_HOST`, `TARGET_PORT`, `TARGET_DB`, `TARGET_USER` | the Postgres that holds the DuckLake **metadata** (database `ducklake`) | the DuckLake changes | the db-import `--check` reaches the target |
| `TARGET_PASSWORD_ENV` | the **name** of the environment variable that holds the password (section 6.1). Empty = `~/.pgpass` | | `run-all --check` says `target password variable: TARGET_PGPASSWORD` |
| `TARGET_DUCKLAKE_DATA_PATH` | the DuckLake data folder (the load writes the parquet files there itself, so this machine must be able to write to it) | the DuckLake changes | the load runs |
| `TARGET_DUCKLAKE_METADATA_SCHEMA` | the metadata schema | `metadata` | |
| `TARGET_SCHEMA` | the schema the prod data is loaded into. **This is the OLD side of the comparison** | a different schema | `--check` table lines show `TARGET TABLE` |
| `TARGET_STRUCTURE` | `strict` (default): the schema, tables and columns **must already exist and fit**, otherwise the run stops. `create`: the data is the truth: the schema, tables and missing columns are **created**. A created table or column **stays** after a run | use `create` only the first time into a new schema or table, on purpose, after `--check` | `--check` prints `TARGET_STRUCTURE=create: ... new table (8 columns)` and saves the statements in `structure_changes.sql` |
| `TABLES="auto"` | load every table found in the zip | keep `auto` | the `--check` table lines match your `TABLES` |
| `PERIOD_FROM="auto"`, `PERIOD_TO="auto"` | load exactly the range the zip holds. Only the target rows of that same range are replaced | keep `auto` | the `--check` line `KPI_...: 2 file(s), period ... to ...` |
| `TIMEZONE` | the times in the files are Sydney local time | keep | |
| `BACKUP`, `BACKUP_SCHEMA` | `on` saves the rows that will be replaced into `<BACKUP_SCHEMA>.<table>_bak_<date_time>` before anything is changed | keep `on` | `BACKUP rows` in the run output equals the old target rows |
| `OFFLINE="yes"` | use the `bundle/` (no internet) | keep | |
| `REPORT_DIR` | where db-import writes its run folders. **Use a folder you can write to** | | |
| `EXTRA_SOURCE_COLUMNS` | do **not** set it together with `TARGET_STRUCTURE="create"` (the load refuses) | | |

### 5.4 UAT: the pivot-compare config and the pairs file

Make copies; never edit the shipped files. Use the shipped `config_ns_all.env` (**not** `config_ns_all_dev.env`: that one holds dev notes).

```bash
cd <UAT apps folder>/gsb-utility-tools/pivot-compare
cp config_ns_all.env nstd_compare.env
cp pairs_ns_name.csv nstd_pairs.csv
vi nstd_compare.env nstd_pairs.csv
```

In this flow the **OLD side is the prod data this flow loaded into the UAT DuckLake** and the **NEW side is the new calculator's output**; both are read from the DuckLake.
Check or change these lines in `nstd_compare.env`:

| Line | What to put | Why |
|---|---|---|
| `MODE` | `list` | one comparison per line of the pairs file |
| `PAIRS_FILE` | `nstd_pairs.csv` | the list of tables to compare |
| `PERIOD_FROM`, `PERIOD_TO` | the window to compare **in UTC**, like `"2026-10-24 13:00:00+00"` and `"2026-10-24 15:00:00+00"` (half open: `FROM <= period < TO`). Sydney is UTC+11 in daylight saving (October to April) and UTC+10 otherwise: 2026-10-25 00:00 to 02:00 Sydney = `2026-10-24 13:00` to `15:00` UTC | **inside the period you export and inside the range the new calculator has written**. A period on one side only is reported as "not comparable" |
| `OLD_SOURCE` | `attached` | the OLD side is the DuckLake catalog |
| `OLD_DSN_ENV` | empty | no Postgres connection for the OLD side |
| `OLD_CATALOG` | the catalog name from step 4.5 (`gsb` on dev) | |
| `OLD_SCHEMA` | the same value as `TARGET_SCHEMA` in the db-import config | the OLD tables are the ones this flow loads |
| `OLD_PERIOD_KIND`, `OLD_PERIOD_TZ` | `local` and `Australia/Sydney` | the loaded times are plain Sydney wall-clock timestamps |
| `NEW_SOURCE` | `attached` | |
| `NEW_CATALOG`, `NEW_SCHEMA` | the catalog and the schema of the new calculator's tables | differs per environment |
| `NEW_PERIOD_KIND`, `NEW_PERIOD_TZ` | `tz` and `UTC` (as shipped) | the new tables hold timestamps with time zone |
| `FINAL_REPORT` | `yes` | builds the Word, Excel and zip |
| `FINAL_REPORT_TITLE` | letters, digits, space, `_` and `-` **only** (no brackets) e.g. `"NS Pivot Comparison - UAT"` | otherwise the report is **not** written (the comparison still finishes) |
| `FINAL_REPORT_AUTHOR` | your name | printed on the report |
| `FINAL_REPORT_NOTES_FILE`, `FINAL_REPORT_COMMENTS_FILE` | **empty** | those files hold text about dev data |
| `REPORT_DIR` | a **new** name for **every** run, e.g. `report_uat_20261201` | the final output folder is never overwritten: a name that is already used gives `already exists` and no new report |
| `DUCKDB` | the full path of the DuckDB program on this server | differs per server |
| `TEMP_DIR` | an existing folder with free space (`mkdir -p tmp` in the tool folder) | DuckDB writes large temporary files there |

Keep the rest as shipped (tolerances, `CM_COMPARE=no`, `INFO_COMPARE=yes`). If a run says `config error: no connection string`, create the `.env` file described in section 4 of the pivot-compare `RUNBOOK.md` (one line, `KPI_ENGINE_PG_DSN=<connection string>`, `chmod 600`).

**The pairs file** has one line per table pair: `name,old_table,new_table,key_cols,info_cols`. The shipped `pairs_ns_name.csv` lists the 17 NS tables of dev, for example:

```
name,old_table,new_table,key_cols,info_cols
NODE_CEM,KPI_NS_QRLY_NODE_CEM_ERS_P,KPI_NS_QRLY_NODE_CEM_ERS_NEW_P,SITE_NAME;CEM,SITE_ID
NODE_IST,KPI_NS_QRLY_NODE_IST_ERS_P,KPI_NS_QRLY_NODE_IST_ERS_NEW_P,SITE_NAME,SITE_ID
```
- `old_table` = the prod table name that was exported and loaded. `new_table` = the new calculator's table. **Check both names on this environment.**
- **Keep only the tables you export** (a line for a table that was not loaded gives `ERROR` for that line). Do not change the `key_cols` and `info_cols` columns.
- One line per table: the compare only covers the tables listed here, the export only the tables in `TABLES`. Keep the two lists the same.

## 6. Run it

Always in this order: **check**, **dry run**, **real run**. Read the output of each before you go on.

### 6.1 The password for the load (every new terminal)

The load needs the UAT target password. The variable name is the one in `TARGET_PASSWORD_ENV` (section 5.3). Type it; the screen does not show what you type [bash, on UAT]:
```bash
read -rs TARGET_PGPASSWORD; export TARGET_PGPASSWORD
```
It must be set in the **same terminal** where you run `run-all.sh`; it is gone when you close the terminal. The prod password is not needed on UAT (it is in `~/.pgpass` on prod).
For an export that takes long, start a `screen` (or `tmux`) first, so closing the terminal does not stop the run.

### 6.2 Check (reads only, writes nothing)

```bash
cd <UAT apps folder>/gsb-utility-tools/prod-to-uat
./run-all.sh --check configs/nstd_prod_to_uat.env
```
It checks the SSH login, the export script and config on prod, runs the export's own read-only check on prod (connection, every table, time column, row count in the period, disk, zip tool), the folder and disk on UAT, the password variable, and the db-import and pivot-compare configs.
It must end with `CHECK  everything is fine. Nothing was written`. Example output:

```
[..] OK     can log in to prod without a password prompt
[..] OK     the export script exists on prod
[..] OK     the export config exists on prod
         | [..] OK     gsb_data_kpi_pivot.KPI_NS_QRLY_NODE_CEM_ERS_P: time column PERIOD_START_TIME, 80445 row(s) in the period
         | [..] OK     gsb_data_kpi_pivot.KPI_NS_QRLY_NODE_IST_ERS_P: time column PERIOD_START_TIME, 144334 row(s) in the period
[..] OK     <LOCAL_ZIP_DIR> is writable, 37112 MB free
[..] OK     pivot-compare config ...
[..] CHECK  everything is fine. Nothing was written ...
```
Any line that starts with `ERROR` stops the check: see section 9. Check that every table in `TABLES` has an `OK` line and that the row counts look right.

### 6.3 Dry run (the load is rolled back, no comparison)

```bash
./run-all.sh --dry-run configs/nstd_prod_to_uat.env
```
It asks `Start? type yes:` (type exactly `yes`, or add `--yes` to skip the question).
It does the **real export and the real copy** (the zip stays on prod and on UAT) and runs the load as a dry run: the whole load is done and then rolled back, so the UAT DuckLake is unchanged.
It must show `DRY-RUN OK (rolled back): target rows in the period 0 -> 130727 (source 130727)` for each table, and the summary with export, copy and load `OK`.

### 6.4 The real run

```bash
./run-all.sh configs/nstd_prod_to_uat.env
```
Type `yes` when asked. Each run makes its own zip name (from the date and time), so the zip of the dry run is not reused.
This is the whole chain: export, copy, load, compare. Example output (the end of the run):

```
job:        nstd_prod_to_uat
zip:        nstd_20261119_233002   (prod: <PROD_OUT_ROOT>/nstd_20261119_233002.zip)   (UAT: <LOCAL_ZIP_DIR>/nstd_20261119_233002.zip)
tables:     KPI_NS_QRLY_NODE_CEM_ERS_P,KPI_NS_QRLY_NODE_IST_ERS_P
period:     2026-10-25  to  2026-10-25 02:00
checksum:   56eefca7...0615a    rows exported: 224779
step      status   seconds
export    OK       1
copy      OK       0
load      OK       12
compare   OK       4
compare exit code: 1 (0 identical, 1 different, 3 not comparable)
report folder: .../prod-to-uat/reports/20261119_233002_nstd_prod_to_uat
[..] DONE   all steps ran; the comparison says DIFFERENT
```

**The exit code** (`echo $?` right after the run):

| Code | Meaning |
|---|---|
| 0 | every step OK, and the comparison is IDENTICAL or was not run |
| 1 | a step failed; the later steps did not run (the log says how to continue) |
| 2 | a bad setup or config; nothing was done |
| 3 | the chain is OK and the comparison says **DIFFERENT**. This is an answer, not a failure |
| 4 | the chain is OK and the comparison says **NOT COMPARABLE** (no object or period in common) |

## 7. Check the result

Do these after a real run. Each line says what must be true.

| What | How | Must be |
|---|---|---|
| Every step OK | `cat reports/<date_time>_<job>/summary.txt` | `export`, `copy`, `load` (and `compare`) show `OK` |
| The zip is not damaged | the log line `copied, checksum <hash> matches` | present, and the same hash as `checksum:` in `summary.txt` |
| The right rows were exported | `rows exported:` in `summary.txt` equals the sum of the `row(s)` of the tables in the export check | equal |
| The load matches the zip | in the load output, per table: `OK: target rows in the period X -> N (source N), backup rows B` | `N` = source rows; `B` = the old target rows (they are saved) |
| Nothing was left behind | the last load line | `finished: all tables OK` |
| The comparison | `pivot-compare/<REPORT_DIR>/pairs_summary.csv` | one line per table in your pairs file, none says `ERROR` |
| The report was written | `ls -d <REPORT_DIR>_FINAL_OUTPUT_RESULT*` in the pivot-compare folder | the folder and the `.zip` are listed |

**Where the comparison output is** (inside the pivot-compare folder):

| Path | What |
|---|---|
| `<REPORT_DIR>/` | the raw results: `pairs_summary.csv` and one folder per table |
| `<REPORT_DIR>_FINAL_OUTPUT_RESULT/` | the folder to share: the Word report, the Excel sheet, one folder per table, `Supporting_details/` |
| `<REPORT_DIR>_FINAL_OUTPUT_RESULT.zip` | the same folder as one zip. **Send this file** |

Check that the zip is complete: `unzip -t <REPORT_DIR>_FINAL_OUTPUT_RESULT.zip | tail -2` must end with `No errors detected`.

**How to read the comparison.** `pairs_summary.csv` gives one line per table with a result: `IDENTICAL`, `DIFFERENT`, `NOT COMPARABLE` or `ERROR`. In the detail text:

| Text | Meaning |
|---|---|
| `objects only old=N` | N objects (for example sites) are in the loaded prod data but not in the new calculator's output |
| `values compared=V different=D` | V values compared; D of them differ by more than the tolerance (1e-8) |
| `null_old_only`, `null_new_only` | a value is empty on one side only |
| `duplicate entries=N conflicting=M` | repeated rows on one side; `conflicting` are repeated rows with different values |
| `periods on both sides=P only old=.. only new=..` | the 15-minute periods in common; a period on one side only is a mismatch |

A table is `PASS` in the Word report only when nothing differs, nothing exists on one side only, nothing is empty on one side, no period is on one side only and no repeated row has conflicting values; otherwise it says `NOT MET` with the numbers.

**What to send back to the team:** the final output zip `<REPORT_DIR>_FINAL_OUTPUT_RESULT.zip`, and the report folder `prod-to-uat/reports/<date_time>_<job>/` (it holds the complete log).

## 8. Change the job: what to edit for what you want

| I want to | Edit this | In this file | Then verify with |
|---|---|---|---|
| Export **another application** (a different set of tables) | `TABLES`, `ZIP_NAME_PREFIX`; add the table pairs to a pairs file | run-all config; pairs file | `--check` shows one `OK` line per table |
| Make one run per application (separate zips) | a separate run-all config per application, each with its own `TABLES` and `ZIP_NAME_PREFIX` (and its own db-import, pairs and compare config if the target or the window differ) | `configs/<application>.env` | `--check` of each |
| Export **more or fewer tables** in one zip | `TABLES` (and the pairs file lines) | run-all config; pairs file | `--check` |
| A **different period** | `PERIOD_FROM`, `PERIOD_TO` in the run-all config (Sydney text) **and** `PERIOD_FROM`, `PERIOD_TO` in the compare config (UTC) | both | the export check shows the rows; the compare window lies inside the exported period |
| A different **UAT folder** for the zip | `LOCAL_ZIP_DIR` | run-all config | `--check` says writable |
| A different **prod server, user or key** | `PROD_SSH_HOST`, `PROD_SSH_USER`, `PROD_SSH_PORT`, `PROD_SSH_KEY` | run-all config | step 4.4 prints `ok` |
| A different **prod folder** | `PROD_EXPORT_SCRIPT`, `PROD_EXPORT_CONFIG`, `PROD_OUT_ROOT`; `OUT_ROOT` in `export.env` | run-all config; `export.env` | `--check` |
| A different **prod database or user** | `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `SCHEMA`; the `~/.pgpass` line | `export.env` (on prod) | the manual export `--check` (step 3.4) |
| Load into **another UAT schema** | `TARGET_SCHEMA`, `BACKUP_SCHEMA` in the db-import config; `OLD_SCHEMA` in the compare config (the same value) | db-import config; compare config | `--check`; the compare `OLD_SCHEMA` equals `TARGET_SCHEMA` |
| Load into a **new schema or new tables** (the first time) | `TARGET_STRUCTURE="create"`, then back to `strict` | db-import config | `--check` lists what will be created |
| **Skip the comparison** | `COMPARE="no"` | run-all config | the step list shows no `compare` |
| **Compare only** (data already loaded) | `./run-all.sh configs/<job>.env --name <zip name> --steps compare` (set a **new** `REPORT_DIR` in the compare config first) | command line | `pairs_summary.csv` |
| Run **one step again** | `./run-all.sh configs/<job>.env --name <zip name> --steps <step>` | command line | `summary.txt` |
| The **report title or author** | `FINAL_REPORT_TITLE`, `FINAL_REPORT_AUTHOR` | compare config | the Word report |
| Skip the "Start? type yes" question (a scheduled run) | add `--yes` | command line | |

## 9. When something goes wrong

A failed step stops the chain and the log prints the exact command to continue, for example:
`STOPPED at step load: later steps were not run. Fix it, then re-run the step with:  ./run-all.sh <config> --name <zip name> --steps load`.
**The zip name (`--name`) ties the steps of one run together.** Nothing is ever overwritten, so a re-run is safe.

### 9.1 What to do for each step

| Failed step | What happened | What to do |
|---|---|---|
| export | a chunk failed: **no zip is made**, and `___All_Errors.txt` in the prod folder says where it stopped | read the `ERROR` line; fix the cause; continue with `./run-all.sh configs/<job>.env --name <zip name> --steps export --resume` (the finished hours are kept, only the rest is exported) |
| copy | the zip did not arrive or its checksum did not match; a damaged copy is removed | re-run `--name <zip name> --steps copy` |
| load | `db-import --check` runs first: if it stops, **nothing was loaded**. If a table fails during the load it is rolled back (the target keeps its old rows for it) | fix the cause; re-run `--name <zip name> --steps load` (a zip that was loaded is replaced with the same data) |
| compare | the loaded data is fine; only the comparison failed | fix the compare config; use a **new** `REPORT_DIR`; re-run `--name <zip name> --steps compare` |

### 9.2 Messages and fixes

| Message | Cause and fix |
|---|---|
| `ERROR: config file not found` | the path is wrong, or you are not in the `prod-to-uat` folder |
| `ERROR: <NAME> is not set in <config>` | a required line is missing in the run-all config |
| `ERROR: <NAME> has a character that is not allowed` | a path has a space or a character outside `A-Z a-z 0-9 _ . / : @ + -` |
| `ERROR: PROD_SSH_KEY ... is not readable` | wrong key path, or the key is not readable by you (`chmod 600`) |
| `ERROR  cannot run a command on prod (host, user, key, tunnel open?)` | the tunnel is closed, the host, user or key is wrong, or the key asks for a password. Test step 4.4 by hand |
| `ERROR  <path> does not exist on prod` (script or config) | the file is not at that path on prod: upload it (section 3) or correct `PROD_EXPORT_SCRIPT` / `PROD_EXPORT_CONFIG` |
| `ERROR  cannot connect (host, port, user, database, password variable?)` | the prod database settings in `export.env`, or the `~/.pgpass` line, are wrong. Test on prod: `psql -h <host> -p <port> -U <user> -d <db> -c 'select 1'` |
| `ERROR  <schema>.<table>: table not found (or no right to see it)` | the table name in `TABLES` is wrong for prod (the names must match exactly), or the user has no right on it |
| `ERROR  <schema>.<table>: time column '<c>' not found` | the table has another time column name: set `TABLE_TIME_COLUMNS` in `export.env` |
| `ERROR  OUT_ROOT ... has only N MB free` / `does not exist or is not writable` | free space, or create the folder, or correct `PROD_OUT_ROOT` / `OUT_ROOT` |
| `ERROR  neither zip nor python3 found: cannot make the zip` | prod has neither; ask the prod admin to install one |
| `ERROR  <zip> already exists (choose another --name; nothing is overwritten)` | a zip of that name exists: use a new `--name`, or leave `--name` out |
| `ERROR  <folder> already holds files (choose another --name, or RESUME=yes ...)` | an earlier run of that name stopped: use `--resume` to continue it, or a new name |
| `FAILED the export stopped at <file>. No zip was made` | read the `ERROR` line just above it (for example `COPY failed` plus the database error); then `--resume` |
| `ERROR  <folder> has N MB free; the zip is M MB ...` | free space on UAT (`LOCAL_ZIP_DIR`) or lower `MIN_FREE_MB` only if you are sure |
| `ERROR  the copy is damaged: checksum ..., expected ...` | the copy broke on the way; it was removed. Re-run `--steps copy` |
| `ERROR  the target password variable <NAME> ... is empty: export it first` | do step 6.1 in this terminal |
| `ERROR  ... must set SOURCE_TYPE="csv"` | the db-import config must have `SOURCE_TYPE="csv"` |
| `offline bundle not found` / `bundle checksum failed` | the `bundle/` folder is missing or damaged: step 4.2 |
| `extension 'ducklake' is not in the bundle` | an older bundle: copy the complete one (step 4.2) |
| `no file for <time> to <time>` / `no CSV file ... covers the period` | the zip does not cover the whole period (an hour is missing): an export problem: re-run the export |
| `<file> has N rows but its manifest says M` | a damaged or partly copied file: copy the zip again. Nothing was written |
| `... table does not exist` (strict) | the target schema or table is missing: set `TARGET_STRUCTURE="create"` once, after `--check` |
| `TARGET_STRUCTURE=create adds the missing columns itself: do not combine it with EXTRA_SOURCE_COLUMNS=skip` | remove `EXTRA_SOURCE_COLUMNS` from the db-import config |
| `permission denied for schema/database` | the UAT user cannot create the backup schema: ask the UAT DBA, or set `BACKUP="off"` (then no backup is saved) |
| `row count check failed: expected N, found M` | the table was rolled back and nothing changed for it: run the load again |
| `not enough free space in ... for the zip` | set `CSV_WORK_DIR` in the db-import config to a folder with more free space |
| `config error: FINAL_REPORT_TITLE may hold letters, digits, space, _ and - only` | remove brackets and other signs from the title. The comparison itself finished; run the compare again with a **new** `REPORT_DIR` |
| `already exists` for the final output | a `REPORT_DIR` name was used before: set a new name in the compare config |
| `Catalog ... does not exist` (compare) | the catalog name in `OLD_CATALOG` / `NEW_CATALOG` is not attached in `~/.duckdbrc` (step 4.5) |
| `Table with name ... does not exist` (compare) | a table name in the pairs file, or `OLD_SCHEMA` / `NEW_SCHEMA`, is wrong for this environment |
| compare says `NOT COMPARABLE` | OLD and NEW have no object or period in common in your window: check the window against both sides (section 5.4) |
| `Input/output error` on the shared folder, or `No space left on device` | the disk is full or the shared mount has a problem: free space, tell the platform team |

If you cannot solve it: do **not** run the real step. Keep the folder `prod-to-uat/reports/<date_time>_<job>/` and send it with the configs.

## 10. Undo and clean up

**What each step changes:**

| Step | Changes |
|---|---|
| export | files on **prod** under `OUT_ROOT` only. The database is only read |
| copy | one file in `LOCAL_ZIP_DIR` on UAT |
| load | the rows of the period in the UAT DuckLake (after a backup). With `TARGET_STRUCTURE="create"` also new schema, tables and columns |
| compare | reads only. Writes files inside the pivot-compare folder |

**Undo a load.** Each load saved the replaced rows in the backup schema (`BACKUP_SCHEMA`), in a table named in the load output and in `summary.csv` (column `backup_table`), for example `KPI_NS_QRLY_NODE_CEM_ERS_P_bak_20261119_221541`.
To restore a table [DuckDB, with the DuckLake attached, `SET TimeZone='Australia/Sydney';` first; replace the names and the period with yours]:
```sql
BEGIN;
DELETE FROM "<TARGET_SCHEMA>"."<table>" WHERE "PERIOD_START_TIME" >= '2026-10-25 00:00' AND "PERIOD_START_TIME" < '2026-10-25 02:00';
INSERT INTO "<TARGET_SCHEMA>"."<table>" SELECT * FROM "<BACKUP_SCHEMA>"."<table>_bak_<date_time>";
COMMIT;
```
If the backup table was empty (the target had no rows for the period), the undo is only the `DELETE`.
**A created table, schema or column is not undone by the backup** (the backup holds rows, not structure). The exact statements are in `structure_changes.sql` in the db-import run folder; drop them by hand only after checking that nothing else uses them.
Backup tables are not removed automatically: `DROP TABLE "<BACKUP_SCHEMA>"."<table>_bak_<date_time>";` when you no longer need one.

**Clean up** (only things this flow made; nothing else): the old zips in `PROD_OUT_ROOT` on prod and in `LOCAL_ZIP_DIR` on UAT, the old run folders in `prod-to-uat/reports/`, the old report folders and `tmp/` content in `pivot-compare/`.

## 11. Checklist

**Once**
- [ ] The values of section 2 are collected; the tunnel is open
- [ ] PROD: `export-on-prod.sh` and `export.env` uploaded, `dos2unix` done, `~/.pgpass` has the line, the manual export `--check` ends with `everything is fine`
- [ ] UAT: the three tools uploaded side by side, `dos2unix` done, `db-import/bundle/` is complete (step 4.2)
- [ ] UAT: both self-tests show `failed: 0`; the SSH test prints `ok` (step 4.4); the catalog is listed (step 4.5)
- [ ] The four configs are created and edited (section 5); the pairs file lists only the exported tables

**Every run**
- [ ] `read -rs TARGET_PGPASSWORD; export TARGET_PGPASSWORD` is done in this terminal
- [ ] `./run-all.sh --check configs/<job>.env` ends with `everything is fine`, every table has an `OK` line with its rows
- [ ] `./run-all.sh --dry-run configs/<job>.env` was read: every table `DRY-RUN OK (rolled back)`
- [ ] A new `REPORT_DIR` is set in the compare config
- [ ] `./run-all.sh configs/<job>.env`: every step `OK`; exit code 0, 3 or 4 (an answer), never 1 or 2
- [ ] The final output zip exists and `unzip -t` says `No errors detected`
- [ ] The zip name, its checksum and the final output zip are noted, and sent back with the run's report folder
