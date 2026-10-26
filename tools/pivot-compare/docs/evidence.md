# Evidence: pivot-compare

Environment: dev server `gsb-dev` (Postgres database `gsb`, read only), 2026-10-26; local tests on Windows 11 with DuckDB CLI v1.5.4
and Docker `postgres:16-alpine`. Verdict legend: ✅ confirmed · ❌ refuted · ⏳ untested.

## A. Facts found on dev before building (all read only)

| # | Claim | Command (short) | Verbatim result | Verdict |
|---|---|---|---|---|
| 1 | Old pivot has 466 KPI columns named `K_<id>` and 9 fixed ones | `psql ... information_schema.columns ... table_name='KPI_ENIQS_CAT6_QRLY_CELL_LTE_ERS_P'` | `db=gsb kpi_cols=466 fixed_cols=9`; fixed: `PERIOD_START_TIME, SITE_ID, CELL_ID, SITE_NAME, CELL_NAME, LAC, SAC, UPDATE_TIMESTAMP, TAC` | ✅ |
| 2 | Per-period tables are partitions of the base table | `pg_inherits` join on the base table | `base_kind=p children=281 first_bound=FOR VALUES FROM ('2025-10-05 13:45:00') TO ('2025-10-05 14:00:00') last_bound=FOR VALUES FROM ('2026-04-23 04:30:00') TO ('2026-04-23 04:45:00')` | ✅ |
| 3 | Old table has no primary key | `pg_index` for the base table | one row: `kpi_eniqs_cat6_qrly_cell_lte_ers_p_idx ... pk=f uq=f ... USING btree ("PERIOD_START_TIME")` | ✅ (so duplicates are possible) |
| 4 | Duplicates exist, mostly on NULL keys | key count at `2025-12-19 18:00` | `keys=15634 dup_keys=71 max_rows_per_key=18 keys_with_several_names=71 null_keys=73` | ✅ |
| 5 | Old data of 2025-12-19 covers 14:00-20:15 and 23:45 (own clock) | rows per period | `2025-12-19 20:00:00 \| 19373 \| 18709`; no rows 20:30-23:30 | ✅ |
| 6 | The new tall table is in Postgres, not DuckLake | `information_schema.tables where upper(table_name)='KPI_CALCULATED'` | `gsb_data_kpi_base \| KPI_CALCULATED` (1 row); DuckLake: `Table with name KPI_CALCULATED does not exist!` | ✅ |
| 7 | The new tall table has `SITE_ID`, `CELL_ID`, `KPI_ID` (key can match the old one) | column list | `PERIOD_START_TIME:timestamp with time zone, ... SITE_ID:bigint ... KPI_ID:bigint, KPI_VALUE:double precision ...` | ✅ |
| 8 | The test application `ENIQS_CAT6_REAL_A` is in the new table | rows per application | **0 rows**; the table holds `SMALLCELL` 13,301,292, `ENIQS_CAT6` 99,840 (2025-12-19 20:00 +11), `VENDOR_PARITY_TEST` 69,731 | ❌ (premise wrong; see parking lot PC-02) |
| 9 | `ENIQS_CAT6` overlaps the old table | cells and KPIs | `n_rows=99840 cells=79 kpis=1248 min_kpi=241326 max_kpi=600025 last_calc=2026-09-29 23:47:56+10 null_cell_id=0 null_val=0` | ✅ |
| 10 | Same objects and KPIs on both sides | join of keys and column names | `new_cells=64 old_cells=18709 cells_in_both=28 new_kpis=1248 kpis_in_old_columns=439` | ✅ overlap is partial: 28 cells, 439 KPIs |
| 11 | Old pivot columns are built as `K_<KPI_ID>` by Java | `gsb-kpi-calculation/src/main/resources/export.sql` lines 91-107 | `'"K_'\|\|"KPI_ID"\|\|'" numeric'`, `crosstab(...)`, key `"SITE_ID"\|\|"CELL_ID"` (`"SITE_ID"` for SITE level) | ✅ |

⏳ Not yet known: that the old and new calculators used the same counters and KPI definitions for the overlapping period
(parking lot PC-04). The tool reports what matches; it cannot prove the inputs were the same.

## B. The tool against fake data with known differences

Command: `DUCKDB=duckdb tests/run_local_tests.sh` - full output in `docs/local_test_output.txt`. Last lines, verbatim:

```
passed: 33   failed: 0
# exit code: 0
```

The report for the main case (A) shows exactly the known differences: objects only in old = 1, only in new = 1, KPI columns
only in old = 1, only in new = 1, one wrong value (`K_1`, object `1|2`, 50 against 51), one NULL against a value (`K_2`, object
`2|1`), and the rounding difference (5e-9) and the NaN against -1 counted as equal. Variants B-H check: `IDENTICAL` and exit
code 0, `NOT COMPARABLE` and exit code 3 for a period with no data, a KPI mapping file, a tighter tolerance, NULL read as the
default, the NaN rule switched off, and a bad table name refused with exit code 2.

Mistakes found and fixed while testing (so the trail is complete):
* `duckdb_columns()` has no `temporary` column (used `database_name = 'temp'`). 
* the exit code for `NOT COMPARABLE` was 2 instead of 3 (a wrong 9-character match in `run.sh`).
* my fake `DECIMAL(30,8)` column rounded the test value `0.123456785` to 8 decimals, so the rounding case was not tested until the column became `DECIMAL(30,10)`.

## C. The Postgres path (attach, partitioned table, unconstrained `numeric`, `timestamptz`)

Command: `DUCKDB=duckdb tests/run_postgres_test.sh` (throwaway `postgres:16-alpine`, removed at the end; nothing on dev) -
output in `docs/postgres_test_output.txt`. Verbatim result lines:

```
DIFFERENT: objects only old=2 only new=1, KPI columns only old=1 only new=1, values compared=12 different=1 null_old_only=1 null_new_only=0, common objects=3, common KPI columns=4
differences.csv:
period_utc,object_key,kpi,old_value,new_value,abs_diff,kind
2025-12-19 09:00,1|2,K_1,50.0,51.0,1.0,DIFF
2025-12-19 09:00,2|1,K_2,,7.0,,NULL_OLD_ONLY
```

(`only old=2` here because the Postgres fixture also holds one row with NULL site and cell, shown as `<NULL>|<NULL>`.) ✅

## D. Run on dev against the real tables

⏳ **Not run yet.** Needs the files uploaded to dev (the user does this) and the run process the user will give. Planned first
run: the default `config.env` (ENIQS_CAT6 LTE, 2025-12-19 09:00 UTC = 20:00 Sydney). Before it is trusted: PC-04, PC-05, PC-06.
