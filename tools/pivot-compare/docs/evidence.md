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

## C2. AUTO mode (the tables are found from the KPI definitions)

Facts found on dev first:

| # | Claim | Verbatim result | Verdict |
|---|---|---|---|
| 12 | The KPI definitions are in `gsb_data."KPI_DEFINITION"` with `KPI_ID, KPI_NAME, NETWORK_LEVEL, TIME_AGGREGATE, TECHNOLOGY, VENDOR, APPLICATION` | 10 rows listed (also backups `KPI_DEFINITION_13Nov`, `..._BACKUP_20261019`, ... and `gsb_data_UAT."KPI_DEFINITION"`) | ✅ |
| 13 | `ENIQS_CAT6` splits into 3 families | `ENIQS_CAT6 \| Q \| CELL \| 5G \| ERS \| 765 \| 241326 \| 500002`; `... \| LTE \| ERS \| 386 \| 259564 \| 600025`; `... \| NB-IoT \| ERS \| 1 \| 600024 \| 600024` | ✅ |

Tests: local test I (`docs/local_test_output.txt`, 46 of 46 checks, includes: 5G family IDENTICAL, LTE family DIFFERENT, NR family
SKIPPED, the `_BKP` copy not compared, other application and a definition without technology left out, the other family's KPI not
counted as a missing column) and the Postgres test in auto mode (`docs/postgres_test_output.txt`: the old table is found in
Postgres, `NB-IoT` gives `..._NB_IOT_ERS_P` which has no old table and is `SKIPPED`). ✅

⏳ Not yet tried on dev: the name rule against the real old tables of every ENIQS family (for example whether the old NB-IoT table
is really called `..._NB_IOT_ERS_P`; on dev the schema list showed `KPI_ENIQS_CAT6_QRLY_CELL_NB_IOT_ERS_P`).

## D. Run on dev against the real tables

⏳ **Not run yet.** Needs the files uploaded to dev (the user does this) and the run process the user will give. Planned first
run: the default `config.env` (ENIQS_CAT6 LTE, 2025-12-19 09:00 UTC = 20:00 Sydney). Before it is trusted: PC-04, PC-05, PC-06.

## E. CM comparison (new, branch `feature/pivot-compare-cm`)

Environment: Windows 11, DuckDB CLI v1.5.4, fake CM tables `tests/make_fake_cm_old.sql` / `make_fake_cm_new.sql` (known differences: one wrong
value BW of B 10 against 15, one NULL against a value FREQ of C, one object only in each side, one column only in each side, a
1e-9 rounding inside the tolerance, a later CM row after the period that must be ignored).

Command: `DUCKDB=duckdb tests/run_local_tests.sh` - verbatim last lines (full output in `docs/local_test_output.txt`):

```
passed: 65   failed: 0
# exit code: 0
```

Sections J-M are the CM checks (19 of the 65): off by default writes no `cm/` folder; DIFFERENT with exactly the known differences;
no history column gives objects with several rows; a bad `CM_KEY_COLS` is refused with exit code 2. ✅

Facts found on dev (read only), 2026-11-03:

| # | Claim | Verbatim result | Verdict |
|---|---|---|---|
| 14 | CM tables exist in Postgres | `gsb_data_cm`: `CM_ERS_5G_CALC, CM_ERS_LTE_CALC, CM_HW_LTE_CALC, CM_NSN_5G_CALC, CM_NSN_LTE_CALC, CM_PEMS_LTE_CALC`; copies in `gsb_data_cm_backup`; `pems_data_cm.CM_PEMS_LTE_CALC` | ✅ |
| 15 | CM tables keep history | `row_count 92835, cells 90370, loads 403, first_load 2023-06-23 17:39:40, last_load 2026-10-28 05:00:46` | ✅ |
| 16 | Old NS pivot periods | most tables `2025-10-10 00:00 - 23:45`; LTE `2026-04-23 04:30`; 6 tables empty (`CELL_MIXED, NODE_EPNGU, NODE_PIST, NODE_RPUPL, NODE_S1ULINK, NODE_SCTP`) | ✅ |
| 17 | New NS pivot (DuckLake `gsb_data_kpi_pivot_dev`) | LTE cell: `2026-10-24 21:15+11 - 2026-10-25 01:00+11, 16 periods, 499020 rows`; 23 tables named `..._ERS_NEW_P` | ✅ (LTE only checked) |

⏳ Not run against the real dev CM tables yet. The two sides to compare are not decided (parking lot PC-13).

## F. Info columns check (new, branch `feature/pivot-compare-cm`)

Command: `DUCKDB=duckdb tests/run_local_tests.sh` (DuckDB CLI v1.5.4, Windows 11, fake data `tests/make_fake_info.sql`). Last lines, verbatim:

```
passed: 79   failed: 0
# exit code: 0
```

Sections N-Q (14 of the 79): `SITE_NAME, CELL_NAME, LAC, TAC` compared on 3 common objects (12 values: 10 equal incl. `57252.00` against `57252`, 1 CELL_NAME
difference, 1 NULL in old only); the KPI verdict stays IDENTICAL and the exit code 0; `INFO_COMPARE=no` writes no info files; a bad `INFO_COLS`
is refused (exit 2); a tall new side gives `NOT COMPARABLE`. ✅

## G. First real dev run: NS LTE cell (2026-11-03)

Old: Postgres `gsb_data_kpi_pivot."KPI_NS_QRLY_CELL_LTE_ERS_P"` (UAT output loaded 2026-11-03: 1,851,508 rows, 13 periods 2026-10-25 00:00-03:00; the 53,893
April rows were backed up to `..._BKP_20261103` and deleted; daily partition `..._p20261025` added). New: DuckLake `gsb_data_kpi_pivot_dev."KPI_NS_QRLY_CELL_LTE_ERS_NEW_P"`.
Command: `./run.sh config_ns_lte.env` (17 s, exit code 1). Verbatim last line:

```
DIFFERENT: objects only old=68333 only new=889, KPI columns only old=7 only new=0, values compared=12527152 different=545 null_old_only=376624 null_new_only=0, common objects=284708, common KPI columns=44
```

Source rows old 723,434 for 353,041 objects; 55,296 duplicate entries. First differences: all `K_-11` in the first period, old larger than new; cell `81717|67`
new value 113507 equals the OLD value of `81717|66` (hint of repeated old rows; not proven). Reasons for the differences, the empties and the one-side cells: ⏳ not yet analysed.
PC-05 (Sydney time) supported by 284,708 common objects; PC-06 (reading 51 numeric columns, speed) ✅.

## H. `scripts/load_old_table.sh` (loads the UAT old-calculator CSV files into one old pivot table)

Tested 2026-11-03 against a throwaway `postgres:16` container (removed afterwards; nothing on dev) with the real `CELL_NBIOT` files (4 files, 148,006 rows)
and a partitioned test table that held 2 old rows in an old partition. Verbatim result lines:

```
state after run 1: table=148006 backup=2 partitions=T_P_p20250101 T_P_p20261025
2. 148006 existing rows backed up to T_P_BKP_20261103 and deleted from T_P
5. rows in table: 148006   rows in files: 148006   periods: 13
RESULT: OK
load_old_table: backup table T_P_BKP_20261103 already exists; look at it first        (same-day backup exists: stops, deletes nothing)
load_old_table: CSV columns that are not in the table: K_-223                           (table column dropped: refused, 148006 rows unchanged)
```

Mistake found while testing: `zcat | head -1` under `set -o pipefail` ended the script with exit 141 (broken pipe); fixed with `|| true` and a check that the header is not empty. ✅

## I. List-mode run of 16 NS table pairs, 2026-11-05 (dev server `gsb-dev`, DuckDB v1.5.5, OLD = Postgres `gsb_data_kpi_pivot`, NEW = DuckLake `gsb_data_kpi_pivot_dev`)

Command: `./run.sh config_ns_all.env` (list mode, `pairs_ns.csv`, 16 pairs). Log: `report_ns_all_run_<date>_<time>.log`; per-pair folders in `report_ns_all/`.

### I.1 What data each side holds (checked, not assumed)

OLD (UAT file, all 16 old tables, same result for each, verbatim for NODE_IST: `234552 | 2026-10-25 00:00:00 | 2026-10-25 03:00:00 | 13`):
13 periods, 2026-10-25 00:00 to 03:00 Sydney = 2026-10-24 13:00 to 16:00 UTC. NOT a full day. Row count of OLD NODE_IST was 234,552 in two checks hours apart: OLD did not change.

NEW (verbatim, `min/max(PERIOD_START_TIME) AT TIME ZONE 'UTC'`): CELL_* and NODE_CEM: 10:15 to 13:15 UTC, 9 periods; NODE_GCUF/IST/MPR/FRU/FRUSU/EP/ROUTER: 8; NODE_RPUPL: 7; NODE_NRSC and NODE_EPXNU: 12:30 to 13:15, 4 periods.
The NEW tables are CHANGING while we test: NODE_IST first showed `10:15 | 13:00 | 4 periods | last_update 2026-11-05 19:14:38+11`, a few minutes later it ended at 13:15 with 8 periods; an earlier run (window up to 14:15) had listed 1 NEW object at 14:00 which the table no longer holds. Cause not known (possibly the new calculator being run again): ask Pramudi.
Shared window in all 16 tables today: 13:00 and 13:15 UTC (00:00 and 00:15 Sydney) = 2 periods. Config now `PERIOD_FROM=2026-10-24 13:00:00+00`, `PERIOD_TO=2026-10-24 13:30:00+00` (end excluded).
Verdict: ⚠️ test covers 2 of the 13 OLD periods; widen `PERIOD_TO` when NEW reaches 16:00 UTC.

Earlier statements that were WRONG and are withdrawn: "OLD holds a full day" (it holds 3 hours) and "NEW stops before 01:00 Sydney" (it moves).

### I.2 Findings that are data gaps or calculator differences (not script problems)

1. `NODE_RIBTM`: ✅ confirmed no NEW table. Verbatim error: `Catalog Error: Table with name KPI_NS_QRLY_NODE_RIBTM_ERS_NEW_P does not exist!` and the NEW schema lists 18 NODE tables, none RIBTM. Removed from `pairs_ns.csv`.
2. `NODE_GCUF`: OLD column GCUF is always the text `null` (`GCUF | 118663 rows | 9131 sites`), NEW holds `1`.
3. `NODE_IST` device text differs in format: OLD `Router=Inner_IpsecTunnel=1`, NEW `Router=CP_Inner-IpsecTunnel=1-IpsecTunnel`. So the device column cannot be a key. For GCUF, IST, MPR, ROUTER the key is now `SITE_ID` only (site-level check, repeated devices reduced with max()). SITE_ID agrees on both sides (site 94487: OLD 13 rows, 13 periods). Weaker check than a per-device one.
4. `CELL_MIXED`: only old=35413, only new=35347. Examples (verbatim): OLD only `1000LaTrobeStIBC-O:M3884-OL07-A-1`, `...-OL07-A-2`, `...-OL23-A-1`; NEW only `...-OL23-B-1`, `...-OL23-B-2`, `...-ON07-B-1`. Cell `...OL07-A-1`: NEW has it in CELL_LTE (7 rows) and in no other NEW cell table; OLD has it in CELL_LTE (13 rows) AND CELL_MIXED (13 rows). So the old calculator puts this cell in both tables, the new one only in LTE. ✅ for this cell, ⏳ not checked for all 35,000.

### I.3 Result of the run, window 13:00 to 13:30 UTC (verbatim totals line: `pairs: 16   identical: 0   different: 16   not comparable: 0   errors: 0`)

| Pair | only old | only new | values compared | different | null in NEW only | null in OLD only | common objects |
|---|---|---|---|---|---|---|---|
| CELL_LTE | 2794 | 438 | 6090128 | 278 | 0 | 187224 | 138412 |
| CELL_NBIOT | 75 | 82 | 10407825 | 356 | 0 | 0 | 22675 |
| CELL_SG | 70 | 69 | 82152 | 13 | 0 | 0 | 20538 |
| CELL_5G | 36 | 0 | 2400840 | 235 | 404077 | 0 | 88920 |
| CELL_MIXED | 35413 | 35347 | 2316660 | 7117 | 0 | 0 | 115833 |
| NODE_CEM | 45 | 26 | 60192 | 0 | 12 | 0 | 20064 |
| NODE_GCUF | 37 | 24 | 127512 | 1 | 17964 | 0 | 18216 |
| NODE_IST | 47 | 26 | 60186 | 0 | 0 | 0 | 20062 |
| NODE_MPR | 15 | 12 | 138666 | 0 | 0 | 0 | 12606 |
| NODE_NRSC | 7802 | 99 | 80990 | 0 | 0 | 0 | 80990 |
| NODE_FRU | 584 | 142 | 1130070 | 0 | 54 | 0 | 113007 |
| NODE_FRUSU | 21610 | 168 | 797976 | 0 | 0 | 0 | 132996 |
| NODE_EPXNU | 61275 | 110 | 132332 | 0 | 0 | 0 | 132332 |
| NODE_EP | 25770 | 34438 | 883542 | 0 | 96460 | 0 | 80322 |
| NODE_RPUPL | 377 | 377 | 23991492 | 0 | 0 | 0 | 285613 |
| NODE_ROUTER | 61 | 26 | 401280 | 0 | 0 | 0 | 20064 |

Not yet explained (⏳): the 278/356/13/235/7117 cell differences (cause not looked at; repeated OLD rows reduced with max() is one candidate), CELL_5G 404,077 values empty in NEW (ask Pramudi), NODE_EP only old/only new, NODE_EPXNU/FRUSU/NRSC only old (data gap or NEW still loading), CELL_LTE 187,224 empty in OLD and 7 KPI columns only in OLD.
Not run: CM comparison (CM_COMPARE=no, PC-13). NODE_PIST and NODE_EPNGU: OLD files being uploaded, not loaded yet.
