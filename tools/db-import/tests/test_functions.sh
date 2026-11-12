#!/usr/bin/env bash
# Tests of the pure logic in db-import.sh (no database, no network). Run: bash tests/test_functions.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/db-import.sh"
set +e   # the tests check failures themselves

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "       expected: $2"; echo "       got:      $3"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
fails(){ local name="$1"; shift; if ( "$@" ) >/dev/null 2>&1; then bad "$name" "failure" "success"; else ok "$name"; fi; }
has()  { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "contains: $2" "$3"; fi; }
hasnt(){ if grep -qF -- "$2" <<<"$3"; then bad "$1" "does not contain: $2" "$3"; else ok "$1"; fi; }

echo "norm_ts"
eq "date only"            "2026-11-01 00:00:00" "$(norm_ts 2026-11-01)"
eq "date and HH:MM"       "2026-11-01 06:00:00" "$(norm_ts '2026-11-01 06:00')"
eq "date and HH:MM:SS"    "2026-11-01 06:15:30" "$(norm_ts '2026-11-01 06:15:30')"
eq "T separator"          "2026-11-01 06:15:30" "$(norm_ts '2026-11-01T06:15:30')"
fails "dd/mm/yyyy refused" norm_ts 01/11/2026
fails "impossible date"    norm_ts 2026-02-31
fails "hour 25"            norm_ts '2026-11-01 25:00'
fails "empty"              norm_ts ''

echo "quoting"
eq "sqlq doubles '"        "it''s" "$(sqlq "it's")"
eq "libpq_val plain"       "'abc'" "$(libpq_val abc)"
eq "libpq_val with ' and \\" "'a\\'b\\\\c'" "$(libpq_val "a'b\\c")"
bad_col 'A"B' && ok "bad_col quote" || bad "bad_col quote" 0 1
bad_col 'A,B' && ok "bad_col comma" || bad "bad_col comma" 0 1
bad_col 'PERIOD_START_TIME' && bad "bad_col normal" 1 0 || ok "bad_col normal"
eq "quote_cols"            '"A", "B", "C"' "$(quote_cols $'A\nB\nC\n')"

echo "table list"
TABLES=$'KPI_A, KPI_B=KPI_B_NEW,\n KPI_C'
parse_tables
eq "3 tables"              3 "${#SRC_T[@]}"
eq "mapped target"         "KPI_B_NEW" "${TGT_T[1]}"
eq "same name"             "KPI_C" "${TGT_T[2]}"
TABLES='A;DROP'; fails "bad table name refused" parse_tables
TABLES=''; fails "empty list refused" parse_tables

echo "time column / lists"
TIME_COLUMN=PERIOD_START_TIME; TABLE_TIME_COLUMNS='T2:STARTTIME,T3:INSERT_DT'
eq "default column"        "PERIOD_START_TIME" "$(tcol_for T1)"
eq "override column"       "STARTTIME" "$(tcol_for T2)"
in_list T2 "T1,T2" && ok "in_list yes" || bad "in_list yes" 0 1
in_list T9 "T1,T2" && bad "in_list no" 1 0 || ok "in_list no"

echo "validation"
fails "bad host"           check_re host 'a b;c' "$re_host"
fails "bad identifier"     check_re ident 'a-b' "$re_ident"
check_re ident KPI_NS_QRLY_CELL_5G_ERS_P "$re_ident" && ok "table ident ok" || bad "table ident ok" 0 1

echo "decide_tables"
SRC_T=(T1 T2 T3); TGT_T=(T1 T2 T3)
FROM_TS="2026-11-01 00:00:00"; TO_TS="2026-11-02 00:00:00"
FULL_COPY_TABLES="T3"; TIME_COLUMN=PERIOD_START_TIME; TABLE_TIME_COLUMNS=""
SRC_COLS=($'ID\nPERIOD_START_TIME\nV\n' $'ID\nPERIOD_START_TIME\n' $'ID\nNAME\n')
TGT_COLS=($'ID\nPERIOD_START_TIME\nV\nEXTRA\n' $'ID\nPERIOD_START_TIME\n' $'ID\nNAME\n')
( decide_tables ) >/dev/null 2>&1 && ok "valid set passes" || bad "valid set passes" 0 1
decide_tables >/dev/null 2>&1
eq "T1 is window"          "window" "${MODE[0]}"
eq "T3 is full copy"       "full" "${MODE[2]}"
has "window WHERE"         "\"PERIOD_START_TIME\" >= TIMESTAMP '2026-11-01 00:00:00' AND \"PERIOD_START_TIME\" < TIMESTAMP '2026-11-02 00:00:00'" "${WHERE[0]}"
eq "full WHERE empty"      "" "${WHERE[2]}"
TGT_COLS[0]=$'ID\nPERIOD_START_TIME\n'                 # target lacks column V
( decide_tables ) >/dev/null 2>&1 && bad "missing target column stops" 1 0 || ok "missing target column stops"
TGT_COLS[0]=$'ID\nPERIOD_START_TIME\nV\n'
FULL_COPY_TABLES=""
( decide_tables ) >/dev/null 2>&1 && bad "no time column and not in FULL_COPY_TABLES stops" 1 0 || ok "no time column and not in FULL_COPY_TABLES stops"
FULL_COPY_TABLES="T3"

echo "generated SQL"
TIMEZONE=UTC
SOURCE_TYPE=postgres; TARGET_TYPE=postgres
SOURCE_HOST=10.0.0.1; SOURCE_PORT=5432; SOURCE_DB=gsb; SOURCE_USER=postgres; SOURCE_SCHEMA=gsb_data_prd; SOURCE_PASSWORD_ENV=""
TARGET_HOST=10.0.0.2; TARGET_PORT=5432; TARGET_DB=gsb; TARGET_USER=postgres; TARGET_SCHEMA=gsb_data;    TARGET_PASSWORD_ENV=""
BACKUP_SCHEMA=import_backup; LOAD_MODE=replace; DRY_RUN=no
SRC_T=(KPI_X); TGT_T=(KPI_X); COMMON=($'ID\nPERIOD_START_TIME\nV\n'); MODE=(window)
WHERE=("WHERE \"PERIOD_START_TIME\" >= TIMESTAMP '2026-11-01 00:00:00' AND \"PERIOD_START_TIME\" < TIMESTAMP '2026-11-02 00:00:00'")
EXPECT=(120); BK_NAME=("KPI_X_bak_20261112_101500")
T="$(mktemp -d)"
PG="$(build_pg_sql 0 "$T")"
has "pg: begins a transaction"   "BEGIN;" "$PG"
has "pg: backup table"           'CREATE TABLE "import_backup"."KPI_X_bak_20261112_101500" AS SELECT * FROM "gsb_data"."KPI_X" WHERE' "$PG"
has "pg: delete the window"      'DELETE FROM "gsb_data"."KPI_X" WHERE' "$PG"
has "pg: copy from program"      '\copy "gsb_data"."KPI_X" ("ID", "PERIOD_START_TIME", "V") FROM PROGRAM' "$PG"
has "pg: row check"              "IF n <> 120 THEN RAISE EXCEPTION" "$PG"
has "pg: commit"                 "COMMIT;" "$PG"
hasnt "pg: no rollback in a real run" "ROLLBACK;" "$PG"
has "pg: source query file"      'COPY (SELECT "ID", "PERIOD_START_TIME", "V" FROM "gsb_data_prd"."KPI_X" WHERE' "$(cat "$T/src_0.sql")"
has "pg: no password in program" 'env -u PGPASSWORD' "$PG"
has "pg: time zone passed to the source psql" 'PGTZ=UTC psql' "$PG"
DRY_RUN=yes; PG="$(build_pg_sql 0 "$T")"
has "pg dry-run: rollback"       "ROLLBACK;" "$PG"
hasnt "pg dry-run: no commit"    "COMMIT;" "$PG"
BK_NAME=(""); LOAD_MODE=append; DRY_RUN=no; PG="$(build_pg_sql 0 "$T")"
hasnt "append: no delete"        "DELETE FROM" "$PG"
hasnt "no backup: no backup table" "CREATE TABLE" "$PG"

echo "generated SQL (DuckDB engine)"
OFFLINE=yes; BUNDLE_DIR=/opt/db-import/bundle; DUCK_EXTS="postgres ducklake"
SOURCE_TYPE=ducklake; SOURCE_DB=ducklake; SOURCE_DUCKLAKE_DATA_PATH=/mnt/mfs/gsb_data/duckdb/ducklake; SOURCE_DUCKLAKE_METADATA_SCHEMA=metadata
SOURCE_SCHEMA=gsb_data_kpi_pivot_dev
export DBI_TEST_PW="p'w d"; SOURCE_PASSWORD_ENV=DBI_TEST_PW
BK_NAME=("KPI_X_bak_20261112_101500"); LOAD_MODE=replace; DRY_RUN=no
DK="$(build_duck_sql 0)"
has "duck: stop at first error"  ".bail on" "$DK"
has "duck: bundle extension dir" "SET extension_directory='/opt/db-import/bundle/extensions';" "$DK"
has "duck: no auto download"     "SET autoinstall_known_extensions=false;" "$DK"
has "duck: UTC by default"       "SET TimeZone='UTC';" "$DK"
TIMEZONE=Australia/Sydney
has "duck: time zone from config" "SET TimeZone='Australia/Sydney';" "$(build_duck_sql 0)"
has "pg: time zone from config"   'PGTZ=Australia/Sydney psql' "$(DRY_RUN=no; build_pg_sql 0 "$T")"
fails "bad time zone refused"      check_re TIMEZONE 'Aus tralia;x' '^[A-Za-z0-9_/+-]+$'
TIMEZONE=UTC
has "duck: attach ducklake read only" "AS src (DATA_PATH '/mnt/mfs/gsb_data/duckdb/ducklake', METADATA_SCHEMA 'metadata', READ_ONLY);" "$DK"
has "duck: password quoted for libpq and SQL" "password=''p\\''w d'''" "$DK"
has "duck: insert"               'INSERT INTO tgt."gsb_data"."KPI_X" ("ID", "PERIOD_START_TIME", "V") SELECT "ID", "PERIOD_START_TIME", "V" FROM src."gsb_data_kpi_pivot_dev"."KPI_X" WHERE' "$DK"
has "duck: check uses error()"   "error('row count check failed" "$DK"
has "duck: commit"               "COMMIT;" "$DK"
SOURCE_TYPE=parquet; SOURCE_PARQUET_GLOB='/data/{TABLE}/*.parquet'
has "parquet source expression"  "read_parquet('/data/KPI_X/*.parquet')" "$(tbl_expr SOURCE KPI_X)"
rm -rf "$T"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
