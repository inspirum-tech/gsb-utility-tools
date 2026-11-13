# DEV run, 2026-10-27

The first live run on DEV and an independent check of its result against exports of `COUNTER_DEF_V2` and the
source tables.

| File | What it is |
|---|---|
| `checks.csv` | The run's checks (all PASS) |
| `migrate.log.txt` | The run's output (`migrate.log`, renamed because `*.log` is ignored by git) |
| `skipped_duplicates.csv` | The 110 rows not migrated, and the row kept for each |

`name_changes.csv` (5.6 MB) and the table exports are not kept here.

## Result

The migration was correct. Nothing was lost or duplicated, and every copied value matches the source.

- All 94,505 source rows are accounted for: 94,395 in `COUNTER_DEF_V2` and 110 in `skipped_duplicates.csv`.
  - No ID was lost, added or repeated.
  - No identity (vendor, measurement, name, attributes) appears twice.
- Every copied column equals the source.
  - Two `DESC_COUNTER_NAME` values only look different in the export: the export tool adds `'` before a value that
    starts with a tab.
- TIME_RESOLUTION: Q → QRLY on 65,555 rows, H → HRLY on 28,840 rows.
- Timestamps were read as Australia/Sydney time, the DEV server default. All 64,289 `FIRST_SEEN_DATE` and 1,816
  `LAST_UPDATED_DATE` values match exactly. 30,106 empty `FIRST_SEEN_DATE` values got the run time.
- No skipped duplicate had an `APPLICATION` the kept row lacks, and no enabled row was dropped for a disabled one.
- The source tables were unchanged (checksums before and after).

## Changed after this run

- **Duplicates:** a row with a `MOCN_NAME` is now kept first. In this run, 12 Nokia (NSN) pairs kept the row
  without one; for example, `M8038C20` lost `IP_TPUT_VOL_UL_QCI6_PLMN`. With the new rule, all 12 keep their
  `MOCN_NAME`. This was checked with a dry run on the same data.
- **Vendors:** `VENDORS=""` (every vendor) is now the default for all environments. This run already included ALC
  and PEMS.
- **Runbook:** step 6 turns `DROP_EXISTING_COUNTER_DEF_V2` off after the live run, so a rerun can't drop the
  counters the parser registers.

## Known gaps

- **`PG_TIMEZONE` is empty**, so timestamps are read in the server's default time zone. DEV was Sydney. Set it
  explicitly for PROD (e.g. `Australia/Sydney`). The value check can't catch a wrong time zone, because it compares
  in the same session.
- **56 ERS names kept a prefix**, so the parser will register new rows for them and the old ones go unused.
  - 11 are named `NRCellCU_GNBDU_...` under the measurement `NRCellDU_GNBDU`; 2 are enabled.
  - 45 are under measurement 20083, which isn't in `MEASUREMENT_DEF`.
- **`pmMacVolDlDrbSingleSlotShortBurstQoS`:** 256 `QoS<n>` rows are plain counters, not bins, because
  `ERS_COUNTER_DEF` spells the name `Qos`. This matches Java and the parser. See
  `FUTURE-ENHACEMENT/FE-002-qos-array-name-case.md`.
- **The log doesn't record the settings used.** The banner (env, vendors, drop) is printed by `migrate.sh` but not
  saved in `migrate.log`.
- **`env/prod.conf`** still needs `PG_HOST` and `PG_USER`.
