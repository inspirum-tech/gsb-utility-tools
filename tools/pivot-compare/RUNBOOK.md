# Runbook: pivot-compare on UAT / prod

For the person who runs the tool. You do not need anyone's help if you follow the steps in order.

## 1. What this tool does

It compares the pivot tables written by the OLD calculator (Postgres) with the pivot tables written by the NEW calculator (DuckLake) for the same objects and the same 15-minute periods, one pair of tables at a time. It then builds a report you can share: a Word report, an Excel sheet, one folder per table and a zip file.

- It only **reads** the two databases. It never writes to them.
- The only things it writes are files in its own folder (the report folders and `tmp/`).
- Nothing is built or installed. You copy the folder and run one command.

## 2. What you need on the machine

| Needs | How to check |
|---|---|
| `bash` | `bash --version` |
| The DuckDB command line program (one file, version 1.5.x) | `<path to duckdb> --version` |
| Network access to the OLD Postgres database and to the NEW DuckLake | step 5 checks this |
| The DuckDB `postgres` extension (a file on this machine) | `<path to duckdb> -c "LOAD postgres;"` prints nothing when it works |
| `python3` (only for the Word / Excel / zip output; nothing to install) | `python3 --version` |
| Free disk space for `tmp/` and the reports (several GB; check with `df -h .`) | |

No internet is needed. If the `postgres` extension check prints an error, see section 9.

## 3. Copy the tool to the server

1. Copy the whole `pivot-compare` folder to a folder of your own on the server. The `tests/` folder is not needed.
2. If the files came from a Windows PC, fix the line endings once. Without this the scripts fail with `$'\r': command not found`:
   ```
   cd <your pivot-compare folder>
   dos2unix run.sh *.env *.csv scripts/*.py scripts/*.sh sql/*.sql
   ```
3. Check that the files are there:
   ```
   ls -la run.sh scripts/make_final_report.py sql/ pairs_ns_name.csv config_ns_all.env
   ```

Every path in the config file is relative to this folder. Run the tool from inside this folder.

## 4. Create your connection file (`.env`)

The OLD side is read from Postgres. The connection string is read from a file named `.env` in the tool folder, so it is never typed on the screen or stored in the config.

```
cd <your pivot-compare folder>
echo 'KPI_ENGINE_PG_DSN=<the Postgres connection string>' > .env
chmod 600 .env
```

- `<the Postgres connection string>` is the same value that works with `psql "<value>"`.
- The `.env` file stays on this server. Never copy it to a share, email or git.
- Check that it works (this prints `1`):
  ```
  PAGER=cat psql "$(grep '^KPI_ENGINE_PG_DSN=' .env | cut -d= -f2- | tr -d '"')" -c "select 1"
  ```

## 5. Check the NEW side is reachable

The NEW tables are read through a DuckLake catalog that DuckDB attaches itself, from the user's `~/.duckdbrc` file. The config says which catalog name to use (`NEW_CATALOG`, `gsb` on dev).

```
<path to duckdb> -c "select database_name from duckdb_databases();"
```

The list must contain the catalog name that is in `NEW_CATALOG`. If it does not, the NEW side cannot be read: attach it in `~/.duckdbrc` the same way the other GSB apps on this server do, or set `NEW_CATALOG` to the name you see.

## 6. Make your config file (the settings that differ from dev)

Do not edit `config_ns_all.env` itself. Make a copy and edit the copy:

```
cp config_ns_all.env config_ns_all_uat.env
```

Open `config_ns_all_uat.env` and check these lines. Everything not listed here stays as it is.

| Line | What to put | Why |
|---|---|---|
| `PERIOD_FROM` / `PERIOD_TO` | The time window to compare, **in UTC**, like `"2026-10-24 13:00:00+00"`. The window is half open: `PERIOD_FROM <= period < PERIOD_TO`. Each 15-minute period needs a start time inside it. Use a window that **both** calculators have written (see the checks below). | A period that exists on one side only is reported as "not comparable". |
| `OLD_SCHEMA` | The Postgres schema of the OLD pivot tables (`gsb_data_kpi_pivot` on dev). | Differs if the environment uses another schema. |
| `NEW_SCHEMA` | The DuckLake schema of the NEW pivot tables (`gsb_data_kpi_pivot_dev` on dev). | Differs per environment. |
| `NEW_CATALOG` | The catalog name from step 5. | Must match `duckdb_databases()`. |
| `DUCKDB` | Full path of the DuckDB program on this server. | Differs per server. |
| `TEMP_DIR` | An existing folder with free space (for example `<tool folder>/tmp`; create it with `mkdir -p tmp`). | DuckDB writes large temporary files there. |
| `REPORT_DIR` | A new folder name for this run, for example `report_uat_20261201`. | A new run writes into this folder. Use a new name for every run. |
| `FINAL_REPORT_TITLE` | A title for the report, for example `"NS Pivot Comparison - UAT"`. | Printed on the Word report. |
| `FINAL_REPORT_AUTHOR` | Your name. | Printed on the Word report. |
| `FINAL_REPORT_NOTES_FILE` | **Leave empty** (`FINAL_REPORT_NOTES_FILE=`). | The file named on dev holds text about the dev data. It must not go into a UAT report. |
| `FINAL_REPORT_COMMENTS_FILE` | **Leave empty** (`FINAL_REPORT_COMMENTS_FILE=`). | Same reason. |
| `PAIRS_FILE` | `pairs_ns_name.csv`, or your own copy (see below). | The list of tables to compare. |

Keep these as they are, unless you were told otherwise: `MODE=list`, `OLD_SOURCE=postgres`, `OLD_DSN_ENV=KPI_ENGINE_PG_DSN`, `NEW_SOURCE=attached`, `OLD_PERIOD_KIND=local`, `OLD_PERIOD_TZ=Australia/Sydney`, `NEW_PERIOD_KIND=tz`, the tolerance lines, `FINAL_REPORT=yes`, `CM_COMPARE=no`.

### The list of tables (`pairs_ns_name.csv`)

One line per table pair: `name,old_table,new_table,key_cols,info_cols`. The table names in the file are the dev names. If the OLD or NEW table has a different name on this environment, copy the file (`cp pairs_ns_name.csv pairs_uat.csv`), change the `old_table` / `new_table` names in your copy, and put `PAIRS_FILE=pairs_uat.csv` in your config. Do not change the other columns.

### Check the window and the tables before you run (read only)

1. OLD periods (psql; the OLD period is in Sydney local time, not UTC):
   ```
   PAGER=cat psql "$(grep '^KPI_ENGINE_PG_DSN=' .env | cut -d= -f2- | tr -d '"')" -c "select min(\"PERIOD_START_TIME\"), max(\"PERIOD_START_TIME\"), count(distinct \"PERIOD_START_TIME\") from <OLD_SCHEMA>.\"KPI_NS_QRLY_CELL_LTE_ERS_P\""
   ```
2. NEW periods (DuckDB; the NEW period is a timestamp with time zone):
   ```
   <path to duckdb> -c "select min(\"PERIOD_START_TIME\"), max(\"PERIOD_START_TIME\"), count(distinct \"PERIOD_START_TIME\") from gsb.<NEW_SCHEMA>.\"KPI_NS_QRLY_CELL_LTE_ERS_NEW_P\";"
   ```
   (Use your catalog name instead of `gsb` if it is different.)
3. Pick `PERIOD_FROM` / `PERIOD_TO` so that the window is inside **both** ranges. Remember that OLD shows Sydney time and the config is UTC (Sydney is UTC+10, or UTC+11 in daylight saving).

## 7. Run it

First a small test with one table, then the full run.

**7a. Small test (one table, a few minutes):**

```
head -2 pairs_ns_name.csv > pairs_smoke.csv
```
Set `PAIRS_FILE=pairs_smoke.csv` and a new `REPORT_DIR=report_smoke` in your config, then:
```
bash run.sh config_ns_all_uat.env
echo "exit code: $?"
```
You should see one line with `CELL_LTE` and a result (`IDENTICAL` or `DIFFERENT`), then the line `pairs: 1 ...`. Either result means the tool works. If you see `ERROR`, go to section 9.

**7b. Full run:** set `PAIRS_FILE` back to `pairs_ns_name.csv` (or your copy), set a new `REPORT_DIR` (for example `report_uat_20261201`), and run it in the background, because it can take a long time:

```
nohup bash run.sh config_ns_all_uat.env > run_uat_$(date +%Y%m%d_%H%M).log 2>&1 &
```

Look at the progress at any time (this does not stop the run):
```
tail -f run_uat_*.log
```
Press Ctrl+C to stop watching; the run continues. The run is finished when the log shows the line starting with `pairs:` and the shell shows the job as done (`jobs`, or `ps aux | grep run.sh`).

## 8. What happens and what you get

While it runs, the log prints one result line per table (`IDENTICAL`, `DIFFERENT`, `NOT COMPARABLE` or `ERROR`), then a totals line:
```
pairs: 18   identical: x   different: y   not comparable: z   errors: e
```

**The exit code** (`echo $?` right after a foreground run):

| Code | Meaning |
|---|---|
| 0 | Every table is identical |
| 1 | At least one table has differences. This is a normal result, not a failure of the tool |
| 3 | A table has nothing in common between OLD and NEW, or no table was run |
| 2 | A setup problem or an error in at least one table (see section 9) |

**What is written** (all inside the tool folder):

| Path | What it is |
|---|---|
| `<REPORT_DIR>/` | Raw results: `pairs_summary.csv` (one line per table) and one folder per table with `summary.csv`, `kpi_summary.csv`, `differences.csv`, `objects_one_side.csv`, `verdict.txt` and `config_used.env` (the settings that table really used) |
| `<REPORT_DIR>_FINAL_OUTPUT_RESULT/` | **The folder to share**: a Word report (`Test Summary Report - ....docx`), an Excel sheet (`... - Results.xlsx`), one folder per table, and `Supporting_details/` (a copy of the raw files) |
| `<REPORT_DIR>_FINAL_OUTPUT_RESULT.zip` | The same folder as one zip file. **Send this file** |
| `tmp/` | DuckDB temporary files. Safe to delete when no run is active |

Pass/not-met wording in the report: a table is `PASS` only when nothing differs, nothing exists on one side only and nothing is empty; otherwise it says `NOT MET` with the numbers. The report states the time the comparison finished: it describes the data as it was at that time.

If the final output was not created (for example no `python3`), the log says so and the raw results in `<REPORT_DIR>/` are still complete. The exit code is not changed by the final output.

**To run again:** use a **new** `REPORT_DIR` name. The final output folder is never overwritten: if it already exists the log prints `already exists` and does not write a new one.

**How to check the output is complete** (replace `report_uat_20261201` with your `REPORT_DIR`):
```
ls -la report_uat_20261201_FINAL_OUTPUT_RESULT*
unzip -t report_uat_20261201_FINAL_OUTPUT_RESULT.zip | tail -2
cat report_uat_20261201/pairs_summary.csv | cut -c1-100
```
- The first command must show the folder and the `.zip` file.
- The second must end with `No errors detected` (if `unzip` is not installed: `python3 -m zipfile -l <zip file> | tail -3`).
- The third shows one line per table with its result. Every table in your pairs file must appear, and none may say `ERROR`.

**What to send back:** the zip file `<REPORT_DIR>_FINAL_OUTPUT_RESULT.zip` and the log file `run_uat_....log`.

## 9. Problems and what to do

| What you see | What it means / what to do |
|---|---|
| `config file not found` | Wrong file name, or you are not in the tool folder. `cd` into it. |
| `config error: ... must be ...` | A config value has a wrong format. The message names the line; fix it in your copy. |
| `DuckDB CLI not found (DUCKDB=...)` | Set `DUCKDB` to the full path of the duckdb program. |
| `config error: no connection string` | The `.env` file is missing, is not in the tool folder, or has no `KPI_ENGINE_PG_DSN=` line (step 4). |
| `config error: the DuckDB 'postgres' extension is not on this machine and could not be downloaded` | This machine has no internet and no copy of the extension. Copy the file `postgres_scanner.duckdb_extension` once from a machine where `LOAD postgres;` works, from `~/.duckdb/extensions/<duckdb version>/<platform>/` to the same folder for the user who runs the tool (create the folders if needed). The DuckDB version must be the same. Test with `<path to duckdb> -c "LOAD postgres;"`. |
| `PAIRS_FILE not found` | The file named in `PAIRS_FILE` is not in the tool folder. |
| A table shows `ERROR` | Open `<REPORT_DIR>/<name>.screen.txt`: the last lines say why. `Table with name ... does not exist` means the schema or table name in the config or the pairs file is wrong for this environment. `Catalog ... does not exist` means step 5 is not done. |
| A table shows `NOT COMPARABLE` | OLD and NEW have no object or period in common in your window. Check the window with the checks in section 6. |
| `final report skipped: python3 was not found` | Install or load `python3`, or ignore it: the raw results are complete. |
| `already exists` for the final output | Run again with a new `REPORT_DIR`. |
| `Input/output error` on the shared folder, or `No space left on device` | The disk is full or the shared mount has a problem. Free space (delete old report folders and `tmp/` content), then run again. Tell the platform team if the mount itself is down. |
| The run seems stuck | Look at `tail -f` of the log: a table finishing every few minutes is normal. Full runs are slow. Do not start a second run in the same folder. |

## 10. Safety

- It is read only on both databases. It cannot change data.
- It never prints the connection string and never writes it to a report.
- It writes only inside its own folder.
- To stop a run: `pkill -f "bash run.sh"` (stops only this tool). Nothing needs cleaning up in the databases; delete the unfinished `REPORT_DIR` folder if you do not need it.

## 11. Short checklist

1. Copy the folder; `dos2unix` if it came from Windows (section 3).
2. Create `.env` with the Postgres connection string; check `select 1` (section 4).
3. Check the NEW catalog is attached (section 5).
4. Copy the config; fix the lines in the table in section 6; leave the two NOTES / COMMENTS lines empty.
5. Check `LOAD postgres;` works (section 2).
6. Check the periods on both sides and set `PERIOD_FROM` / `PERIOD_TO` (section 6).
7. Run the one-table test (7a), then the full run with a new `REPORT_DIR` (7b).
8. Send back `<REPORT_DIR>_FINAL_OUTPUT_RESULT.zip` and the log file.
