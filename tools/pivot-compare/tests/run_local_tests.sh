#!/usr/bin/env bash
# Local test: fake data with KNOWN differences (see make_fake_data.sql); the comparison must report exactly those.
# Needs only the DuckDB CLI (DUCKDB=/path/to/duckdb, default: duckdb). No database server, nothing outside tests/work/.
#   tests/run_local_tests.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DUCKDB="${DUCKDB:-duckdb}"
command -v "$DUCKDB" >/dev/null 2>&1 || [ -x "$DUCKDB" ] || { echo "DuckDB CLI not found; set DUCKDB=" >&2; exit 2; }

W=tests/work
rm -rf "$W"; mkdir -p "$W"
"$DUCKDB" "$W/old.duckdb" < tests/make_fake_data.sql >/dev/null || { echo "could not build the fake OLD data" >&2; exit 2; }
"$DUCKDB" "$W/new.duckdb" < tests/make_fake_data_new.sql >/dev/null || { echo "could not build the fake NEW data" >&2; exit 2; }

PASS=0; FAIL=0
check() {  # name, expected, actual
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok    $1 = $3"
  else FAIL=$((FAIL+1)); echo "  FAIL  $1: expected '$2', got '$3'"; fi
}
metric() { "$DUCKDB" -csv -noheader -c "SELECT value FROM read_csv('$1/summary.csv') WHERE metric = '$2'"; }
rows()   { "$DUCKDB" -csv -noheader -c "SELECT count(*) FROM read_csv('$1')"; }
# variant NAME 'KEY=value' ...  : the test config plus overrides (a later line wins when the file is read)
variant() { local n="$1"; shift; { cat tests/test.env; for o in "$@"; do echo "$o"; done; echo "REPORT_DIR=$W/report_$n"; } > "$W/$n.env"; }
run() { local n="$1"; ./run.sh "$W/$n.env" > "$W/$n.out" 2>&1; echo $?; }

echo "A. all known differences (strict verdict)"
variant A
code=$(run A); R=$W/report_A
check "exit code (1 = DIFFERENT)" 1 "$code"
check "verdict line starts with" DIFFERENT "$(cut -d: -f1 "$R/verdict.txt")"
check "objects only in old" 1 "$(metric $R only_old_objects)"
check "objects only in new" 1 "$(metric $R only_new_objects)"
check "objects in both" 3 "$(metric $R common_objects)"
check "KPI columns in both" 3 "$(metric $R common_kpi_columns)"
check "KPI columns only in old" 1 "$(metric $R only_old_kpi_columns)"
check "KPI columns only in new" 1 "$(metric $R only_new_kpi_columns)"
check "values compared" 9 "$(metric $R values_compared)"
check "values equal (rounding and NaN rule included)" 7 "$(metric $R values_equal)"
check "values different" 1 "$(metric $R values_different)"
check "NULL in old only" 1 "$(metric $R values_null_old_only)"
check "NULL in new only" 0 "$(metric $R values_null_new_only)"
check "rows in differences.csv" 2 "$(rows $R/differences.csv)"
check "rows in objects_one_side.csv" 2 "$(rows $R/objects_one_side.csv)"
check "rows in kpi_columns_one_side.csv" 2 "$(rows $R/kpi_columns_one_side.csv)"
check "the wrong value is K_1 of object 1|2 (50 against 51)" "K_1,1|2,50.0,51.0,DIFF" \
  "$("$DUCKDB" -csv -noheader -c "SELECT kpi, object_key, old_value, new_value, kind FROM read_csv('$R/differences.csv') WHERE kind = 'DIFF'")"
check "the NULL against a value is K_2 of object 2|1" "K_2,2|1,7.0,NULL_OLD_ONLY" \
  "$("$DUCKDB" -csv -noheader -c "SELECT kpi, object_key, new_value, kind FROM read_csv('$R/differences.csv') WHERE kind = 'NULL_OLD_ONLY'")"
check "largest difference of K_1" 1.0 "$("$DUCKDB" -csv -noheader -c "SELECT max_abs_diff FROM read_csv('$R/kpi_summary.csv') WHERE kpi = 'K_1'")"

echo "B. only the KPI that differs by rounding and NaN; objects and columns on one side tolerated -> IDENTICAL"
printf 'K_3\n' > "$W/only_k3.txt"
variant B "KPI_LIST_FILE=$W/only_k3.txt" FAIL_ON_OBJECTS_ONE_SIDE=no FAIL_ON_KPI_COLUMNS_ONE_SIDE=no
code=$(run B); R=$W/report_B
check "exit code (0 = IDENTICAL)" 0 "$code"
check "verdict line starts with" IDENTICAL "$(cut -d: -f1 "$R/verdict.txt")"
check "values compared" 3 "$(metric $R values_compared)"

echo "C. a period with no data -> NOT COMPARABLE, never IDENTICAL"
variant C 'PERIOD_FROM="2025-12-20 00:00:00+00"' 'PERIOD_TO="2025-12-20 00:15:00+00"'
code=$(run C); R=$W/report_C
check "exit code (3 = NOT COMPARABLE)" 3 "$code"
check "verdict line starts with" "NOT COMPARABLE" "$(cut -d: -f1 "$R/verdict.txt")"

echo "D. a KPI mapping file makes K_8 (new) the same KPI as K_9 (old)"
printf 'old_kpi,new_kpi\nK_9,K_8\n' > "$W/map.csv"
variant D "KPI_MAP_FILE=$W/map.csv"
code=$(run D); R=$W/report_D
check "KPI columns in both" 4 "$(metric $R common_kpi_columns)"
check "KPI columns only in old" 0 "$(metric $R only_old_kpi_columns)"
check "values different" 1 "$(metric $R values_different)"

echo "E. a tighter tolerance (1e-9) turns the rounding difference of 5e-9 into a difference"
variant E TOLERANCE_ABS=0.000000001
code=$(run E); R=$W/report_E
check "values different" 2 "$(metric $R values_different)"

echo "F. NULL read as the default value (-1) -> the NULL becomes a difference against 7"
variant F NULL_AS_DEFAULT=yes
code=$(run F); R=$W/report_F
check "values different" 2 "$(metric $R values_different)"
check "NULL in old only" 0 "$(metric $R values_null_old_only)"

echo "G. NaN rule switched off -> NaN against -1 is a difference"
variant G SPECIAL_AS_DEFAULT=no
code=$(run G); R=$W/report_G
check "values different" 2 "$(metric $R values_different)"

echo "H. a table name with something other than letters, digits and _ is refused"
variant H 'OLD_TABLE="old_pivot;drop"'
code=$(run H)
check "exit code (2 = bad setup)" 2 "$code"
check "the message says why" 1 "$(grep -c 'letters, digits' "$W/H.out")"

echo "I. AUTO mode: the families and their old tables are found from the KPI definitions"
variant I MODE=auto AUTO_APPLICATIONS=APP_TEST DEF_SOURCE=duckdb DEF_DB_FILE=$W/new.duckdb DEF_SCHEMA=main DEF_TABLE=KPI_DEFINITION   DEF_DSN_ENV= DEF_CATALOG= AUTO_KPI_PREFIX=K_   'AUTO_OLD_TABLE_PATTERN=KPI_{APPLICATION}_{RES}_{LEVEL}_{TECH}_{VENDOR}_P' 'AUTO_RES_TOKENS=Q=QRLY,H=HRLY,D=DAILY'   DEF_COL_KPI_ID=KPI_ID DEF_COL_APPLICATION=APPLICATION DEF_COL_RESOLUTION=TIME_AGGREGATE DEF_COL_LEVEL=NETWORK_LEVEL   DEF_COL_TECHNOLOGY=TECHNOLOGY DEF_COL_VENDOR=VENDOR
code=$(run I); R=$W/report_I
check "exit code (1 = at least one family DIFFERENT)" 1 "$code"
check "families found (5G, LTE, NR; not the OTHER_APP one, not the one without technology)" 3 "$(rows $R/families.csv)"
check "family KPI ids listed (1,2,3,9 LTE; 8 5G; 20 NR)" 6 "$(rows $R/family_kpis.csv)"
res() { "$DUCKDB" -csv -noheader -c "SELECT result FROM read_csv('$R/families_summary.csv') WHERE family = '$1'"; }
check "5G family" IDENTICAL "$(res KPI_APP_TEST_QRLY_CELL_5G_ERS_P)"
check "LTE family" DIFFERENT "$(res KPI_APP_TEST_QRLY_CELL_LTE_ERS_P)"
check "NR family (no old table)" SKIPPED "$(res KPI_APP_TEST_QRLY_CELL_NR_ERS_P)"
check "the _BKP copy was not compared" 0 "$(ls $R | grep -c BKP)"
RL=$R/KPI_APP_TEST_QRLY_CELL_LTE_ERS_P
check "LTE: objects only in old" 1 "$(metric $RL only_old_objects)"
check "LTE: objects only in new" 1 "$(metric $RL only_new_objects)"
check "LTE: values different" 1 "$(metric $RL values_different)"
check "LTE: NULL in old only" 1 "$(metric $RL values_null_old_only)"
check "LTE: KPI columns only in new (other family's K_8 is not counted)" 0 "$(metric $RL only_new_kpi_columns)"
check "5G: objects only in old and new" 0 "$(( $(metric $R/KPI_APP_TEST_QRLY_CELL_5G_ERS_P only_old_objects) + $(metric $R/KPI_APP_TEST_QRLY_CELL_5G_ERS_P only_new_objects) ))"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
