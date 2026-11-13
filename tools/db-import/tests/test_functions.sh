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
echo "flightsql source (no API: a fake flight_py stands in for the helper)"
SOURCE_TYPE=flightsql; SOURCE_HOST=localhost; SOURCE_PORT=8815; SOURCE_SCHEMA=gsb_data_kpi_pivot; EXPORT_DIR=/data/export
unset SOURCE_PASSWORD_ENV
eq  "flightsql: fingerprint"            "flightsql:localhost:8815" "$(side_fingerprint SOURCE)"
has "flightsql: source expression reads the exported files" "read_parquet('/data/export/KPI_X/*.parquet')" "$(tbl_expr SOURCE KPI_X)"
eq  "flightsql: nothing to attach"      "" "$(duck_attach SOURCE yes)"
if (validate_side SOURCE) >/dev/null 2>&1; then ok "flightsql: a valid source is accepted"; else bad "flightsql: a valid source is accepted" "accepted" "refused"; fi
vs_noport()   { SOURCE_PORT="";            validate_side SOURCE; }
vs_nohost()   { SOURCE_HOST="";            validate_side SOURCE; }
vs_noschema() { SOURCE_SCHEMA="";          validate_side SOURCE; }
vs_badhost()  { SOURCE_HOST="a b;x";       validate_side SOURCE; }
vs_badport()  { SOURCE_PORT="88x";         validate_side SOURCE; }
vs_target()   { TARGET_TYPE=flightsql; TARGET_HOST=localhost; TARGET_PORT=8815; TARGET_SCHEMA=s; validate_side TARGET; }
fails "flightsql: port required"      vs_noport
fails "flightsql: host required"      vs_nohost
fails "flightsql: schema required"    vs_noschema
fails "flightsql: bad host refused"   vs_badhost
fails "flightsql: bad port refused"   vs_badport
fails "flightsql as a target refused" vs_target

SRC_T=(KPI_X KPI_Y); TGT_T=(KPI_X KPI_Y); FROM_TS="2026-10-25 00:00:00"; TO_TS="2026-10-25 02:00:00"; TIMEZONE=Australia/Sydney
FLIGHT_MAX_ROWS=100000; FLIGHT_TIMEOUT_SECONDS=120; FLIGHT_SLICE_MINUTES=10; FLIGHT_PAUSE_SECONDS=2; EXPORT_OVERWRITE=no; EXPORT_ONLY=no
TIME_COLUMN=PERIOD_START_TIME; TABLE_TIME_COLUMNS="KPI_Y:period_start_time"
flight_py() {   # fake helper: records its arguments, answers like the real one
    printf '%s\n' "$*" >>"$T/flight_calls.txt"
    case "$1 $*" in
        "probe "*"--table KPI_X "*) printf 'TYPE,aware\nCOLUMN,PERIOD_START_TIME\nNCOLS,2\nSCOL,ID\nSCOL,PERIOD_START_TIME\nCOUNT,42\n' ;;
        "probe "*)                  printf 'TYPE,naive\nCOLUMN,period_start_time\nNCOLS,1\nSCOL,period_start_time\nCOUNT,7\n' ;;
        "export "*"--table KPI_X "*) printf 'TYPE,aware\nCOLUMN,PERIOD_START_TIME\nNCOLS,2\nSLICE,1,2,20\nSLICE,2,2,22\nTOTAL,42\n' ;;
        "export "*)                 printf 'TYPE,naive\nSLICE,1,1,9\nTOTAL,9\n' ;;
    esac
}
TMP="$T"; : >"$T/flight_calls.txt"
flight_probe_all >"$T/probe.out" 2>&1
eq  "probe: row count of table 1"       "42" "${SRC_CNT[0]}"
eq  "probe: row count of table 2"       "7"  "${SRC_CNT[1]}"
eq  "probe: kind of table 1"            "aware" "${FL_KIND[0]}"
eq  "probe: kind of table 2"            "naive" "${FL_KIND[1]}"
eq  "probe: real time column name"      "period_start_time" "${FL_COL[1]}"
eq  "probe: column list of table 1"     "$(printf 'ID\nPERIOD_START_TIME\n')" "$(printf '%s' "${SRC_COLS[0]}")"
has "probe: time column from TABLE_TIME_COLUMNS is passed" "--table KPI_Y --time-column period_start_time" "$(cat "$T/flight_calls.txt")"
has "probe: window and time zone are passed" '--from-local 2026-10-25 00:00:00 --to-local 2026-10-25 02:00:00 --timezone Australia/Sydney' "$(cat "$T/flight_calls.txt")"
has "probe: row cap and timeout are passed" '--max-rows 100000 --timeout-seconds 120' "$(cat "$T/flight_calls.txt")"
TC=(); tc0="$(tcol_for KPI_X)"; [ -z "${FL_COL[0]:-}" ] || tc0="${FL_COL[0]}"
eq  "decide: the probe's column name wins" "PERIOD_START_TIME" "$tc0"

# the data changed between the count and the export: the exported total is used and the expectation follows
TGT_CNT=(5 5); LOAD_MODE=replace; set_expect 0; eq "set_expect replace" "42" "${EXPECT[0]}"
LOAD_MODE=append;  set_expect 0; eq "set_expect append"  "47" "${EXPECT[0]}"
LOAD_MODE=replace
: >"$T/flight_calls.txt"
flight_export_all >"$T/export.out" 2>&1; OUT="$(cat "$T/export.out")"
has "export: slice progress is shown" "slice 2,2,22" "$OUT"
has "export: slice size, pause and output folder are passed" "--slice-minutes 10 --pause-seconds 2" "$(cat "$T/flight_calls.txt")"
hasnt "export: no --overwrite by default" "--overwrite" "$(cat "$T/flight_calls.txt")"
eq  "export: total equals the count, no warning" "42" "${SRC_CNT[0]}"
eq  "export: table 2 total replaces the count"   "9"  "${SRC_CNT[1]}"
eq  "export: expectation follows the new total"  "9"  "${EXPECT[1]}"
has "export: warns when the data changed" "the earlier count said 7" "$OUT"
EXPORT_OVERWRITE=yes; : >"$T/flight_calls.txt"; flight_export_all >/dev/null 2>&1
has "export: --overwrite only when asked" "--overwrite" "$(cat "$T/flight_calls.txt")"
EXPORT_OVERWRITE=no

# EXPORT_KEEP
X="$(mktemp -d)"; EXPORT_DIR="$X/exp"; mkdir -p "$EXPORT_DIR/KPI_X" "$EXPORT_DIR/KPI_Y" "$EXPORT_DIR/KEEP_ME"; : >"$EXPORT_DIR/KPI_X/a.parquet"
FL_EXPORTED=" KPI_X KPI_Y"
EXPORT_KEEP=yes; flight_cleanup
if [ -d "$EXPORT_DIR/KPI_X" ]; then ok "EXPORT_KEEP=yes keeps the files"; else bad "EXPORT_KEEP=yes keeps the files" "kept" "removed"; fi
EXPORT_KEEP=no; flight_cleanup
if [ ! -e "$EXPORT_DIR/KPI_X" ] && [ ! -e "$EXPORT_DIR/KPI_Y" ]; then ok "EXPORT_KEEP=no removes the exported tables"; else bad "EXPORT_KEEP=no removes the exported tables" "removed" "still there"; fi
if [ -d "$EXPORT_DIR/KEEP_ME" ]; then ok "EXPORT_KEEP=no leaves other folders alone"; else bad "EXPORT_KEEP=no leaves other folders alone" "kept" "removed"; fi
rm -rf "$X"
unset -f flight_py
SOURCE_TYPE=parquet

rm -rf "$T"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
