#!/usr/bin/env bash
# Loads the .csv.gz files of ONE folder into ONE old-calculator pivot table in Postgres (the output of the old calculator
# from another environment, for the comparison). Run it from tools/pivot-compare:
#   scripts/load_old_table.sh <folder with the .csv.gz files> <table name> <day YYYY-MM-DD>
#   e.g.  scripts/load_old_table.sh ../../old_cal_import/CELL_5G KPI_NS_QRLY_CELL_5G_ERS_P 2026-10-25
# Steps: 1 check that every CSV column exists in the table, 2 if the table has rows: back them up to <table>_BKP_<date> and
# delete them, 3 add the daily partition <table>_p<YYYYMMDD> if it is missing, 4 load every file (each file is all or nothing),
# 5 count the rows loaded against the file lines. Stops at the first problem. Do not run it twice for the same data: the table
# has no primary key, so a second run would load every row twice (step 2 would back up and clear the first load).
# Connection string: KPI_ENGINE_PG_DSN from ENV_FILE (default ../../.env); it is never printed.
set -euo pipefail
FOLDER="${1:?folder with the .csv.gz files}"; TABLE="${2:?table name}"; DAY="${3:?day YYYY-MM-DD}"
SCHEMA="${SCHEMA:-gsb_data_kpi_pivot}"; ENV_FILE="${ENV_FILE:-../../.env}"
die() { echo "load_old_table: $*" >&2; exit 2; }
[[ "$TABLE" =~ ^[A-Za-z0-9_]+$ && "$SCHEMA" =~ ^[A-Za-z0-9_]+$ ]] || die "table and schema must be letters, digits, _ only"
[[ "$DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "day must look like 2026-10-25"
[ -d "$FOLDER" ] || die "folder not found: $FOLDER"
shopt -s nullglob; FILES=("$FOLDER"/*.csv.gz); [ "${#FILES[@]}" -gt 0 ] || die "no .csv.gz files in $FOLDER"
DSN="${LOAD_DSN:-$(grep '^KPI_ENGINE_PG_DSN=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"')}"; [ -n "$DSN" ] || die "no connection string"
q() { psql "$DSN" -v ON_ERROR_STOP=1 -At -c "$1"; }
REF="\"$SCHEMA\".\"$TABLE\""

echo "== $TABLE: ${#FILES[@]} files from $FOLDER, day $DAY"
# 1. columns
[ "$(q "select count(*) from information_schema.columns where table_schema='$SCHEMA' and table_name='$TABLE'")" -gt 0 ] || die "table $SCHEMA.$TABLE not found"
COLS="$(zcat "${FILES[0]}" 2>/dev/null | head -1 | tr -d '\r' || true)"   # head closes the pipe early: not an error
[ -n "$COLS" ] || die "could not read the header of ${FILES[0]}"
MISSING="$(comm -23 <(printf '%s\n' "$COLS" | tr ',' '\n' | sort) <(q "select column_name from information_schema.columns where table_schema='$SCHEMA' and table_name='$TABLE'" | sort))"
if [ -n "$MISSING" ]; then
  # the UAT calculator may know newer KPIs than this table: with ADD_MISSING_COLUMNS=yes the missing K_<id> columns are added
  # (numeric, like the other KPI columns); any other missing column stays an error
  [ "${ADD_MISSING_COLUMNS:-no}" = yes ] || die "CSV columns that are not in the table: $(echo $MISSING) (set ADD_MISSING_COLUMNS=yes to add K_ columns)"
  for c in $MISSING; do [[ "$c" =~ ^K_-?[0-9]+$ ]] || die "missing column $c is not a K_<id> KPI column; not added"; done
  for c in $MISSING; do q "alter table $REF add column if not exists \"$c\" numeric" >/dev/null; done
  echo "1. added $(echo $MISSING | wc -w) missing KPI columns to the table: $(echo $MISSING)"
fi
echo "1. columns ok: $(printf '%s' "$COLS" | tr ',' '\n' | wc -l) CSV columns all exist in the table"
# 2. existing rows: back up, then delete
BEFORE="$(q "select count(*) from $REF")"
if [ "$BEFORE" -gt 0 ] && [ "${NO_BACKUP:-no}" = yes ]; then
  # explicit decision of the owner: the old rows are not needed (nothing on dev reads this table), so they are deleted without a copy
  q "delete from $REF" >/dev/null
  echo "2. $BEFORE existing rows DELETED from $TABLE without a backup (NO_BACKUP=yes)"
elif [ "$BEFORE" -gt 0 ]; then
  BKP="${TABLE}_BKP_$(date +%Y%m%d)"
  [ -z "$(q "select to_regclass('\"$SCHEMA\".\"$BKP\"')")" ] || die "backup table $BKP already exists; look at it first"
  q "create table \"$SCHEMA\".\"$BKP\" as select * from $REF" >/dev/null
  [ "$(q "select count(*) from \"$SCHEMA\".\"$BKP\"")" = "$BEFORE" ] || die "backup row count differs; nothing was deleted"
  q "delete from $REF" >/dev/null
  echo "2. $BEFORE existing rows backed up to $BKP and deleted from $TABLE"
else
  echo "2. table is empty: no backup needed"
fi
# 3. daily partition
KIND="$(q "select c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname='$SCHEMA' and c.relname='$TABLE'")"
if [ "$KIND" = p ]; then
  PART="${TABLE}_p${DAY//-/}"; NEXT="$(date -d "$DAY + 1 day" +%F)"
  if [ -z "$(q "select to_regclass('\"$SCHEMA\".\"$PART\"')")" ]; then
    q "create table \"$SCHEMA\".\"$PART\" partition of $REF for values from ('$DAY 00:00:00') to ('$NEXT 00:00:00')" >/dev/null
    echo "3. partition $PART added ($DAY to $NEXT)"
  else echo "3. partition $PART exists"; fi
else echo "3. table is not partitioned (relkind '$KIND'): no partition needed"; fi
# 4. load
QCOLS="$(printf '%s' "$COLS" | sed 's/[^,]*/"&"/g')"; EXPECT=0
for f in "${FILES[@]}"; do
  N=$(( $(zcat "$f" | wc -l) - 1 )); EXPECT=$((EXPECT + N))
  echo "4. loading $(basename "$f") ($N rows)"
  zcat "$f" | psql "$DSN" -v ON_ERROR_STOP=1 -c "\\copy $REF ($QCOLS) FROM STDIN WITH (FORMAT csv, HEADER true)" >/dev/null
done
# 5. verify
GOT="$(q "select count(*) from $REF")"
echo "5. rows in table: $GOT   rows in files: $EXPECT   periods: $(q "select count(distinct \"PERIOD_START_TIME\") from $REF")"
[ "$GOT" = "$EXPECT" ] && echo "RESULT: OK" || { echo "RESULT: MISMATCH"; exit 1; }
