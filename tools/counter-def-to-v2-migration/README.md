# COUNTER_DEF → COUNTER_DEF_V2 migration

A one-time script that copies the counters in `COUNTER_DEF` into the
`COUNTER_DEF_V2` table, which the new counter parser uses.

- `COUNTER_DEF`, `MEASUREMENT_DEF` and `ERS_COUNTER_DEF` are only read, never changed (see "Source tables are safe").
- `COUNTER_DEF_V2` is created if it doesn't exist, using the same definition as the parser.
- Every column is copied exactly as it is, `COUNTER_ID` included. There are two exceptions:
  - Four fields are set the way the parser sets them (next section).
  - An empty `FIRST_SEEN_DATE` gets the time of the run, because V2 requires a value.
- The whole run is one transaction. If anything fails, nothing is saved.

## What changes

| Field | Old (`COUNTER_DEF`) | New (`COUNTER_DEF_V2`) |
|---|---|---|
| `COUNTER_NAME` | `EUtranCellFDD_pmRrcConnEstabAtt` | `pmRrcConnEstabAtt` (raw XML name) |
| `COUNTER_NAME` of an array element | `EUtranCellTDD_pmRadioUeRepCqiDistr##14` | `pmRadioUeRepCqiDistr` (parent name) |
| `ATTRIBUTES` | — | `{}`, or `{"array_bin": 14}` for an array element |
| `SUB_COUNTER` | `Y` / `N` / empty | `Y` for an array element, otherwise `N` |
| `TIME_RESOLUTION` | `Q`, `H` | `QRLY`, `HRLY` (the parser's values, `TIME_RESOLUTION_MAP`) |

The name rule comes from the Java parser.
- For Ericsson, Java writes `<MEASUREMENT_NAME>_<raw name>`, and array elements also get `<separator><n>` added. The script removes both.
- Huawei and Nokia names are already raw, so they are kept as they are.

An array element is any name that matches `<array counter><separator><n>` in `ERS_COUNTER_DEF`, where `COUNTER_SIZE` is 2 or more and `n` is less than `COUNTER_SIZE`. This is the same rule the parser uses.

**Duplicates.** V2 allows only one row per vendor + measurement + name + attributes. If two old rows end up the same, the script keeps one and lists the other in `skipped_duplicates.csv`. It picks the row to keep in this order:
1. The row with a `MOCN_NAME`.
2. Otherwise, the row with `ENABLED='Y'`.
3. Otherwise, the row Java named.
4. Otherwise, the lower `COUNTER_ID`.

On the dev export this skips 110 rows.

**Vendors.** Every vendor in `COUNTER_DEF` is migrated (`VENDORS=""` in `migrate.conf`). To limit the run, list them,
e.g. `VENDORS="ERS,HW,NSN"`.

**TIME_RESOLUTION.** Java stored one letter; the parser stores `MNLY`, `FIVE`, `TEN`, `QRLY`, `HRLY`, `DALY`.
`TIME_RESOLUTION_MAP` in `migrate.conf` maps each letter. A value not in the map stops the run before anything is
written. Without this, the parser would rewrite every migrated counter's value the first time it saw it.

## Source tables are safe

The script writes only to `COUNTER_DEF_V2`, its sequence and its index. Before it writes anything, it refuses to run
if any of these is (or belongs to) a source table:

- `COUNTER_DEF_V2` is `COUNTER_DEF`, `MEASUREMENT_DEF` or `ERS_COUNTER_DEF` (checked by name, then in the database);
- the sequence is owned by, or used as a default by, a source table;
- an index with the configured name already exists on another table;
- with `DROP_EXISTING_COUNTER_DEF_V2="true"`: the table to drop doesn't look like `COUNTER_DEF_V2` (it needs
  `COUNTER_ID`, `VENDOR`, `MEASUREMENT_ID`, `COUNTER_NAME`, `ATTRIBUTES` as jsonb and `SUB_COUNTER`). The drop
  never cascades: anything depending on the table makes the run fail.

It also takes a row count and checksum of each source table at the start and compares them at the end; any
difference fails the run and rolls everything back. Source tables are never locked, so the GSB UI and the parser
are not blocked on them. For extra safety, run it as a database user that has only `SELECT` on the source tables.

## Files

| File | What it is |
|---|---|
| `migrate.conf` | Shared settings: schemas, tables, vendors, column mapping, TIME_RESOLUTION map |
| `env/dev.conf`, `env/uat.conf`, `env/prod.conf` | Each environment's connection and `DROP_EXISTING_COUNTER_DEF_V2` (all `true`); read after `migrate.conf` |
| `migrate.sh` | Run this |
| `migrate.sql` | The migration (called by `migrate.sh`) |
| `docs/dev-run-2026-10-27/` | Evidence of the first DEV run and its validation (see its `README.md`) |

## Needs

- `bash` 4 or newer and `psql` 10 or newer, on any machine that can reach the database. No internet and nothing else is needed.
- A database user that can read the three source tables and create/write `COUNTER_DEF_V2` in `gsb_data`.

## Checks (a live run commits only if all pass)

- **Row counts:** rows inserted = rows selected − duplicates skipped.
- **IDs:** every kept `COUNTER_ID` is in V2 exactly once, and V2 contains no other IDs.
- **Values:** every copied column, in every row, still equals the source value.
- **TIME_RESOLUTION:** every row holds the mapped value (and the counts per mapping are listed).
- **Source tables:** `COUNTER_DEF`, `MEASUREMENT_DEF` and `ERS_COUNTER_DEF` are exactly as they were at the start.
- **Names:** each new name, rebuilt into Java's form, gives back the exact old name.
- **Arrays:**
  - `ATTRIBUTES` is a JSON object.
  - `array_bin` is a whole number of 0 or more.
  - `SUB_COUNTER='Y'` if and only if `array_bin` is set.
  - No element matches two parents.

The results are printed and saved to `checks.csv`. `FAIL` means the run was rolled back. `INFO` lines are counts only.

## Reports (one folder per run, under `reports/`)

| File | Contents |
|---|---|
| `migrate.log` | Everything the run printed |
| `checks.csv` | Every check and count, marked PASS / FAIL / INFO |
| `skipped_duplicates.csv` | Rows not migrated, and the `COUNTER_ID` kept in their place (with both rows' `ENABLED` and `MOCN_NAME`) |
| `name_changes.csv` | Every row whose name or attributes changed: old name → new name |

## Notes

- Stop the counter parser before the live run. The script locks `COUNTER_DEF_V2` while it runs.
- If `COUNTER_DEF_V2` already has rows, the script stops. Set `DROP_EXISTING_COUNTER_DEF_V2="true"` to drop and recreate it in the same transaction. That removes any counters the parser registered there; the parser registers the missing ones again when it next runs.
- The `COUNTER_ID` sequence is kept, and after a live run it is moved past the highest migrated ID. It never moves back, so no ID the parser already handed out is reused.
- `pmFlex` array elements are not converted back to their parent name. Today's `ERS_COUNTER_DEF` has no `pmFlex` arrays.
- Every schema and table name is in `migrate.conf` (`COUNTER_DEF_*`, `MEASUREMENT_DEF_*`, `ERS_COUNTER_DEF_*`, `COUNTER_DEF_V2_*`). For the real run keep `COUNTER_DEF_V2` in the schema the parser reads (`[refdata] schema`): the parser's table and sequence names are fixed.
- The column names of `MEASUREMENT_DEF` and `ERS_COUNTER_DEF` are fixed, as the parser reads them.

---

# Runbook (copy and paste)

### 1. Copy the folder to the server

```bash
scp -r counter-def-to-v2-migration <user>@<server>:~/
ssh <user>@<server>
cd ~/counter-def-to-v2-migration
sed -i 's/\r$//' migrate.sh migrate.conf migrate.sql env/*.conf   # only if edited on Windows
chmod +x migrate.sh
```

### 2. Set the connection

```bash
ENV=dev                                   # dev | uat | prod
cat env/$ENV.conf                         # host and user from the vendor parser's [refdata]
                                          # PROD: fill in PG_HOST and PG_USER first (vi env/prod.conf)
export PGPASSWORD='<password>'
. ./migrate.conf; . env/$ENV.conf
psql -h "$PG_HOST" -U "$PG_USER" -d "$PG_DATABASE" -c 'select 1'    # must print 1
```

### 3. Dry run (changes nothing)

```bash
./migrate.sh --dry-run $ENV
```

The run is good when it ends with `RESULT: DRY RUN OK` and every check shows `PASS`. Look through `reports/<time>_<env>_dry-run/skipped_duplicates.csv`.

### 4. Stop the parser, then do the live run (once per environment)

```bash
./migrate.sh $ENV
```

It's done when the output ends with `RESULT: SUCCESS`. Keep the `reports/<time>_<env>/` folder.

### 5. Quick check afterwards

```bash
psql -h "$PG_HOST" -U "$PG_USER" -d "$PG_DATABASE" -c 'select count(*), count(*) filter (where "SUB_COUNTER"='"'"'Y'"'"') as array_elements from gsb_data."COUNTER_DEF_V2"'
```

Compare these numbers with `rows inserted` and `array bins` in `checks.csv`.

### 6. Turn the drop off, then start the parser

Do this straight after a successful live run, before the parser starts. A second run with the drop on would delete
every counter the parser registers from now on; the parser would register them again with new IDs, and data already
written under the old IDs would point at nothing.

```bash
sed -i 's/^DROP_EXISTING_COUNTER_DEF_V2=.*/DROP_EXISTING_COUNTER_DEF_V2="false"/' env/$ENV.conf
grep DROP_EXISTING env/$ENV.conf          # must print ...="false"
```

Then start the parser again. From now on, a rerun stops with `COUNTER_DEF_V2 already has rows` and changes nothing.

### If it says `RESULT: FAILED`

Nothing was saved. Open `reports/<time>_<env>/migrate.log` and read the `ERROR:` line:

| Error says | Do this |
|---|---|
| `name the environment` / `set PG_HOST and PG_USER` | Run as `./migrate.sh [--dry-run] <dev|uat|prod>`; fill in `env/prod.conf` before a PROD run |
| `COUNTER_DEF_V2 already has rows` | Set `DROP_EXISTING_COUNTER_DEF_V2="true"` in `env/<env>.conf` if it can be replaced, then run again |
| `is a source table` / `is not a free sequence` / `already exists on another table` / `does not look like COUNTER_DEF_V2` | A `COUNTER_DEF_V2_*` name in `migrate.conf` points at the wrong object. Nothing was touched; fix the name |
| `not in TIME_RESOLUTION_MAP` | `COUNTER_DEF` has a TIME_RESOLUTION value the map doesn't know. Add it to `TIME_RESOLUTION_MAP` |
| `validation failed: …` | The listed check failed. Send `checks.csv` and `migrate.log` to the developer |
| `column not found` | A name in `COPY_COLUMNS` is wrong. Fix it in `migrate.conf` |
| `invalid input syntax for type integer` | A copied value doesn't fit V2 (e.g. a `VERSION` like `6.4.0`). Find the row in `COUNTER_DEF` and send it to the developer |
| `password authentication failed` / `could not connect` | Check `PG_HOST`, `PG_USER` and `PGPASSWORD` |

### To undo a live run

`COUNTER_DEF` is unchanged, so undoing means clearing V2, then running again whenever you're ready:

```bash
psql -h "$PG_HOST" -U "$PG_USER" -d "$PG_DATABASE" -c 'delete from gsb_data."COUNTER_DEF_V2"'
```
