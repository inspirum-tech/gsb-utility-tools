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

echo "csv source (no DuckDB: names, coverage, files, columns; DuckDB is stubbed)"
N1='/x/NODE_EPNGU/KPI_NS_QRLY_NODE_EPNGU_ERS_P_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz'
eq  "parse: .csv.gz name" "KPI_NS_QRLY_NODE_EPNGU_ERS_P|2026-10-25 00:00:00|2026-10-25 01:00:00" "$(csv_parse_name "$N1")"
eq  "parse: plain .csv name" "KPI_A|2026-10-25 03:00:00|2026-10-25 03:15:00" "$(csv_parse_name KPI_A_2026-10-25_03_00_00__to__2026-10-25_03_15_00.csv)"
fails "parse: no time range"     csv_parse_name KPI_A.csv.gz
fails "parse: the manifest"      csv_parse_name _manifest.csv
fails "parse: other extension"   csv_parse_name KPI_A_2026-10-25_00_00_00__to__2026-10-25_01_00_00.txt

W0='2026-10-25 00:00:00'; W1='2026-10-25 01:00:00'; W2='2026-10-25 02:00:00'; W3='2026-10-25 03:00:00'; W4='2026-10-25 03:15:00'
gaps() { printf '%s\n' "$@" | csv_gaps "$W0" "$W4"; }
eq  "gaps: complete"              "" "$(gaps "$W0|$W1" "$W1|$W2" "$W2|$W3" "$W3|$W4")"
eq  "gaps: order does not matter" "" "$(gaps "$W3|$W4" "$W0|$W1" "$W2|$W3" "$W1|$W2")"
eq  "gaps: a file in the middle is missing" "no file for $W1 to $W2" "$(gaps "$W0|$W1" "$W2|$W3" "$W3|$W4")"
eq  "gaps: the end is missing"    "no file for $W1 to $W4" "$(gaps "$W0|$W1")"
eq  "gaps: the start is missing"  "no file for $W0 to $W1" "$(gaps "$W1|$W2" "$W2|$W3" "$W3|$W4")"
has "gaps: overlapping files"     "two files overlap" "$(gaps "$W0|$W2" "$W1|$W3" "$W3|$W4")"
eq  "gaps: nothing at all"        "no file for $W0 to $W4" "$(gaps)"

SOURCE_TYPE=csv; SOURCE_CSV_PATH=/data/export_nonstd.zip
eq  "csv: fingerprint"            "csv:/data/export_nonstd.zip" "$(side_fingerprint SOURCE)"
eq  "csv: nothing to attach"      "" "$(duck_attach SOURCE yes)"
if (validate_side SOURCE) >/dev/null 2>&1; then ok "csv: a valid source is accepted"; else bad "csv: a valid source is accepted" "accepted" "refused"; fi
vs_nocsv()  { SOURCE_CSV_PATH=""; validate_side SOURCE; }
vs_badcsv() { SOURCE_CSV_PATH="a b;x"; validate_side SOURCE; }
vs_csvtgt() { TARGET_TYPE=csv; TARGET_CSV_PATH=/x; validate_side TARGET; }
fails "csv: path required"        vs_nocsv
fails "csv: bad path refused"     vs_badcsv
fails "csv as a target refused"   vs_csvtgt

# --- a small download on disk: two tables, the real file name pattern, a manifest next to the files
X="$(mktemp -d)"; mkdir -p "$X/dl/NODE_A" "$X/dl/NODE_B" "$X/tmp"
mkgz() { printf 'PERIOD_START_TIME,ID,V\n%s\n' "$2" | gzip >"$1"; }
A1="$X/dl/NODE_A/KPI_A_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz"
A2="$X/dl/NODE_A/KPI_A_2026-10-25_01_00_00__to__2026-10-25_02_00_00.csv.gz"
B1="$X/dl/NODE_B/KPI_B_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz"
mkgz "$A1" $'2026-10-25 00:00:00,1,0.5\n2026-10-25 00:15:00,2,1.5'
mkgz "$A2" $'2026-10-25 01:00:00,3,2.5\n2026-10-25 01:15:00,4,3.5\n2026-10-25 01:30:00,5,'
mkgz "$B1" $'2026-10-25 00:00:00,9,9.0'
printf 'file,rows\nKPI_A_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz,2\nKPI_A_2026-10-25_01_00_00__to__2026-10-25_02_00_00.csv.gz,3\n' >"$X/dl/NODE_A/_manifest.csv"
printf 'file,rows\nKPI_B_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz,1\n' >"$X/dl/NODE_B/_manifest.csv"
printf 'CorrelationId: x\n\nThe following files/folders have not been downloaded\n0. export/NODE_C\n' >"$X/dl/___All_Errors.txt"

FROM_TS="$W0"; TO_TS="$W2"; TMP="$X/tmp"; RUN_TS=t1; SOURCE_CSV_PATH="$X/dl"; CSV_CHECK_MANIFEST=no; CSV_INCOMPLETE=error
PYTHON=python3; CSV_AUTO=yes; CSV_KEEP_EXTRACTED=no; CSV_WORK_DIR=""
fresh_csv() { CSV_FILES=(); CSV_PROBLEMS=0; CSV_ALL=""; CSV_EXTRACTED=no; CSV_DIR=""; }
fresh_csv
( csv_setup ) >/dev/null 2>&1 && bad "csv: a table with a missing hour stops the run" "failure" "success" || ok "csv: a table with a missing hour stops the run"
fresh_csv; OUT="$( ( csv_setup ) 2>&1 )"
has "csv: the missing hour is named" "KPI_B: no file for 2026-10-25 01:00:00 to 2026-10-25 02:00:00" "$OUT"
has "csv: the download's error list is shown" "export/NODE_C" "$OUT"
fresh_csv; CSV_INCOMPLETE=warn
( csv_setup ) >/dev/null 2>&1 && ok "csv: CSV_INCOMPLETE=warn lets it continue" || bad "csv: CSV_INCOMPLETE=warn lets it continue" "success" "failure"
CSV_INCOMPLETE=error
fresh_csv; rm -rf "$X/dl/NODE_B"
csv_setup >"$X/setup.out" 2>&1; RC=$?
eq  "csv: complete data is accepted" "0" "$RC"
eq  "csv: tables found by the file names" "KPI_A" "${SRC_T[*]}"
eq  "csv: target table = source table (auto)" "KPI_A" "${TGT_T[*]}"
eq  "csv: both hour files are chosen" "2" "$(printf '%s\n' "${CSV_FILES[KPI_A]}" | grep -c .)"
has "csv: read_csv expression" "read_csv(['$A1','$A2'], header=true, all_varchar=true)" "$(tbl_expr SOURCE KPI_A)"
FROM_TS="$W1"; TO_TS="$W2"; fresh_csv; csv_setup >/dev/null 2>&1
eq  "csv: only the file that overlaps the period" "1" "$(printf '%s\n' "${CSV_FILES[KPI_A]}" | grep -c .)"
FROM_TS="$W0"; TO_TS="$W2"
fresh_csv; CSV_AUTO=no; SRC_T=(KPI_A KPI_MISSING); TGT_T=(KPI_A KPI_MISSING)
( csv_setup ) >/dev/null 2>&1 && bad "csv: a table named in TABLES without files stops" "failure" "success" || ok "csv: a table named in TABLES without files stops"
CSV_AUTO=yes
PATHQ="$X/dl/it's"; mkdir -p "$PATHQ"; CSV_FILES[Q]="$PATHQ/f.csv"
has "csv: a quote in a path is doubled" "'$X/dl/it''s/f.csv'" "$(tbl_expr SOURCE Q)"
fresh_csv; mkdir -p "$X/dl/NODE_X"; : >"$X/dl/NODE_X/notes.csv"
( csv_setup ) >/dev/null 2>&1 && bad "csv: an unknown file name stops" "failure" "success" || ok "csv: an unknown file name stops"
rm -rf "$X/dl/NODE_X"

# manifest check, DuckDB stubbed: MCNT,<n>,<rows> in the order of the files
ORIG_FUNCS="$(declare -f duck_head duck_run)"
duck_head() { :; }
duck_run()  { printf 'MCNT,0,%s\nMCNT,1,%s\n' "${FAKE0:-2}" "${FAKE1:-3}"; }
CSV_CHECK_MANIFEST=yes; fresh_csv; FAKE0=2; FAKE1=3; csv_setup >/dev/null 2>&1; RC=$?
eq  "manifest: setup passes when the counts match" "0" "$RC"
FAKE0=2; FAKE1=3; CSV_PROBLEMS=0; csv_check_manifest >/dev/null 2>&1
eq  "manifest: rows equal the manifest"  "0" "$CSV_PROBLEMS"
FAKE0=2; FAKE1=2; CSV_PROBLEMS=0; OUT="$(csv_check_manifest 2>&1)"; csv_check_manifest >/dev/null 2>&1
has "manifest: a different row count is reported" "has 2 rows but its manifest says 3" "$OUT"
eq  "manifest: and counted as a problem" "1" "$CSV_PROBLEMS"
rm -f "$X/dl/NODE_A/_manifest.csv"; CSV_PROBLEMS=0; OUT="$(csv_check_manifest 2>&1)"
has "manifest: a missing manifest is reported" "no _manifest.csv" "$OUT"
printf 'file,rows\nKPI_A_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz,2\n' >"$X/dl/NODE_A/_manifest.csv"; CSV_PROBLEMS=0
OUT="$(csv_check_manifest 2>&1)"
has "manifest: a file that is not listed is reported" "is not listed in" "$OUT"
CSV_CHECK_MANIFEST=no

# a zip is unzipped once; the unzipped copy is removed at the end, a folder you gave is never removed
if python3 -c 'import zipfile' >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    python3 -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
z.write(sys.argv[2], "export/NODE_A/" + sys.argv[2].rsplit("/", 1)[1])
z.close()' "$X/dl.zip" "$A1"
    SOURCE_CSV_PATH="$X/dl.zip"; FROM_TS="$W0"; TO_TS="$W1"; fresh_csv
    csv_setup >/dev/null 2>&1; RC=$?
    eq  "zip: opened and read" "0" "$RC"
    eq  "zip: the table comes from the file name" "KPI_A" "${SRC_T[*]}"
    if [ -d "$CSV_DIR" ]; then ok "zip: unzipped into the work folder"; else bad "zip: unzipped into the work folder" "a folder" "none"; fi
    D="$CSV_DIR"; CSV_KEEP_EXTRACTED=yes; csv_cleanup
    if [ -d "$D" ]; then ok "zip: CSV_KEEP_EXTRACTED=yes keeps the files"; else bad "zip: CSV_KEEP_EXTRACTED=yes keeps the files" "kept" "removed"; fi
    CSV_KEEP_EXTRACTED=no; csv_cleanup
    if [ ! -d "$D" ]; then ok "zip: the unzipped copy is removed"; else bad "zip: the unzipped copy is removed" "removed" "still there"; fi
    SOURCE_CSV_PATH="$X/dl"; fresh_csv; csv_setup >/dev/null 2>&1; csv_cleanup
    if [ -d "$X/dl/NODE_A" ]; then ok "folder: a folder you gave is never removed"; else bad "folder: a folder you gave is never removed" "kept" "removed"; fi
else
    echo "  (zip tests skipped: python3 or unzip is missing here)"
fi
SOURCE_CSV_PATH=""; fresh_csv
( csv_setup ) >/dev/null 2>&1 && bad "csv: no path stops" "failure" "success" || ok "csv: no path stops"

# columns: extra source columns, the WHERE and the casts
SOURCE_TYPE=csv; TIME_COLUMN=PERIOD_START_TIME; TABLE_TIME_COLUMNS=""; FULL_COPY_TABLES=""; TBL_FROM=(); TBL_TO=()   # (an earlier csv_setup left a per-table period behind; a real run resets it)
SRC_T=(KPI_A); TGT_T=(KPI_A); FROM_TS="$W0"; TO_TS="$W2"
SRC_COLS=($'PERIOD_START_TIME\nID\nV\nK_-373\nK_-372\n'); TGT_COLS=($'PERIOD_START_TIME\nID\nV\nOLD_ONLY\n')
EXTRA_SOURCE_COLUMNS=error
OUT="$( ( decide_tables ) 2>&1 )" && bad "extra columns stop by default" "failure" "success" || ok "extra columns stop by default"
has "extra columns are named in the error" "K_-373 K_-372" "$OUT"
EXTRA_SOURCE_COLUMNS=skip; RUN_DIR="$X"; rm -f "$X/skipped_columns.txt"
decide_tables >/dev/null 2>&1; RC=$?
eq  "EXTRA_SOURCE_COLUMNS=skip: passes" "0" "$RC"
eq  "skip: only the columns the target has are loaded" "$(printf 'PERIOD_START_TIME\nID\nV\n')" "$(printf '%s' "${COMMON[0]}")"
has "skip: the skipped columns are saved to a file" "KPI_A: K_-373 K_-372" "$(cat "$X/skipped_columns.txt")"
has "csv WHERE: text compared as local time" "WHERE CAST(\"PERIOD_START_TIME\" AS TIMESTAMP) >= TIMESTAMP '2026-10-25 00:00:00' AND CAST(\"PERIOD_START_TIME\" AS TIMESTAMP) < TIMESTAMP '2026-10-25 02:00:00'" "${WHERE[0]}"
TGT_TY=(); TGT_TY["0|PERIOD_START_TIME"]="TIMESTAMP"; TGT_TY["0|ID"]="INTEGER"; TGT_TY["0|V"]="DECIMAL(30,10)"
eq  "csv: the text is cast to the target types" 'CAST("PERIOD_START_TIME" AS TIMESTAMP) AS "PERIOD_START_TIME", CAST("ID" AS INTEGER) AS "ID", CAST("V" AS DECIMAL(30,10)) AS "V"' "$(csv_select_list 0)"
TARGET_TYPE=duckdb; TARGET_DB_FILE=/x/t.duckdb; TARGET_SCHEMA=s; OFFLINE=no; DUCK_EXTS=""; TIMEZONE=Australia/Sydney
LOAD_MODE=replace; DRY_RUN=no; BACKUP_SCHEMA=import_backup; MODE=(window); EXPECT=(5); BK_NAME=("")
CSV_FILES=(); CSV_FILES[KPI_A]="$A1"
eval "$ORIG_FUNCS"
SQL="$(build_duck_sql 0)"
has "csv: the insert casts and reads the files" 'INSERT INTO tgt."s"."KPI_A" ("PERIOD_START_TIME", "ID", "V") SELECT CAST("PERIOD_START_TIME" AS TIMESTAMP) AS "PERIOD_START_TIME"' "$SQL"
has "csv: read_csv in the insert" "FROM read_csv(['$A1'], header=true, all_varchar=true) WHERE CAST" "$SQL"
has "csv: the session time zone is set" "SET TimeZone='Australia/Sydney'" "$SQL"
rm -rf "$X"
SOURCE_TYPE=parquet; EXTRA_SOURCE_COLUMNS=error

echo "TARGET_STRUCTURE=create (schema, table and column creation; DuckDB is stubbed)"
csv_parse_types "$CSV_TYPES_DEFAULT"; RC=$?
eq  "types: the default rules are valid" "0" "$RC"
eq  "type of the time column"   "TIMESTAMP" "$(csv_col_type PERIOD_START_TIME)"
eq  "type of UPDATE_TIMESTAMP"  "TIMESTAMP" "$(csv_col_type UPDATE_TIMESTAMP)"
eq  "type of SITE_ID"           "INTEGER" "$(csv_col_type SITE_ID)"
eq  "type of a K_ counter"      "DECIMAL(30,10)" "$(csv_col_type 'K_-131')"
eq  "type of CELL_ID"           "INTEGER" "$(csv_col_type CELL_ID)"
eq  "type of LAC (as the real tables)" "DECIMAL(4,2)" "$(csv_col_type LAC)"
eq  "type of SAC (as the real tables)" "DECIMAL(4,2)" "$(csv_col_type SAC)"
eq  "type of TAC (as the real tables)" "DECIMAL(10,2)" "$(csv_col_type TAC)"
eq  "type of a text column"     "VARCHAR" "$(csv_col_type SITE_NAME)"
csv_parse_types 'PERIOD_START_TIME=TIMESTAMP WITH TIME ZONE; *=VARCHAR'
eq  "types: own rules, with a time zone" "TIMESTAMP WITH TIME ZONE" "$(csv_col_type PERIOD_START_TIME)"
eq  "types: own rules, the rest" "VARCHAR" "$(csv_col_type 'K_-131')"
csv_parse_types 'SITE_ID=INTEGER'
csv_col_type SITE_NAME >/dev/null 2>&1 && bad "types: no matching rule fails" "failure" "success" || ok "types: no matching rule fails"
fails "types: an entry without = is refused"     csv_parse_types 'SITE_ID'
fails "types: a type with a bracket is refused"  csv_parse_types 'A=INTEGER); DROP TABLE x'
fails "types: a type with a space is refused"    csv_parse_types 'A=VAR CHAR'
fails "types: a bad column pattern is refused"   csv_parse_types 'A"B=INTEGER'
fails "types: empty is refused"                  csv_parse_types ''
csv_parse_types "$CSV_TYPES_DEFAULT"

ORIG_FUNCS2="$(declare -f duck_head duck_run)"
duck_head() { :; }
SOURCE_TYPE=csv; TARGET_TYPE=duckdb; TARGET_DB_FILE=/x/t.duckdb; TARGET_SCHEMA=s; TARGET_STRUCTURE=create
SRC_T=(KPI_A KPI_B); TGT_T=(KPI_A KPI_B)
duck_run() { printf 'SCH,0,1\nTBL,0,0\nTBL,1,1\n'; }
struct_probe
eq  "probe: the schema exists"        "no"  "$NEW_SCHEMA"
eq  "probe: a table that is missing"  "yes" "${NEW_TBL[0]}"
eq  "probe: a table that exists"      "no"  "${NEW_TBL[1]}"
duck_run() { printf 'SCH,0,0\nTBL,0,0\nTBL,1,0\n'; }
struct_probe
eq  "probe: a missing schema"         "yes" "$NEW_SCHEMA"
eq  "probe: so every table is new"    "yes yes" "${NEW_TBL[0]} ${NEW_TBL[1]}"

# an existing table that lacks two CSV columns, and a table that does not exist
NEW_SCHEMA=no; NEW_TBL=(no yes); ADD_COLS=(); STRUCT_NOTE=(); TGT_TY=()
SRC_COLS=($'PERIOD_START_TIME\nSITE_ID\nK_-1\nK_-373\nK_-372\n' $'PERIOD_START_TIME\nSITE_NAME\nK_-5\n')
TGT_COLS=($'PERIOD_START_TIME\nSITE_ID\nK_-1\nOLD_ONLY\n' '')
struct_fill 0; struct_fill 1
eq  "fill: the missing columns are the ones to add" "$(printf 'K_-373\nK_-372\n')" "$(printf '%s' "${ADD_COLS[0]}")"
eq  "fill: the table lists them now"  "$(printf 'PERIOD_START_TIME\nSITE_ID\nK_-1\nOLD_ONLY\nK_-373\nK_-372\n')" "$(printf '%s' "${TGT_COLS[0]}")"
eq  "fill: an added column gets its rule type" "DECIMAL(30,10)" "${TGT_TY["0|K_-373"]}"
eq  "fill: note for added columns"    "2 column(s) added" "${STRUCT_NOTE[0]}"
eq  "fill: a new table takes all CSV columns" "$(printf 'PERIOD_START_TIME\nSITE_NAME\nK_-5\n')" "$(printf '%s' "${TGT_COLS[1]}")"
eq  "fill: note for a new table"      "new table (3 columns)" "${STRUCT_NOTE[1]}"
eq  "fill: a new table has nothing to add" "" "${ADD_COLS[1]}"
NEW_TBL=(no no); TGT_COLS=($'PERIOD_START_TIME\nSITE_ID\nK_-1\nK_-373\nK_-372\n' $'PERIOD_START_TIME\nSITE_NAME\nK_-5\n'); struct_fill 0
eq  "fill: nothing changes when the columns fit" "-" "${STRUCT_NOTE[0]}"
NEW_TBL=(no yes); TGT_COLS=($'PERIOD_START_TIME\nSITE_ID\nK_-1\nOLD_ONLY\n' ''); struct_fill 0; struct_fill 1
TGT_TY["0|PERIOD_START_TIME"]=TIMESTAMP; TGT_TY["0|SITE_ID"]=INTEGER; TGT_TY["0|K_-1"]="DECIMAL(30,10)"; TGT_TY["0|OLD_ONLY"]=VARCHAR   # (on a real run these come from the target table)

NEW_SCHEMA=yes
DDL="$(struct_ddl 1)"
has "ddl: the schema is created first"   'CREATE SCHEMA IF NOT EXISTS tgt."s";' "$DDL"
has "ddl: the table is created with the rule types" 'CREATE TABLE tgt."s"."KPI_B" ("PERIOD_START_TIME" TIMESTAMP, "SITE_NAME" VARCHAR, "K_-5" DECIMAL(30,10));' "$DDL"
NEW_SCHEMA=no
DDL="$(struct_ddl 0)"
has "ddl: a column is added"      'ALTER TABLE tgt."s"."KPI_A" ADD COLUMN "K_-373" DECIMAL(30,10);' "$DDL"
has "ddl: every missing column"   'ADD COLUMN "K_-372" DECIMAL(30,10);' "$DDL"
hasnt "ddl: nothing is dropped"   "DROP" "$DDL"
TARGET_STRUCTURE=strict
eq  "ddl: strict creates nothing" "" "$(struct_ddl 0)"
TARGET_STRUCTURE=create

# the order inside the transaction: backup, structure, delete, insert
TIMEZONE=UTC; OFFLINE=no; DUCK_EXTS=""; LOAD_MODE=replace; DRY_RUN=no; BACKUP_SCHEMA=import_backup
MODE=(window window); EXPECT=(5 5); BK_NAME=("KPI_A_bak_1" ""); COMMON=("${TGT_COLS[0]}" "${TGT_COLS[1]}")
WHERE=("WHERE x" "WHERE x"); CSV_FILES=(); CSV_FILES[KPI_A]="/d/a.csv.gz"; CSV_FILES[KPI_B]="/d/b.csv.gz"
SQL="$(build_duck_sql 0)"
has   "sql: the added column is cast on insert" 'CAST("K_-373" AS DECIMAL(30,10)) AS "K_-373"' "$SQL"
BEFORE_ALTER="${SQL%%ALTER TABLE*}"; AFTER_ALTER="${SQL#*ALTER TABLE}"
has   "sql: the backup comes before the ALTER"  'CREATE TABLE tgt."import_backup"."KPI_A_bak_1"' "$BEFORE_ALTER"
hasnt "sql: the delete does not come before the ALTER" 'DELETE FROM' "$BEFORE_ALTER"
has   "sql: the delete comes after the ALTER"   'DELETE FROM' "$AFTER_ALTER"
has   "sql: the insert comes after the ALTER"   'INSERT INTO tgt."s"."KPI_A"' "$AFTER_ALTER"
NEW_SCHEMA=yes
SQL="$(build_duck_sql 1)"
has   "sql: a new table is created inside the transaction" 'CREATE TABLE tgt."s"."KPI_B"' "$SQL"
BEFORE_BEGIN="${SQL%%BEGIN;*}"
hasnt "sql: nothing is created before BEGIN"   'CREATE TABLE tgt."s"."KPI_B"' "$BEFORE_BEGIN"
NEW_SCHEMA=no
TARGET_STRUCTURE=strict; SQL="$(build_duck_sql 0)"
hasnt "sql: strict has no structure statements" 'ALTER TABLE' "$SQL"
TARGET_STRUCTURE=create

# the plan text and the saved statements
SRC_T=(KPI_A KPI_B); NEW_SCHEMA=yes; NEW_TBL=(yes yes); RUN_DIR="$(mktemp -d)"
OUT="$(structure_report)"
has "report: says the schema will be created" "the schema s does not exist and will be CREATED" "$OUT"
has "report: statements are saved" "structure_changes.sql" "$OUT"
if [ -s "$RUN_DIR/structure_changes.sql" ]; then ok "report: structure_changes.sql is written"; else bad "report: structure_changes.sql is written" "a file" "none"; fi
NEW_SCHEMA=no; NEW_TBL=(no no); STRUCT_NOTE=(- -); rm -f "$RUN_DIR/structure_changes.sql"
has "report: says nothing to create when it all fits" "already fit, nothing to create" "$(structure_report)"
rm -rf "$RUN_DIR"; RUN_DIR=""
eval "$ORIG_FUNCS2"
TARGET_STRUCTURE=strict; SOURCE_TYPE=parquet

echo "PERIOD_FROM / PERIOD_TO = auto, and a folder of zips (DuckDB and unzip are not needed: the zip listing is stubbed)"
# a download where the two tables cover different ranges: KPI_A 00:00-02:00 (two files), KPI_B 00:00-01:00 (one file)
X="$(mktemp -d)"; mkdir -p "$X/dl/NODE_A" "$X/dl/NODE_B" "$X/tmp"
mkgz2() { printf 'PERIOD_START_TIME,ID\n%s\n' "$2" | gzip >"$1"; }
mkgz2 "$X/dl/NODE_A/KPI_A_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz" $'2026-10-25 00:00:00,1'
mkgz2 "$X/dl/NODE_A/KPI_A_2026-10-25_01_00_00__to__2026-10-25_02_00_00.csv.gz" $'2026-10-25 01:00:00,2'
mkgz2 "$X/dl/NODE_B/KPI_B_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz" $'2026-10-25 00:00:00,3'
SOURCE_TYPE=csv; SOURCE_CSV_PATH="$X/dl"; TMP="$X/tmp"; RUN_TS=t2; CSV_CHECK_MANIFEST=no; CSV_INCOMPLETE=error; CSV_AUTO=yes
PERIOD_AUTO_FROM=yes; PERIOD_AUTO_TO=yes; FROM_TS="0001-01-01 00:00:00"; TO_TS="9999-12-31 23:59:59"; DBI_ZIP=""
fresh_csv
csv_setup >"$X/o.txt" 2>&1; RC=$?
eq  "auto: accepted, each table has its own range" "0" "$RC"
eq  "auto: the tables found in the files"   "KPI_A KPI_B" "${SRC_T[*]}"
eq  "auto: table A starts at its first file" "2026-10-25 00:00:00" "${TBL_FROM[0]}"
eq  "auto: table A ends at its last file"    "2026-10-25 02:00:00" "${TBL_TO[0]}"
eq  "auto: table B has only its own hour"    "2026-10-25 00:00:00 2026-10-25 01:00:00" "${TBL_FROM[1]} ${TBL_TO[1]}"
has "auto: the period of each table is logged" "KPI_B: 1 file(s), period 2026-10-25 00:00:00 to 2026-10-25 01:00:00" "$(cat "$X/o.txt")"
eq  "period text: both ends auto" "(start of the files)  <=  PERIOD_START_TIME  <  (end of the files)" "$(period_text)"

# only the end is auto: from 01:00 on
PERIOD_AUTO_FROM=no; FROM_TS="2026-10-25 01:00:00"; fresh_csv
csv_setup >/dev/null 2>&1
eq  "auto end: only the table with data from 01:00 on"  "KPI_A" "${SRC_T[*]}"
eq  "auto end: the start stays as given"  "2026-10-25 01:00:00 2026-10-25 02:00:00" "${TBL_FROM[0]} ${TBL_TO[0]}"
eq  "period text: only the end is auto"   "2026-10-25 01:00:00  <=  PERIOD_START_TIME  <  (end of the files)" "$(period_text)"
PERIOD_AUTO_FROM=yes; FROM_TS="0001-01-01 00:00:00"

# a hole inside a table's files is still caught
mkgz2 "$X/dl/NODE_A/KPI_A_2026-10-25_03_00_00__to__2026-10-25_04_00_00.csv.gz" $'2026-10-25 03:00:00,9'
fresh_csv; OUT="$( ( csv_setup ) 2>&1 )" && bad "auto: a gap inside the files stops the run" "failure" "success" || ok "auto: a gap inside the files stops the run"
has "auto: the gap is named" "KPI_A: no file for 2026-10-25 02:00:00 to 2026-10-25 03:00:00" "$OUT"
rm -f "$X/dl/NODE_A/KPI_A_2026-10-25_03_00_00__to__2026-10-25_04_00_00.csv.gz"

# the WHERE of a table uses its own period
PERIOD_AUTO_FROM=no; PERIOD_AUTO_TO=no; FROM_TS="2026-11-01 00:00:00"; TO_TS="2026-11-02 00:00:00"
SRC_T=(KPI_A); TGT_T=(KPI_A); FULL_COPY_TABLES=""; TIME_COLUMN=PERIOD_START_TIME; TABLE_TIME_COLUMNS=""; EXTRA_SOURCE_COLUMNS=error
SRC_COLS=($'PERIOD_START_TIME\nID\n'); TGT_COLS=($'PERIOD_START_TIME\nID\n'); TBL_FROM=("2026-10-25 01:00:00"); TBL_TO=("2026-10-25 02:00:00")
decide_tables >/dev/null 2>&1
has "WHERE: the table's own period is used" "TIMESTAMP '2026-10-25 01:00:00' AND CAST(\"PERIOD_START_TIME\" AS TIMESTAMP) < TIMESTAMP '2026-10-25 02:00:00'" "${WHERE[0]}"
TBL_FROM=(); TBL_TO=(); decide_tables >/dev/null 2>&1
has "WHERE: without a table period the global one is used" "TIMESTAMP '2026-11-01 00:00:00'" "${WHERE[0]}"
eq  "period text: a fixed period" "2026-11-01 00:00:00  <=  PERIOD_START_TIME  <  2026-11-02 00:00:00" "$(period_text)"

# ---- a folder of zips
ORIG_ZN="$(declare -f csv_zip_names)"
csv_zip_names() { # stub: what is "inside" each zip
    case "$(basename "$1")" in
        a.zip|01_a.zip) printf '%s\n' "export/NODE_A/KPI_A_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz" "export/NODE_A/_manifest.csv" "export/___All_Errors.txt" "export/NODE_A/" ;;
        b.zip|02_b.zip) printf '%s\n' "export/NODE_A/KPI_A_2026-10-25_01_00_00__to__2026-10-25_02_00_00.csv.gz" "export/NODE_C/KPI_C_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz" ;;
        c.zip)    printf '%s\n' "export/NODE_A/KPI_A_2026-10-25_01_00_00__to__2026-10-25_02_00_00.csv.gz" ;;
        d.zip)    printf '%s\n' "export/NODE_A/KPI_A_2026-10-25_03_00_00__to__2026-10-25_04_00_00.csv.gz" ;;
        03_c.zip) printf '%s\n' "export/NODE_D/KPI_D_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz" ;;
    esac
}
PERIOD_AUTO_FROM=yes; PERIOD_AUTO_TO=yes; FROM_TS="0001-01-01 00:00:00"; TO_TS="9999-12-31 23:59:59"; CSV_AUTO=yes; CSV_INCOMPLETE=error
fresh_csv; OUT="$( ( csv_prescan /z/a.zip /z/b.zip ) 2>&1 )"; RC=$?
eq  "zips: two zips that fit together are accepted" "0" "$RC"
has "zips: and it says so" "the zip files fit together" "$OUT"
fresh_csv; OUT="$( ( csv_prescan /z/a.zip /z/b.zip /z/c.zip ) 2>&1 )" && bad "zips: the same table and time in two zips is refused" "failure" "success" || ok "zips: the same table and time in two zips is refused"
has "zips: the overlap is named" "KPI_A: two files overlap" "$OUT"
fresh_csv; OUT="$( ( csv_prescan /z/a.zip /z/d.zip ) 2>&1 )" && bad "zips: a gap between the zips is refused" "failure" "success" || ok "zips: a gap between the zips is refused"
has "zips: the gap is named" "KPI_A: no file for 2026-10-25 01:00:00 to 2026-10-25 03:00:00" "$OUT"
fresh_csv; CSV_INCOMPLETE=warn; ( csv_prescan /z/a.zip /z/d.zip ) >/dev/null 2>&1 && ok "zips: CSV_INCOMPLETE=warn lets a gap pass" || bad "zips: CSV_INCOMPLETE=warn lets a gap pass" "success" "failure"
CSV_INCOMPLETE=error
CSV_AUTO=no; SRC_T=(KPI_Z); fresh_csv
( csv_prescan /z/a.zip /z/b.zip ) >/dev/null 2>&1 && bad "zips: a table in none of the zips is refused" "failure" "success" || ok "zips: a table in none of the zips is refused"
CSV_AUTO=yes

# the runner: name order, one run per zip, stops at the first failure
D="$X/multi"; mkdir -p "$D" "$X/empty"; : >"$D/02_b.zip"; : >"$D/01_a.zip"; : >"$D/03_c.zip"
printf '#!/bin/bash\necho "$DBI_ZIP|$DBI_JOB_SUFFIX|$*" >>"$CHILD_LOG"\ncase "$DBI_ZIP" in *02_b.zip) [ -z "${CHILD_FAIL:-}" ] || exit 1 ;; esac\nexit 0\n' >"$X/child.sh"
export CHILD_LOG="$X/child.log"; CSV_CHILD_CMD="$X/child.sh"; DBI_ZIP_PAUSE=0; ORIG_ARGS=(--dry-run /x/job.env); JOB_NAME=job
SOURCE_CSV_PATH="$D"; : >"$CHILD_LOG"; fresh_csv
if csv_has_zips "$D"; then ok "folder: a folder with zip files is recognised"; else bad "folder: a folder with zip files is recognised" "yes" "no"; fi
if csv_has_zips "$X/empty"; then bad "folder: a folder without zips is not a folder of zips" "no" "yes"; else ok "folder: a folder without zips is not a folder of zips"; fi
OUT="$(csv_multi_zip 2>&1)"; RC=$?
eq  "run: all zips done, exit code 0" "0" "$RC"
eq  "run: the zips run in name order" "01_a.zip 02_b.zip 03_c.zip" "$(cut -d'|' -f1 "$CHILD_LOG" | while read -r l; do basename "$l"; done | tr '\n' ' ' | sed 's/ $//')"
has "run: every zip gets its own report name" "|_02_02_b|" "$(cat "$CHILD_LOG")"
has "run: the options are passed on" "--dry-run /x/job.env" "$(cat "$CHILD_LOG")"
has "run: it says all zips are done" "all 3 zip files done" "$OUT"
: >"$CHILD_LOG"; export CHILD_FAIL=1; fresh_csv
OUT="$(csv_multi_zip 2>&1)"; RC=$?
eq  "run: a failing zip gives its exit code" "1" "$RC"
eq  "run: the zips after the failure are not run" "2" "$(grep -c . "$CHILD_LOG")"
has "run: it says where it stopped" "stopped at zip 2 of 3" "$OUT"
unset CHILD_FAIL CHILD_LOG; CSV_CHILD_CMD=""
eval "$ORIG_ZN"
rm -rf "$X"
PERIOD_AUTO_FROM=no; PERIOD_AUTO_TO=no; SOURCE_TYPE=parquet; DBI_ZIP=""

rm -rf "$T"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
