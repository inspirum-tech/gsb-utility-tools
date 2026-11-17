# db-import runbook (UAT / prod)

For the person who runs the import. You do not need anyone's help: follow the steps in order.
Short description of the tool: [README.md](README.md). Evidence of what was tested: [docs/EVIDENCE.md](docs/EVIDENCE.md).

**What it does.** Copies the rows of one or more tables, for one time period, from a *source* database to a *target* database.
The source is only read. In the target, the rows of that period are replaced (after a backup of them). Each table is one transaction:
if anything is wrong (a row count that does not match, an error) the table is rolled back and nothing is left half done.

Example: the target `KPI_NS_QRLY_NODE_CEM_ERS_P` has 100 rows for 25 Oct 00:00 to 02:00, the source has 120.
After the run the target has 120 rows for that period, the 100 old rows are saved in a backup table, and everything outside that period is untouched.

You run it in three steps, always in this order:

| Step | Command | Changes anything? |
|---|---|---|
| 1. Check | `./db-import.sh --check configs/<job>.env` | No. Reads and counts only |
| 2. Dry run | `./db-import.sh --dry-run configs/<job>.env` | No. Does everything, then rolls back |
| 3. Real run | `./db-import.sh configs/<job>.env` | **Yes** |

---

## 1. What the server needs

| You want to copy | Needs on the machine that runs the tool |
|---|---|
| Postgres -> Postgres | `bash` 4 or newer and `psql`. Nothing else |
| anything with DuckDB, DuckLake or parquet | `bash` 4 or newer and the `bundle/` folder (it contains the DuckDB program and its extensions) |
| a source read through the Flight SQL API (`flightsql`, section 3.5) | the same, plus `python3`, and the Python packages in `bundle/pylibs` (built with `./prepare-bundle.sh --with-flightsql`) |
| a zip downloaded from prod (`csv`, section 3.6) | the same as for DuckDB / DuckLake (the `bundle/`), plus `unzip` or `python3` to open a zip, and free disk space of about the zip's size. No connection to prod |

Check: `bash --version | head -1` and `psql --version`. No internet is needed, ever.
The machine must be able to reach both databases (host and port). It can be a machine other than the database servers.
**DuckLake needs more than the connection:** the metadata Postgres is reached by host and port (a tunnel is fine), but DuckDB reads and writes the DuckLake parquet files itself, straight from the data folder (`*_DUCKLAKE_DATA_PATH`).
So the machine that runs the tool must also be able to open the source data folder (read) and the target data folder (write). A tunnel does not carry those files. See section 3.2. If the source is on another network, read it through its Flight SQL API instead (section 3.5).

Permissions of the database user:

| Where | Needs |
|---|---|
| source | read (SELECT) on the tables |
| target | SELECT, INSERT, DELETE on the tables. With `BACKUP="on"` also the right to create the backup schema and tables (CREATE on the database) |

If the user cannot create the backup tables, ask your DBA for the right, or set `BACKUP="off"` (see section 6; no backup is then saved).

## 2. Put the tool on the server (once)

1. Copy the whole `db-import` folder to the server (upload from your PC, or copy from another server). Example target: `/mnt/mfs/gsb_application/gsb-utility-tools/db-import/`.
2. Files that come from a Windows PC can have Windows line endings, which breaks bash scripts. Always run:
   ```bash
   cd <the db-import folder>
   dos2unix db-import.sh prepare-bundle.sh config.example.env tests/*.sh
   chmod +x db-import.sh prepare-bundle.sh tests/*.sh
   grep -c $'\r' db-import.sh        # must print 0
   bash -n db-import.sh && echo SYNTAX_OK
   ```
3. Optional self-test of the logic (no database needed): `bash tests/test_functions.sh | tail -1` prints `passed: <N>   failed: 0` (N is the number of checks, about 230; `failed` must be 0).
4. **If DuckDB / DuckLake / parquet is involved:** the `bundle/` folder must be inside the `db-import` folder.
   It is built once on **dev** (the only machine with internet) by someone with dev access: `./prepare-bundle.sh --tar`, which writes
   `db-import-bundle-<version>-<date>.tar.gz` and a `.sha256`. Copy both to the server, then:
   ```bash
   sha256sum -c db-import-bundle-<version>-<date>.tar.gz.sha256        # must say: OK
   tar -xzf db-import-bundle-<version>-<date>.tar.gz                   # creates ./bundle
   ```
   (Or simply copy the whole `db-import` folder from dev with `bundle/` in it.) The tool checks the bundle itself on every run (checksums and DuckDB version) and stops if it is damaged or incomplete.
   For Postgres -> Postgres no bundle is needed.
   **Never run `prepare-bundle.sh` on UAT or prod:** it downloads the extensions, so it needs internet. Run it once on dev (or any machine with internet and the same DuckDB version), then copy `bundle/` over.
   The extensions only work with the exact DuckDB version they were built for (dev and UAT both have v1.5.5). The tool uses `bundle/duckdb` when it exists; the `DUCKDB=<path>` setting is used only when there is no `bundle/duckdb`
   (a `DUCKDB=...` line typed on its own in the terminal is not seen by the script: use `export DUCKDB=...` or put it in front of the command). Using the server's own CLI instead of `bundle/duckdb` was not tested.
5. **Only for a `flightsql` source:** the bundle must also hold the Python packages (`bundle/pylibs`). On the machine with internet run once `./prepare-bundle.sh --tar --with-flightsql`
   (it needs `python3` and `pip`, installs pyarrow, adbc-driver-flightsql and adbc-driver-manager into `bundle/pylibs`, saves the Python version in `bundle/pylibs/PYVERSION` and proves they load with an empty home folder).
   **Use the same Python minor version as the server that will run the tool** (check `python3 --version` there): the packages only work with the Python they were built for, and the tool refuses to run otherwise.
   `pylibs` is large (about 170 MB unpacked on dev), so the copy takes a while. The tool checks it with the other bundle checksums.

## 3. Create the config for your job

One config file per job. It holds no passwords.

```bash
cp config.example.env configs/prod_to_uat.env
vi configs/prod_to_uat.env
```

Fill in the sections below. Rules for the file: plain `NAME="value"` lines, no spaces around `=`, lines starting with `#` are comments.

### 3.1 The source and the target

| Setting | Meaning |
|---|---|
| `SOURCE_TYPE` / `TARGET_TYPE` | `postgres`, `duckdb` (a .duckdb file), `ducklake`; a source can also be `parquet`, `flightsql` (the source environment's API, section 3.5) or `csv` (a zip downloaded from prod, section 3.6) |
| `TARGET_ENV` | `dev`, `uat` or `prod`. **Set it to the real environment of the target.** With `prod` the tool asks you to type the database name before it writes |
| `*_HOST`, `*_PORT`, `*_DB`, `*_USER` | the Postgres connection. For `ducklake` these are the connection of the Postgres database that holds the DuckLake metadata (database `ducklake`) |
| `*_SCHEMA` | the schema of the tables (Postgres schema, or `main` for a .duckdb file, or the DuckLake schema) |
| `*_PASSWORD_ENV` | the **name** of an environment variable that holds the password (section 4). Empty = use `~/.pgpass` |
| `SOURCE_DB_FILE` / `TARGET_DB_FILE` | path of the .duckdb file (type `duckdb`) |
| `*_DUCKLAKE_DATA_PATH`, `*_DUCKLAKE_METADATA_SCHEMA` | DuckLake only: the data folder (`/mnt/mfs/gsb_data/duckdb/ducklake` on dev) and the metadata schema (`metadata`) |
| `SOURCE_PARQUET_GLOB` | parquet only, e.g. `/data/export/{TABLE}/*.parquet` (`{TABLE}` is replaced by the table name) |
| `SOURCE_CSV_PATH` | csv only: the zip, the unzipped folder, or a folder of zips (section 3.6). A csv source has no host, schema or password: only the `TARGET_*` settings are needed |

Notes:
- **Always give a real `*_HOST` when DuckDB / DuckLake is involved.** An empty host (local socket) was tested only for Postgres -> Postgres; the DuckDB paths were tested over the network (host and port) only.
- Hosts and schemas differ per environment. Use the values of that environment; do not copy dev's. Known: dev Postgres `192.168.50.218`, UAT Postgres `10.201.170.205`
  (the counter-def tool uses these). **Confirm every host, database and schema with the environment owner**: the DuckLake schema on dev is `gsb_data_kpi_pivot_dev_V2` (with `_V2`).

### 3.2 DuckLake to DuckLake, and DuckLake across environments (tunnel, data folder)

DuckLake has two parts: the metadata (a Postgres database, reached with `*_HOST`, `*_PORT`, `*_DB`) and the parquet data files (a folder, `*_DUCKLAKE_DATA_PATH`).
The catalog stores the file paths (for example `/abc/parquet.file`), and DuckDB opens those paths directly. **The tool assumes the machine that runs it can open both data folders.** On dev this is true (`/mnt/mfs` is shared).

If there is no direct route (for example UAT cannot reach prod) a tunnel solves only the metadata part: put the tunnel address in `SOURCE_HOST` / `SOURCE_PORT`. It does not help with the files.
If the source data folder exists only on another server, use one of these (config and setup only, no code change):

| Option | How |
|---|---|
| A | Make the source data folder visible on the machine that runs the tool, read-only, **at the same path** (a mount; ask the infrastructure team). Then DuckLake to DuckLake runs as one import |
| B | Two steps with a DuckDB file in between. Step 1, on the source side: DuckLake -> `duckdb` file (`TARGET_TYPE="duckdb"`, `TARGET_DB_FILE=...`). Step 2: copy the file to the target side. Step 3, on the target side: `duckdb` file -> DuckLake. Each step is a tested combination; the chain with a real prod and UAT was not run |
| C | **When the networks are separated (UAT cannot reach prod): read the source through its Flight SQL API** (`SOURCE_TYPE="flightsql"`, section 3.5). Only a tunnel to the API port is needed; no data folder, no metadata Postgres of the source. Tested on dev against the dev API |
| D | **When the data is downloaded from prod as a zip and copied to UAT: load the zip** (`SOURCE_TYPE="csv"`, section 3.6). No connection to prod at all. Tested on dev |

Tested on dev: DuckLake to DuckLake inside one catalog (two different schemas, one DuckDB session with both attached). Two separate catalogs (prod and UAT) were not tested.

### 3.3 What to copy

| Setting | Meaning | Example |
|---|---|---|
| `TABLES` | comma separated, new lines allowed. `A=B` means source table A goes into target table B | `TABLES="KPI_NS_QRLY_CELL_LTE_ERS_P,KPI_NS_QRLY_NODE_CEM_ERS_P"` |
| `PERIOD_FROM`, `PERIOD_TO` | the period: `PERIOD_FROM <= time column < PERIOD_TO`. `PERIOD_TO` itself is **not** included. With a csv source both can be `"auto"`: every row of the files (section 3.6) | see below |
| `TIME_COLUMN` | the time column (default `PERIOD_START_TIME`) | |
| `TIMEZONE` | the time zone the period is written in. **Use `Australia/Sydney` for the gsb data** | `TIMEZONE="Australia/Sydney"` |

Period formats (nothing else is accepted):

| You write | Meaning |
|---|---|
| `2026-10-25` | 25 Oct 00:00:00 |
| `2026-10-25 06:00` or `2026-10-25 06:00:00` | that exact time |

Examples: all of 25 Oct and 26 Oct = `PERIOD_FROM="2026-10-25"` and `PERIOD_TO="2026-10-27"`. Two hours = `"2026-10-25 00:00"` to `"2026-10-25 02:00"`.

Why `TIMEZONE` matters: some tables store the time with a time zone (the DuckLake NEW pivot tables do, shown as `+11`) and others without (the Postgres OLD ones).
`TIMEZONE` makes the period and the copied values mean the same thing in both. Without the right zone the values can shift by 11 hours.

The tool needs the same column names on both sides: every column of the source table must exist in the target table (the target may have extra columns, which get their default).
The target table must already exist. Only with a csv source and `TARGET_STRUCTURE="create"` (section 3.6) does the tool create the missing schema, tables and columns itself.

### 3.4 How it behaves

| Setting | Values | Meaning |
|---|---|---|
| `LOAD_MODE` | `replace` (default) | delete the target rows of the period, then insert the source rows. Safe to run again |
| | `append` | only insert. Running twice gives duplicate rows |
| | `stop` | refuse if the target already has rows for the period |
| `BACKUP` | `on` (default) / `off` | on: the replaced rows are first saved in the **target database** as `<BACKUP_SCHEMA>."<table>_bak_<date_time>"`. off: no backup, a warning is printed |
| `BACKUP_SCHEMA` | default `import_backup` | the schema for the backup tables |
| `ON_ERROR` | `stop` (default) / `continue` | stop at the first failed table, or go on with the next one (the failed table is rolled back either way) |
| `FULL_COPY_TABLES` | table names | for a table with **no time column** that must be replaced whole. A table without the time column that is not listed stops the run |
| `TABLE_TIME_COLUMNS` | `TABLE:COLUMN,TABLE:COLUMN` | only for a table whose time column has a different name |
| `OFFLINE` | `yes` (default) / `no` | yes: DuckDB uses only `bundle/` (leave it `yes` on UAT and prod) |
| `DUCKDB` | path | only if you must use another DuckDB program; `bundle/duckdb` is used first |
| `REPORT_DIR` | folder | where each run writes its report (default `./reports`). Must be writable by the user who runs the tool |

### 3.5 Reading through the Flight SQL API (`SOURCE_TYPE="flightsql"`)

**When to use it.** The source database's data files cannot be reached from this machine (for example prod from UAT: the networks are separated), but you can reach the **gsb-kpi-data-api** of the source environment, usually through a tunnel to its Flight SQL port (8815 by default).
The tool asks the API for the period in small time slices, saves them as parquet files on this machine, then imports those files into the target (same backup, one transaction, row-count check and `--dry-run` as always).

**What it needs**

| Need | Detail |
|---|---|
| The API | its Flight SQL listener must be on (`FLIGHTSQL__ENABLED=true`) and reachable from this machine, directly or through a tunnel. It has no login and no TLS: the tunnel is the protection. Check the port: `bash -c '</dev/tcp/localhost/8815' && echo open` |
| Python 3 | `python3` on this machine, and the packages in `bundle/pylibs` (pyarrow, adbc-driver-flightsql, adbc-driver-manager). Nothing is installed from the internet: on UAT / prod copy the `bundle/` built with `./prepare-bundle.sh --with-flightsql` (section 2) |
| The target | any target the tool supports (tested: DuckLake). Its tables must exist, as always |
| Disk space | the exported parquet files stay in `EXPORT_DIR` (see below) |

**Settings** (add them to the config; the target side is as in any other job)

| Setting | Meaning | Default |
|---|---|---|
| `SOURCE_TYPE="flightsql"` | read through the API | |
| `SOURCE_HOST`, `SOURCE_PORT` | the API, or the local address and port of the tunnel to it | |
| `SOURCE_SCHEMA` | the schema on the API, e.g. `gsb_data_kpi_pivot` | |
| `TABLES`, `PERIOD_FROM`, `PERIOD_TO`, `TIMEZONE` | as for every job (`TIMEZONE="Australia/Sydney"`) | |
| `FLIGHT_MAX_ROWS` | the API's row cap (`FLIGHTSQL__MAX_ROWS` on the API: ask its owner). A slice that returns this many rows **or more** fails the table, because the API cuts a bigger result silently | 100000 |
| `FLIGHT_SLICE_MINUTES` | length of one time slice | 10 |
| `FLIGHT_PAUSE_SECONDS` | wait between two slices, so the API (which prod users share) is not loaded | 2 |
| `FLIGHT_TIMEOUT_SECONDS` | time limit of one query | 120 |
| `EXPORT_DIR` | where the parquet files go, as `<EXPORT_DIR>/<TABLE>/*.parquet` | `reports/<run>/export` |
| `EXPORT_KEEP` | `yes` keeps the files after the run, so the same data can be imported again without asking the API; `no` removes them at the end | `yes` |
| `EXPORT_OVERWRITE` | `yes` replaces an earlier export of the same table in `EXPORT_DIR`; `no` refuses (an old copy is never mixed with a new one) | `no` |
| `PYTHON` | the Python program | `python3` |

There is no `SOURCE_PASSWORD_ENV` for this source (the API has no login). The time column is found by name, upper or lower case (`TIME_COLUMN`, default `PERIOD_START_TIME`; `TABLE_TIME_COLUMNS` for another name).

**What a run does**
1. `--check`: for each table the API is asked for its structure and one row count for the period. Nothing is exported and nothing is written.
2. The plan is printed (and, for a prod target, you confirm). Only then the export starts: one slice at a time, with a pause, into `EXPORT_DIR`.
3. The exported files are imported like a parquet source. The row-count check uses the number of rows that were really exported.

**Run it in two steps, or later again**
- Only fetch the data, touching no database (the `TARGET_*` settings are not used and no target password is needed): `./db-import.sh --export-only configs/<job>.env`. The files are kept.
- Import kept files later, with no new load on the API: a normal job with `SOURCE_TYPE="parquet"`, `SOURCE_SCHEMA="main"` and `SOURCE_PARQUET_GLOB="<EXPORT_DIR>/{TABLE}/*.parquet"`.
- A `--dry-run` also exports (it needs the real data). If you then run the real step with the same fixed `EXPORT_DIR`, the tool refuses because the files exist: set `EXPORT_OVERWRITE="yes"`, or leave `EXPORT_DIR` empty so every run gets its own folder, or import the kept files as described above.

**Good to know**
- The time filter is built by the tool from the period (as exact UTC instants for columns with a time zone, as local time for columns without one). It is not the API's own time conversion, which shifts a plain filter by 11 hours on some tables. You do not need to do anything.
- The query is always `SELECT * FROM <schema>."<table>" WHERE <time column> in the slice`. You choose tables and period; you cannot add other filters.
- Only a time column of type timestamp is supported. Another type, or a table without the column, stops the run with a message.
- The row cap: pick `FLIGHT_SLICE_MINUTES` so that one slice is far below `FLIGHT_MAX_ROWS`. If it still fails, lower it. The data of one single time stamp cannot be split further.

### 3.6 Loading the downloaded CSV files (`SOURCE_TYPE="csv"`)

**When to use it.** The data was downloaded from prod as a zip (nothing connects UAT to prod). A teammate puts the zip on this server and the tool loads it, instead of inserting the CSV files by hand. There is no connection to prod at all: no tunnel, no API.
**Upload the zip as ONE file** (bulk is much quicker than many small files). An already unzipped folder works too.

**What the zip looks like** (the NSTD download): one folder per table, one `.csv.gz` file per time range, and a `_manifest.csv` (`file,rows`) in each folder:

```
export_nonstd.zip
  export_nonstd/NODE_EPNGU/KPI_NS_QRLY_NODE_EPNGU_ERS_P_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz
  export_nonstd/NODE_EPNGU/..._01_00_00__to__..._02_00_00.csv.gz
  export_nonstd/NODE_EPNGU/_manifest.csv
  export_nonstd/___All_Errors.txt        <- what the download could not fetch (only shown by the tool)
```

The **table name is read from the file name** (`KPI_NS_QRLY_NODE_EPNGU_ERS_P`), not from the folder, so any family of tables works. Files that do not follow this name pattern stop the run.

**Settings** (the target side is as in any other job)

| Setting | Meaning | Default |
|---|---|---|
| `SOURCE_TYPE="csv"` | read the downloaded files | |
| `SOURCE_CSV_PATH` | the `.zip` file, the folder with the unzipped files, or **a folder that holds several `.zip` files** (see "Several zips in one folder" below) | |
| `TABLES` | `"auto"` = every table found in the files for the period, or a list as usual (`SOURCE_NAME=TARGET_NAME` when the target is named differently) | |
| `PERIOD_FROM`, `PERIOD_TO` | a date or time as for every job, or **`"auto"`**: from the first / to the last row of each table's files. With both `"auto"` the whole content of the zip is loaded, and only the target rows of that same range are replaced (each table uses its own range). A fixed date loads only that part of the files | |
| `TIMEZONE` | `"Australia/Sydney"`: the times in the files are Sydney local time | `UTC` |
| `TARGET_*` | the DuckLake target (see example E). `TARGET_SCHEMA` can be an existing schema or a new one (see `TARGET_STRUCTURE`) | |
| `TARGET_STRUCTURE` | `strict`: the schema, tables and columns must already fit, otherwise the run stops. `create`: the data is the truth, the target follows it (see below) | `strict` |
| `CSV_COLUMN_TYPES` | types for NEW tables and columns: `COLUMN=TYPE; ...`, first matching rule wins, `*` matches any characters | the types of the real `_ERS_P` pivot tables |
| `EXTRA_SOURCE_COLUMNS` | with `strict`: the data has columns the table lacks: `error` stops and lists them, `skip` loads only the columns the table has (listed in `skipped_columns.txt`). Not allowed together with `create` | `error` |
| `CSV_WORK_DIR` | where a zip is unzipped. **The root disk of a server can be small:** the zip needs about its own size free here | the run's temp folder (`/tmp`) |
| `CSV_KEEP_EXTRACTED` | `yes` keeps the unzipped files after the run (a folder you gave is never removed) | `no` |
| `CSV_CHECK_MANIFEST` | compare the rows of each file with its `_manifest.csv` (reads every file once more) | `yes` |
| `CSV_INCOMPLETE` | `error` stops when the period is not fully covered or a count differs; `warn` only warns | `error` |

**Checks before anything is written** (all printed by `--check`)
1. Every table has files that cover the whole period with no gap and no overlap (`no file for 2026-10-25 03:15:00 to 2026-10-25 04:00:00` names a missing time).
2. The rows of each file equal its `_manifest.csv` line (a damaged or partly copied file is caught here).
3. The download's own error list (`___All_Errors.txt`) is printed, so you can see what was not downloaded.
4. The usual checks: the time column, the target, the row counts and the backup.

**`TARGET_STRUCTURE="create"`: the prod data is the source of truth.** After the import the target holds exactly the columns and rows of the files:

| Situation | What the tool does |
|---|---|
| schema and table exist, same columns | loads, as always |
| the table lacks columns the files have | **adds the columns**, then loads all of them (CSV has `A, B, C, D`, the table `A, B, C`: `D` is added) |
| the table has columns the files lack | leaves them (empty values); nothing is ever dropped |
| the table does not exist | **creates the table** from the file's columns |
| the schema does not exist | **creates the schema**, then the tables |

- `--check` prints every change (`TARGET_STRUCTURE=create: ... new table (8 columns)` or `1 column(s) added: K_-68`) and saves the exact statements in `<report folder>/structure_changes.sql`. `summary.csv` has a `structure` column.
- The statements run in the **same transaction as the data, after the backup**: `--dry-run` rolls them back too (proven on DuckLake), and the backup of the old rows is taken before any column is added.
- **A created table or an added column stays after a real run.** The backup holds the old rows, not the old structure. That is why the default is `strict`: set `create` on purpose, and always run `--check` first (a typo in `TARGET_SCHEMA` would otherwise create a new schema).
- Types of new tables and columns: `PERIOD_START_TIME` and `UPDATE_TIMESTAMP` timestamp, `SITE_ID` and `CELL_ID` integer, `LAC` and `SAC` `DECIMAL(4,2)`, `TAC` `DECIMAL(10,2)`, `K_*` `DECIMAL(30,10)`, everything else text: the types of the real `_ERS_P` tables. Existing columns keep their own type. A value that does not fit a type makes the run fail and roll back, never lose data silently.
- Only with `SOURCE_TYPE="csv"` for now.

**Several zips in one folder.** Set `SOURCE_CSV_PATH` to a **folder that holds `.zip` files** (any number: 2, 5, 8 ...). The logic is the same for every count:
1. The zips are taken in **name order**. To choose the order, name them `01_nstd.zip`, `02_other.zip`, and so on.
2. Before anything is imported, the tool looks into every zip (it unzips nothing) and **refuses the run** when the same table and time range is in more than one zip (the second zip would overwrite the first), or when the zips together leave a gap. The same table in two zips with different time ranges is fine.
3. Then one zip after the other is run as a **full job of its own**: unzip, checks, import, remove the unzipped files, next zip. The report folders are named `<time>_<job>_01_<zip name>`, `..._02_...`. Only one zip is unzipped at a time, so the disk needs the size of the biggest zip, not of all of them.
4. It **stops at the first failure**. The zips before it stay loaded, the zips after it are not touched. The last lines list every zip and its result.
- `TABLES` can list tables from different zips: each zip loads only the tables that are in it. A table that is in none of the zips stops the run before anything is imported.
- `--check` and `--dry-run` also go through all the zips (one after the other), so check the whole folder before the real run.
- A fixed period can span several zips: each zip loads only its own part of the period, and the check that the zips together cover the whole period is done first.
- Put only the zips you want in the folder: every `.zip` in it is imported.

**Good to know**
- Every column is read as text and cast to the target type on insert, so `DECIMAL(30,10)` counters keep every digit.
- The times are loaded as written (Sydney local time). A plain `timestamp` target keeps them as written; a `timestamptz` target uses `TIMEZONE`. The hour that happens twice when the clocks go back (April) cannot be told apart in plain text: check that hour by hand on a `timestamptz` target.
- Re-running the same job is safe: `replace` backs up and replaces the rows of the period.
- Run it in the usual order: `--check`, `--dry-run`, then the real run.

## 4. Passwords

Passwords are never written in the config. Two ways:

**A. Environment variables** (the config names them, you set them in your terminal before the run; this prompt does not show what you type):
```bash
read -rs SOURCE_PGPASSWORD; export SOURCE_PGPASSWORD      # type the source password, press Enter
read -rs TARGET_PGPASSWORD; export TARGET_PGPASSWORD      # type the target password, press Enter
```
and in the config: `SOURCE_PASSWORD_ENV="SOURCE_PGPASSWORD"` and `TARGET_PASSWORD_ENV="TARGET_PGPASSWORD"`.
The variable must be set in the **same terminal** where you run the tool; it is gone when you close it.

**B. `~/.pgpass`** of the user who runs the tool (a line `host:port:database:user:password`, `chmod 600`). Leave `*_PASSWORD_ENV=""`.

The plain `PGPASSWORD` variable is ignored on purpose, so that two databases never share one password by mistake.
A `flightsql` or `csv` source has no password (the API has no login; a zip has none): only the target password is needed.

## 5. Run

```bash
cd <the db-import folder>
./db-import.sh --check configs/prod_to_uat.env
```
Read the table it prints, one line per table:

```
#    SOURCE TABLE                  TARGET TABLE                  MODE     SOURCE ROWS  TARGET ROWS  BACKUP
1    KPI_NS_QRLY_NODE_CEM_ERS_P    KPI_NS_QRLY_NODE_CEM_ERS_P    window         80445            5  KPI_NS_QRLY_NODE_CEM_ERS_P_bak_20261112_230041
```
- `SOURCE ROWS` = rows that will be copied. `TARGET ROWS` = rows in the target for the period now (they will be replaced).
- Check that the period line (`period: ... <= PERIOD_START_TIME < ...  (time zone: ...)`), the table names and the row counts are what you expect. If a number looks wrong, stop and fix the config. Nothing has been changed.

Then:
```bash
./db-import.sh --dry-run configs/prod_to_uat.env
```
It must end with `DRY-RUN OK (rolled back): target rows in the period 5 -> 80445 (source 80445), backup rows 5` for each table and `finished: all tables OK`.
This did the whole work (backup, delete, insert, row-count check) and then rolled it all back. The database is as it was.

Then the real run:
```bash
./db-import.sh configs/prod_to_uat.env
```
- If `TARGET_ENV="prod"` it asks: *"Type the target database name to continue"*. Type it exactly (for example `gsb`). For an unattended run add `--yes` (the confirmation is skipped).
- Each table ends with `OK: target rows in the period 5 -> 80445 (source 80445), backup rows 5, 0s`.
- The last line must be `finished: all tables OK`. The exit code is 0.

Tables are done one after the other, each in its own transaction. If one fails it is rolled back (the target keeps its old rows for that table), the tool stops (or continues with the next if `ON_ERROR="continue"`), and the exit code is 1.

### After the run: what to look at

Each run writes a folder `reports/<date_time>_<job>/` with:

| File | Contents |
|---|---|
| `run.log` | everything that was printed |
| `summary.csv` | per table: rows in the source, rows in the target before and after, the backup table and its rows, status, seconds, and (csv) what was created or added in the target |
| `structure_changes.sql` | only with `TARGET_STRUCTURE="create"`: the exact `CREATE SCHEMA` / `CREATE TABLE` / `ALTER TABLE ... ADD COLUMN` statements of the run (also written by `--check`) |
| `skipped_columns.txt` | only with `EXTRA_SOURCE_COLUMNS="skip"`: the columns that were not loaded |
| `config_used.env` | a copy of the config (no secrets) |

Optional proof in SQL (Postgres target). The rows of the period must equal the source:
```sql
SELECT count(*) FROM gsb_data."KPI_NS_QRLY_NODE_CEM_ERS_P"
WHERE "PERIOD_START_TIME" >= '2026-10-25 00:00' AND "PERIOD_START_TIME" < '2026-10-25 02:00';
```

## 6. Changing the config: what to edit for what you want

Always edit the config file (`vi configs/<job>.env`), then run `--check` again.

| I want to ... | Change |
|---|---|
| import another period | `PERIOD_FROM` and `PERIOD_TO` |
| import more or other tables | `TABLES` |
| import into a table with another name | `TABLES="SOURCE_NAME=TARGET_NAME"` |
| point at another environment | `SOURCE_HOST`, `SOURCE_DB`, `SOURCE_SCHEMA`, the same for `TARGET_*`, and **`TARGET_ENV`** |
| not take a backup | `BACKUP="off"` (the tool prints a warning; the replaced rows are lost) |
| add rows without deleting | `LOAD_MODE="append"` (running it twice duplicates rows) |
| refuse if the period already has rows | `LOAD_MODE="stop"` |
| copy a table that has no time column | `FULL_COPY_TABLES="TABLE_NAME"` (the **whole** target table is replaced) |
| a table whose time column has another name | `TABLE_TIME_COLUMNS="TABLE_NAME:COLUMN_NAME"` |
| go on with the other tables when one fails | `ON_ERROR="continue"` |
| write the reports somewhere else | `REPORT_DIR="/path/you/can/write"` |
| run without the question on prod | add `--yes` to the command |
| a second job | copy the config to a new name, e.g. `cp configs/prod_to_uat.env configs/prod_to_dev.env`, and edit that |
| load a zip downloaded from prod | `SOURCE_TYPE="csv"` and `SOURCE_CSV_PATH="/path/to/file.zip"` (example E, section 3.6) |
| load every table and every row of the zip | `TABLES="auto"`, `PERIOD_FROM="auto"`, `PERIOD_TO="auto"` (csv only) |
| load several zips in one go | put the zips in one folder and set `SOURCE_CSV_PATH` to the folder; they run in name order (`01_...`, `02_...`) |
| load into a schema that does not exist yet, or into tables that lack columns | `TARGET_STRUCTURE="create"` (csv only; run `--check` first: it lists what will be created) |
| load into another schema | `TARGET_SCHEMA="<schema>"` (all zips of the run go to this one schema) |
| the root disk is small | `CSV_WORK_DIR="/folder/with/space"` (where the zip is unzipped) |

## 7. Example configs

**A. Postgres -> Postgres** (e.g. a source Postgres into a UAT Postgres; hosts and schemas are examples, use your own)
```bash
JOB_NAME="pg_to_uat"
SOURCE_TYPE="postgres"
SOURCE_HOST="<source host>"
SOURCE_PORT="5432"
SOURCE_DB="gsb"
SOURCE_USER="postgres"
SOURCE_PASSWORD_ENV="SOURCE_PGPASSWORD"
SOURCE_SCHEMA="gsb_data_kpi_pivot"
TARGET_TYPE="postgres"
TARGET_ENV="uat"
TARGET_HOST="10.201.170.205"
TARGET_PORT="5432"
TARGET_DB="gsb"
TARGET_USER="postgres"
TARGET_PASSWORD_ENV="TARGET_PGPASSWORD"
TARGET_SCHEMA="gsb_data_kpi_pivot"
TABLES="KPI_NS_QRLY_NODE_CEM_ERS_P"
PERIOD_FROM="2026-10-25"
PERIOD_TO="2026-10-26"
TIMEZONE="Australia/Sydney"
```

**B. DuckLake -> Postgres** (the DuckLake password is the password of the metadata Postgres)
```bash
JOB_NAME="ducklake_to_pg"
SOURCE_TYPE="ducklake"
SOURCE_HOST="<metadata Postgres host>"
SOURCE_PORT="5432"
SOURCE_DB="ducklake"
SOURCE_USER="postgres"
SOURCE_PASSWORD_ENV="SOURCE_PGPASSWORD"
SOURCE_DUCKLAKE_DATA_PATH="<DuckLake data path>"
SOURCE_DUCKLAKE_METADATA_SCHEMA="metadata"
SOURCE_SCHEMA="gsb_data_kpi_pivot_dev_V2"
TARGET_TYPE="postgres"
TARGET_ENV="uat"
TARGET_HOST="<target host>"          # give a real host here (tested over the network only)
TARGET_PORT="5432"
TARGET_DB="gsb"
TARGET_USER="postgres"
TARGET_PASSWORD_ENV="TARGET_PGPASSWORD"
TARGET_SCHEMA="gsb_data_kpi_pivot"
TABLES="KPI_NS_QRLY_NODE_CEM_ERS_NEW_P"
PERIOD_FROM="2026-10-25"
PERIOD_TO="2026-10-26"
TIMEZONE="Australia/Sydney"
OFFLINE="yes"
```

**C. DuckDB file -> DuckDB file** (no password, no extension)
```bash
JOB_NAME="duck_to_duck"
SOURCE_TYPE="duckdb"
SOURCE_DB_FILE="/path/to/source.duckdb"
SOURCE_SCHEMA="main"
TARGET_TYPE="duckdb"
TARGET_ENV="dev"
TARGET_DB_FILE="/path/to/target.duckdb"
TARGET_SCHEMA="main"
TABLES="KPI_NS_QRLY_NODE_CEM_ERS_NEW_P"
PERIOD_FROM="2026-10-25"
PERIOD_TO="2026-10-26"
TIMEZONE="Australia/Sydney"
OFFLINE="yes"
```
A .duckdb file can be opened by one program at a time: nobody else may have the target file open while you run.

**D. Prod API (Flight SQL, through a tunnel) -> UAT DuckLake** (the tunnel from this machine to the prod API listens on `localhost:8815`)
```bash
JOB_NAME="prod_api_to_uat_ducklake"
SOURCE_TYPE="flightsql"
SOURCE_HOST="localhost"                # the tunnel
SOURCE_PORT="8815"
SOURCE_SCHEMA="gsb_data_kpi_pivot"
TARGET_TYPE="ducklake"
TARGET_ENV="uat"
TARGET_HOST="<UAT metadata Postgres host>"
TARGET_PORT="5432"
TARGET_DB="ducklake"
TARGET_USER="postgres"
TARGET_PASSWORD_ENV="TARGET_PGPASSWORD"
TARGET_DUCKLAKE_DATA_PATH="<UAT DuckLake data path>"
TARGET_DUCKLAKE_METADATA_SCHEMA="metadata"
TARGET_SCHEMA="gsb_data_kpi_pivot"
TABLES="KPI_NS_QRLY_NODE_CEM_ERS_NEW_P"
PERIOD_FROM="2026-10-25"
PERIOD_TO="2026-10-25 02:00"
TIMEZONE="Australia/Sydney"
FLIGHT_MAX_ROWS="100000"               # the API's real cap
FLIGHT_SLICE_MINUTES="10"
FLIGHT_PAUSE_SECONDS="2"
EXPORT_KEEP="yes"
OFFLINE="yes"
```
Only `TARGET_PASSWORD_ENV` needs a password. Run `--check`, then `--dry-run`, then the real run, as always.

**E. A zip downloaded from prod -> UAT DuckLake** (no connection to prod at all; the zip was copied to this server)
```bash
JOB_NAME="uat_load_nstd_zip"
SOURCE_TYPE="csv"
SOURCE_CSV_PATH="/data/upload/export_nonstd.zip"   # a .zip, an unzipped folder, or a FOLDER OF ZIPS (imported in name order)
TARGET_TYPE="ducklake"
TARGET_ENV="uat"
TARGET_HOST="<UAT metadata Postgres host>"
TARGET_PORT="5432"
TARGET_DB="ducklake"
TARGET_USER="postgres"
TARGET_PASSWORD_ENV="TARGET_PGPASSWORD"
TARGET_DUCKLAKE_DATA_PATH="<UAT DuckLake data path>"
TARGET_DUCKLAKE_METADATA_SCHEMA="metadata"
TARGET_SCHEMA="gsb_data_kpi_pivot"     # an existing schema, or a new one (created when TARGET_STRUCTURE="create")
TABLES="auto"                          # every table found in the zip; or a list
PERIOD_FROM="auto"                     # every row in the files; or real dates for only a part
PERIOD_TO="auto"
TARGET_STRUCTURE="create"              # create missing schema / tables / columns so the target equals the data; "strict" = stop instead
TIMEZONE="Australia/Sydney"
CSV_WORK_DIR="/data/tmp"               # optional: a folder with enough free space for the unzipped zip (the root disk can be small)
OFFLINE="yes"
```
There is no source host and no source password. Only `TARGET_PASSWORD_ENV` needs a password. Run `--check` (it prints what would be created), then `--dry-run`, then the real run.
For several zips put them in one folder (for example `/data/upload/zips/` holding `01_nstd.zip` and `02_other.zip`) and set `SOURCE_CSV_PATH` to that folder: they are imported one after the other (section 3.6).

## 8. Undo a run

Only possible if the run had `BACKUP="on"`. The saved rows are in the target database, in the table named in the run log / `summary.csv` (column `backup_table`).

Postgres target (one transaction; replace the names and the period with yours):
```sql
BEGIN;
DELETE FROM gsb_data."KPI_NS_QRLY_NODE_CEM_ERS_P"
 WHERE "PERIOD_START_TIME" >= '2026-10-25 00:00' AND "PERIOD_START_TIME" < '2026-10-25 02:00';
INSERT INTO gsb_data."KPI_NS_QRLY_NODE_CEM_ERS_P"
 SELECT * FROM import_backup."KPI_NS_QRLY_NODE_CEM_ERS_P_bak_20261112_230154";
COMMIT;
```
DuckDB / DuckLake target: the same two statements, with the table written as `"main"."<table>"` (the backup is in schema `import_backup`) and `SET TimeZone='Australia/Sydney';` first.

If the backup table was empty or not made (the target had no rows for the period), the undo is just the `DELETE`.
Backup tables are **not** removed automatically. When you no longer need one: `DROP TABLE import_backup."<table>_bak_<date_time>";`.
**Structure changes are not undone by the backup.** With `TARGET_STRUCTURE="create"` the backup holds the old rows, not the old structure: a created schema, a created table or an added column stays. `structure_changes.sql` in the run's report folder lists exactly what was created; remove it by hand (`DROP TABLE`, `ALTER TABLE ... DROP COLUMN`) if you need to, after checking that nothing else uses it.

## 9. If something goes wrong

Every message below is printed before anything is written, unless stated. Exit code 2 = refused, nothing changed. Exit code 1 = a table failed and was rolled back.

| Message | Cause and fix |
|---|---|
| `config has Windows line endings. Run: dos2unix ...` | run the `dos2unix` command it names on the config |
| `$'\r': command not found` or `bad interpreter` | the script has Windows line endings: `dos2unix db-import.sh` |
| `SOURCE_PASSWORD_ENV=..., but the environment variable ... is empty or not exported` | do the `read -rs ...; export ...` step (section 4) in the same terminal |
| `PERIOD_FROM '...' is not valid` | use `YYYY-MM-DD` or `YYYY-MM-DD HH:MM[:SS]` |
| `PERIOD_FROM (...) must be earlier than PERIOD_TO (...)` | swap or correct the two values |
| `TARGET_ENV must be dev, uat or prod` | set `TARGET_ENV` |
| `source and target are the same table` | the source and target settings point to the same database and schema: correct `SOURCE_*` or `TARGET_*` |
| `psql not found` | install or load the PostgreSQL client (`psql`) |
| `psql: error: connection ... failed` / `password authentication failed` / `role "..." does not exist` | wrong host, port, user or password. Test by hand: `psql -h <host> -p <port> -U <user> -d <db> -c 'select 1'` |
| `source table ... does not exist` / `target table ... does not exist` | wrong table name or schema. Create the target table first (same columns as the source), or, with a csv source, set `TARGET_STRUCTURE="create"` |
| `these source columns are not in the target table: ...` | the target table lacks columns that the source has. Align the tables |
| `no column PERIOD_START_TIME in source or target ...` | the table has another time column name or none: `TABLE_TIME_COLUMNS=...` or `FULL_COPY_TABLES=...` (section 6) |
| `time column ... exists in the source: yes, in the target: no` | the time column must be on both sides |
| `LOAD_MODE=stop: the target already has N row(s) for this period` | on purpose. Use `replace`, or pick another period |
| `offline bundle not found in .../bundle` | the `bundle/` folder is missing: section 2, step 4 |
| `bundle checksum failed` | the bundle was damaged or only partly copied: copy it again and check it with `sha256sum -c` |
| `DuckDB version is X but the bundle was built for Y` | use the DuckDB in `bundle/duckdb` (do not set `DUCKDB`), or rebuild the bundle on dev |
| `extension '...' is not in the bundle` | rebuild the bundle on dev: `./prepare-bundle.sh --tar` |
| `mkdir: cannot create directory ... Permission denied` (report folder) | `REPORT_DIR` is owned by another user: set `REPORT_DIR` to a folder you can write |
| `permission denied for schema/database ...` when `BACKUP="on"` | the user cannot create the backup schema: ask the DBA, or use `BACKUP="off"` |
| `row count check failed: expected N, found M` (table FAILED, rolled back) | the source changed during the run, or a trigger/rule changed the rows on the target. Nothing was changed for that table. Run again |
| `FAILED: exit code ...; the transaction was rolled back` | read the error printed just above it (a constraint, a type mismatch, a lost connection). The target keeps its old rows for that table |
| `DuckDB could not read the table columns` | the error just above says why: a wrong DuckLake schema or data path, a wrong password, or a file that does not exist |
| `Python cannot load pyarrow / adbc_driver_flightsql` | `bundle/pylibs` is missing or incomplete: build it on a machine with internet with `./prepare-bundle.sh --with-flightsql` and copy `bundle/` (section 2) |
| `bundle/pylibs was built for Python 'X' but this machine's python3 is 'Y'` | the packages only work with the Python they were built for: rebuild with the same Python version as this machine |
| `cannot connect to the Flight SQL API at <host>:<port>` | the tunnel is not up, or the host or port is wrong, or the API's Flight SQL is off. Test: `bash -c '</dev/tcp/<host>/<port>' && echo open` |
| `the API rejected or failed a query: ...` | read the text after it: a wrong schema or table name, a timeout (raise `FLIGHT_TIMEOUT_SECONDS` or lower `FLIGHT_SLICE_MINUTES`), or the API is busy |
| `slice N of M (...) returned R rows, which is the row cap` | the API may have cut the result, so the table is not imported. Lower `FLIGHT_SLICE_MINUTES`. If the cap on the API differs from `FLIGHT_MAX_ROWS`, set it to the real value |
| `the table has no time column '...'` / `time column '...' has type ...` | set `TIME_COLUMN` or `TABLE_TIME_COLUMNS` (section 6); only timestamp columns are supported |
| `... already holds files from an earlier export` | an earlier export is in `EXPORT_DIR`: use another folder, leave `EXPORT_DIR` empty, or set `EXPORT_OVERWRITE="yes"` (section 3.5) |
| `no CSV file in ... covers the period` / `no file for <time> to <time>` | the downloaded files do not cover the whole period: download the missing part, or shorten the period. `CSV_INCOMPLETE="warn"` only if you know it is fine (section 3.6) |
| `<file> has N rows but its manifest says M` | a damaged or partly copied file: copy the zip again and check its size. Nothing was written |
| `the file does not follow the pattern <TABLE>_<YYYY-MM-DD_HH_MM_SS>__to__<...>.csv[.gz]` | the folder holds a file that is not part of the download: remove it, or point `SOURCE_CSV_PATH` at the right folder |
| `not enough free space in ... for the zip` | set `CSV_WORK_DIR` to a folder with more free space (the root disk is often small), or unzip the file yourself and give the folder |
| `neither unzip nor Python ... is available to open the zip` | unzip it on another machine and give the folder as `SOURCE_CSV_PATH` |
| `... table does not exist` with `TARGET_STRUCTURE="strict"` | set `TARGET_STRUCTURE="create"` (csv source only) to create the schema and tables, after `--check` shows what will be created |
| `TARGET_STRUCTURE=create adds the missing columns itself: do not combine it with EXTRA_SOURCE_COLUMNS=skip` | remove `EXTRA_SOURCE_COLUMNS` from the config |
| `no rule in CSV_COLUMN_TYPES for column ...` | end the rule list with `*=VARCHAR` |
| `PERIOD_FROM / PERIOD_TO = "auto" is only supported with SOURCE_TYPE=csv` | use real dates for the other sources |
| `the zip files do not fit together` (folder of zips) | two zips hold the same table and time range, or leave a gap between them (the lines above name the table and the times). Remove the duplicate zip, add the missing one, or set `CSV_INCOMPLETE="warn"` if you know it is fine |
| `stopped at zip N of M` (folder of zips) | zip N failed: read its error above. The zips before it stay loaded, the ones after it were not touched. Fix the cause and run again (a zip that already loaded is replaced with the same data) |

If you cannot solve it: do not run the real step. Keep the folder `reports/<date_time>_<job>/` (it has the complete log) and send it with the config (`config_used.env` in it).

## 10. Safety summary

- The source is only read.
- Only the tables in `TABLES` are changed, and only the rows of the period (`FULL_COPY_TABLES` tables completely).
- Every table is one transaction: all or nothing. The row count is checked inside it.
- `--check` and `--dry-run` change nothing. Always run them first.
- A prod target needs you to type the database name.
- It never drops anything. It creates or alters a table or schema only with `TARGET_STRUCTURE="create"` (csv source), after `--check` listed exactly what it will do; otherwise only the backup schema and tables are created.
- Passwords are not stored anywhere by the tool.

## 11. What was tested, and what was not

Tested on dev with real data (see [docs/EVIDENCE.md](docs/EVIDENCE.md)): Postgres -> Postgres (80,445 rows), DuckLake -> Postgres (40,921 rows) running from the offline `bundle/`,
DuckDB file -> DuckDB file, DuckDB file -> DuckLake and parquet -> DuckDB (40,921 rows each); replace, backup on/off, dry-run rollback, a failing import rolled back, `stop`, `append`, `FULL_COPY_TABLES`, table-name mapping, the Sydney time zone.

Also tested: `ON_ERROR` `stop` and `continue`, the prod confirmation prompt (wrong, empty and correct answer, no terminal, `--yes`), and `--dry-run` against a DuckLake target.
DuckLake -> DuckLake (40,921 rows, `--check`, `--dry-run`, real run, equal row for row) was tested inside the one dev catalog (source schema `gsb_data_kpi_pivot_dev_V2`, scratch target schema `dbimport_demo_dl`).

**Flight SQL source** (section 3.5), tested on dev against the dev API with real data: API -> DuckLake (40,921 rows: `--check`, `--dry-run`, real run, equal row for row, the 40,921 old rows replaced and saved in the backup), a table with a time zone and a table without one,
the row-cap failure (nothing written), `--export-only` (no password needed), importing the kept files later with no API call, `EXPORT_KEEP="no"`, and the offline bundle with `pylibs` (empty home folder; a bundle built for another Python is refused). See `docs/EVIDENCE.md` and `PLAN-FLIGHTSQL.md` (sections 9 to 12).

**CSV source** (section 3.6), tested on dev with a real cut-out of the prod NSTD download (two tables, 130,727 and 234,552 rows, `unzip` route): zip -> DuckLake with `--check`, `--dry-run`, a real run and a second run (replace with backup), equal row for row (`EXCEPT` in both directions);
a table with a time zone and a plain `timestamp` target; `TARGET_STRUCTURE="create"` into a schema that did not exist (schema and two tables created, rolled back by `--dry-run`, then created by the real run) and adding a missing column to an existing table (also rolled back by `--dry-run`);
a period the files do not cover (stopped before any write, exit code 2);
`PERIOD_FROM="auto"` / `PERIOD_TO="auto"` (every row of the files, each table with its own range); a **folder of two zips** in name order (two tables, one per zip, into a new schema, 130,727 and 234,552 rows), the **same table split by time over two zips** (80,445 + 50,282 = 130,727 rows, equal row for row), and the refusal when the same table and time range is in two zips (exit code 2, nothing imported).
Evidence: `PLAN-CSV.md` (sections 8 to 13).

**Not tested:** two separate DuckLake catalogs (for example prod and UAT) read directly; a real tunnel from UAT to the prod API, the prod API itself (its version, row cap and tables may differ from dev) and UAT's Python (the bundle must be built for it); the Flight SQL source with a Postgres target.

**Not tested:** a server that has no network at all (only UAT / prod can prove that; on dev the bundle was proven to load with an empty home folder and auto-download off).
UAT and prod themselves could not be tested (no access). That is why you run `--check` and `--dry-run` first, and why the first real run there should be a small period.

## 12. Checklist

- [ ] The tool folder is on the server, `dos2unix` and `chmod +x` done, `grep -c $'\r' db-import.sh` prints 0
- [ ] DuckDB involved? `bundle/` is in the folder and `sha256sum -c` of the bundle was OK
- [ ] Config created in `configs/`, hosts / databases / schemas confirmed for **this** environment, `TARGET_ENV` correct, `TIMEZONE="Australia/Sydney"`
- [ ] Passwords exported in this terminal (or `~/.pgpass`)
- [ ] `--check`: the tables, the period and the row counts are as expected
- [ ] `--dry-run`: every table `DRY-RUN OK`, `finished: all tables OK`
- [ ] First real run with a **small period**, then check `summary.csv` and the rows in the target
- [ ] Note the backup table names; drop them when no longer needed
- [ ] CSV zip: the zip is on the server (upload it as ONE file), `unzip` or `python3` exists, there is enough free disk (`CSV_WORK_DIR` if `/tmp` is small), `--check` shows every table you expect and no `ERROR`
- [ ] `TARGET_STRUCTURE="create"`: read what `--check` says it will create or add (a typo in `TARGET_SCHEMA` would create a new schema), and keep `structure_changes.sql`
- [ ] Several zips in a folder: only the zips you want are in it (every `.zip` is imported), named in the order you want
