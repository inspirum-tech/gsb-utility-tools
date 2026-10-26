# pivot-compare: does the NEW KPI calculator give the same numbers as the OLD (Java) one?

This tool compares the **pivot table of the old Java calculator** with the **output of the new Rust `kpi-engine`**
for the same period(s), and says `IDENTICAL` or `DIFFERENT` with counts and the exact differences.

* **Read only.** It only reads the two sources. The only things it writes are the report files.
* **Config driven.** Tables, schemas, key columns, period, KPI columns, tolerance and report folder are all in one
  file (`config.env`). Nothing about them is written in the SQL or in `run.sh`.
* **Engine:** the DuckDB command line program, driven by `run.sh` (bash). No Python, no Rust, no database changes.

## What it compares, in a small example

A pivot table is one row per object and period, one column per KPI (`K_<KPI_ID>`).

```
OLD (Postgres, Java)                                   NEW (kpi-engine, tall table KPI_CALCULATED)
PERIOD_START_TIME     SITE_ID CELL_ID  K_1   K_2       PERIOD_START_TIME     SITE_ID CELL_ID KPI_ID KPI_VALUE
2025-12-19 20:00:00     1       2      50    21        2025-12-19 09:00+00     1       2       1      51
                                                                                1       2       2      21
```

* The old time `20:00` is Sydney time (UTC+11), the new one is a real instant: both become the same UTC instant
  `2025-12-19 09:00 UTC` (settings `*_PERIOD_KIND` and `*_PERIOD_TZ`).
* The **object key** is the period plus the key columns (`SITE_ID,CELL_ID`) = `1|2`.
* The tool compares `K_1` of object `1|2`: old `50`, new `51` -> a difference. `K_2`: `21` and `21` -> equal.
* A new side that is a **tall table** is turned into the same shape on the fly, so you do not have to build a new
  pivot table first (`NEW_SHAPE=tall`). If a new pivot table exists, point at it with `NEW_SHAPE=wide`.

One line summary: *both sides are reduced to (period, object key, KPI, value), joined, and every pair is judged equal
or different by the tolerance and the Java null/NaN/infinity rule.*

## How to run

```bash
cd tools/pivot-compare
$EDITOR config.env           # period, tables, filter (see the comments in the file)
./run.sh                     # or: ./run.sh path/to/other-config.env
```

Needs `bash` and the `duckdb` command line program (set `DUCKDB=/full/path/duckdb` in the config if it is not on the
`PATH`). For a Postgres side it needs the connection string in the environment variable named by `OLD_DSN_ENV` /
`NEW_DSN_ENV` (default `KPI_ENGINE_PG_DSN`) or as the line `KPI_ENGINE_PG_DSN=...` in the file `ENV_FILE` (default
`../../.env`, the project `.env`). It is never printed or written to the report.

Exit code: `0` IDENTICAL, `1` DIFFERENT, `3` NOT COMPARABLE (no object or no KPI column in common), `2` bad setup.

### On the dev server

```
/mnt/mfs/gsb_application/pems-dbt-calculator/tall-engine-and-final-schema/tools/pivot-compare/
```

Upload the whole folder, then `dos2unix run.sh tests/*.sh`, `chmod +x run.sh`, and set
`DUCKDB=/mnt/mfs/gsb_application/gsb-dedup-service/duckdb-cli/duckdb` and a `TEMP_DIR` with free space in `config.env`.
The DuckDB there loads `~/.duckdbrc`; the tool uses its own names (`cmp_...`) for what it attaches, so they do not clash.

## How to read the result

On screen: object counts (old, new, in both, only old, only new), KPI column counts, value counts, the 10 worst KPIs,
and the last line, the **verdict**, for example:

```
DIFFERENT: objects only old=1 only new=1, KPI columns only old=1 only new=1, values compared=9 different=1 null_old_only=1 null_new_only=0, common objects=3, common KPI columns=3
```

Files in `REPORT_DIR` (all rewritten on every run):

| File | What is in it |
|---|---|
| `verdict.txt` | the verdict line |
| `summary.csv` | every count (`metric,value`) |
| `differences.csv` | every difference: `period_utc, object_key, kpi, old_value, new_value, abs_diff, kind` (`DIFF`, `NULL_OLD_ONLY`, `NULL_NEW_ONLY`); at most `MAX_DIFF_ROWS` rows |
| `objects_one_side.csv` | objects (period + key) that exist on one side only, with the side |
| `kpi_columns_one_side.csv` | KPI columns that exist on one side only |
| `kpi_summary.csv` | per KPI: compared, equal, different, null on one side, largest difference |
| `duplicate_keys.csv` | objects (or object and KPI) that appear more than once on a side; values are reduced with `max()` |
| `generated.sql`, `config_used.env` | exactly what ran (no connection strings) |

**The verdict.** `DIFFERENT` if any value differs, or (switches in the config) objects exist on one side only,
KPI columns exist on one side only, or a value is NULL on one side only. `IDENTICAL` only when none of that is
found *and* there is something in common. Nothing in common is `NOT COMPARABLE`, never `IDENTICAL`.

**Value rules** (same as the Java calculator, all configurable):

* Equal when `abs(old - new) <= TOLERANCE_ABS + TOLERANCE_REL * abs(old) + FLOAT_SLACK`. The new calculator rounds to 8
  decimals like Java, so the default is `1e-8`.
* NaN and +-infinity are read as `SPECIAL_DEFAULT` (-1) on both sides (`SPECIAL_AS_DEFAULT=yes`), because Java replaces
  them by `DIVIDE_BY_ZERO_DEFAULT`.
* A NULL on one side and a value on the other is reported, not hidden (`NULL_AS_DEFAULT=no`). A KPI that is NULL on
  both sides counts as equal.

## Likely reasons for a difference that is *not* a bug

Do not "fix" a difference by changing either calculator: report it with the likely reason.

* The two sides did not use the same counters or KPI definitions for that period (check this first).
* Non-cell KPIs: the new engine writes `EXT_NODE` = node and `EXT_CELL_NAME` = device.
* HW/ERS value pick is the last row per object and counter.
* MOCN and ENIQS profiles are calculated per cell and neighbour (`TGT_NODE`, `TGT_CELL`); the old pivot row key may differ.
* Nokia cell keys are `node|cell`. Array-bin KPIs depend on the `COUNTER_DEF_V2` ids. The new counter tables have renumbered ids.
* Dev data can be inconsistent (the old table has no primary key; see `duplicate_keys.csv`).

## Pointing it at other tables

Copy `config.env` and change:

| To compare | Change |
|---|---|
| another family (for example 5G or STD) | `OLD_TABLE`, `NEW_FILTER_VALUE` (the application), `KPI_REGEX` if the names differ |
| another period | `PERIOD_FROM`, `PERIOD_TO` (UTC, `PERIOD_TO` not included) |
| site level instead of cell | `OLD_KEY_COLS`, `NEW_KEY_COLS` (same count, same order) |
| a new **pivot** table (DuckLake) instead of the tall table | `NEW_SHAPE=wide`, `NEW_SOURCE=attached`, `NEW_CATALOG=gsb`, `NEW_SCHEMA=gsb_data_kpi_pivot`, `NEW_TABLE=<pivot table>`, `NEW_KEY_COLS`, `NEW_PERIOD_KIND` |
| only some KPIs | `KPI_LIST_FILE` (one `K_<id>` per line) or `KPI_REGEX` |
| the new side names a KPI differently | `KPI_MAP_FILE` (CSV header `old_kpi,new_kpi`) |
| a DuckDB file | `*_SOURCE=duckdb`, `*_DB_FILE` |

Names (schema, table, columns) accept letters, digits and `_` only, and the values are checked before any SQL is built.
`PERIOD_*`, numbers and yes/no values are checked too; a bad value stops the run with a message and exit code 2.

## Tests

```bash
DUCKDB=duckdb tests/run_local_tests.sh      # fake data with 6 known differences + 7 settings variants, needs only DuckDB
DUCKDB=duckdb tests/run_postgres_test.sh    # optional: the Postgres path, with a throwaway Postgres in Docker
```

The fake data and the list of known differences are in `tests/make_fake_data.sql`. The test passes only when the report
shows exactly those: a missing row, an extra row, one wrong value, NULL against a value, a rounding difference inside the
tolerance (and the NaN rule). Recorded output: `docs/local_test_output.txt`, `docs/postgres_test_output.txt`.

## Known limits

* Values are compared as 64-bit floats. A pivot value above about 1e15 with decimals loses its last digits on the way.
* If the old side has the same object twice in a period, the values are reduced with `max()` and listed in `duplicate_keys.csv`.
* A very large comparison (all periods of a day, 60,000 cells x 466 KPIs) is millions of rows per period; set
  `MEMORY_LIMIT`, `TEMP_DIR` and keep the window small on the shared dev server.
* The comparison is only as meaningful as the input: it cannot tell you that the two calculators were fed the same counters.
