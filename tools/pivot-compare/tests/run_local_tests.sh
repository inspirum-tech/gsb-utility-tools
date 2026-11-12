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
"$DUCKDB" "$W/info.duckdb" < tests/make_fake_info.sql >/dev/null || { echo "could not build the fake info data" >&2; exit 2; }
"$DUCKDB" "$W/cm_old.duckdb" < tests/make_fake_cm_old.sql >/dev/null || { echo "could not build the fake OLD CM data" >&2; exit 2; }
"$DUCKDB" "$W/cm_new.duckdb" < tests/make_fake_cm_new.sql >/dev/null || { echo "could not build the fake NEW CM data" >&2; exit 2; }

PASS=0; FAIL=0
check() {  # name, expected, actual
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok    $1 = $3"
  else FAIL=$((FAIL+1)); echo "  FAIL  $1: expected '$2', got '$3'"; fi
}
metric() { "$DUCKDB" -csv -noheader -c "SELECT value FROM read_csv('$1/summary.csv') WHERE metric = '$2'"; }
cmmetric() { "$DUCKDB" -csv -noheader -c "SELECT value FROM read_csv('$1/cm_summary.csv') WHERE metric = '$2'"; }
infometric() { "$DUCKDB" -csv -noheader -c "SELECT value FROM read_csv('$1/info_summary.csv') WHERE metric = '$2'"; }
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

echo "J. CM comparison switched off: no CM folder is written"
check "no cm folder in the report of test A (CM_COMPARE is not set)" 0 "$([ -d "$W/report_A/cm" ] && echo 1 || echo 0)"

echo "K. CM comparison switched on (history: the row in force at PERIOD_TO is used)"
CMCFG=(CM_COMPARE=yes CM_OLD_SOURCE=duckdb CM_OLD_DSN_ENV= CM_OLD_DB_FILE=$W/cm_old.duckdb CM_OLD_SCHEMA=main CM_OLD_TABLE=CM_TEST
  CM_NEW_SOURCE=duckdb CM_NEW_DSN_ENV= CM_NEW_DB_FILE=$W/cm_new.duckdb CM_NEW_SCHEMA=main CM_NEW_TABLE=CM_TEST
  CM_KEY_COLS=CELL_NAME CM_ASOF_COL=INSERT_DT CM_ASOF_TZ=Australia/Sydney CM_EXCLUDE_COLS=)
variant K "${CMCFG[@]}" 'PERIOD_FROM="2025-12-19 09:00:00+00"'
code=$(run K); R=$W/report_K/cm
check "exit code (1 = DIFFERENT)" 1 "$code"
check "CM verdict starts with" DIFFERENT "$(cut -d: -f1 "$R/cm_verdict.txt")"
check "CM objects in old" 4 "$(cmmetric $R old_objects)"
check "CM objects in new" 4 "$(cmmetric $R new_objects)"
check "CM objects in both" 3 "$(cmmetric $R common_objects)"
check "CM objects only in old (D)" 1 "$(cmmetric $R only_old_objects)"
check "CM objects only in new (E)" 1 "$(cmmetric $R only_new_objects)"
check "CM columns in both (BW, STATE, FREQ; not the key or the as-of column)" 3 "$(cmmetric $R common_columns)"
check "CM columns only in old" 1 "$(cmmetric $R only_old_columns)"
check "CM columns only in new" 1 "$(cmmetric $R only_new_columns)"
check "CM values compared" 9 "$(cmmetric $R values_compared)"
check "CM values equal (A's 1e-9 and the later CM row ignored)" 7 "$(cmmetric $R values_equal)"
check "CM values different" 1 "$(cmmetric $R values_different)"
check "CM NULL in old only" 1 "$(cmmetric $R values_null_old_only)"
check "CM objects with several rows after the as-of cut" 0 "$(cmmetric $R objects_with_several_rows)"
check "the wrong value is BW of B (10 against 15)" "B,BW,10.0,15.0" \
  "$("$DUCKDB" -csv -noheader -c "SELECT object_key, cm_column, old_value, new_value FROM read_csv('$R/cm_differences.csv') WHERE kind = 'DIFF'")"

echo "L. CM comparison without a history column: both rows of A count as several rows"
variant L "${CMCFG[@]}" CM_ASOF_COL=
code=$(run L); R=$W/report_L/cm
check "CM objects with several rows" 2 "$(cmmetric $R objects_with_several_rows)"

echo "M. a bad CM key column name is refused"
variant M "${CMCFG[@]}" 'CM_KEY_COLS="CELL_NAME;drop"'
code=$(run M)
check "exit code (2 = bad setup)" 2 "$code"

echo "N. info columns: compared and reported separately, the KPI verdict is not changed"
INFOCFG=(INFO_COMPARE=yes INFO_COLS=SITE_NAME,CELL_NAME,LAC,TAC OLD_DB_FILE=$W/info.duckdb OLD_TABLE=info_old
  NEW_DB_FILE=$W/info.duckdb NEW_TABLE=info_new NEW_SHAPE=wide NEW_FILTER_COL= NEW_FILTER_VALUE=
  FAIL_ON_OBJECTS_ONE_SIDE=no FAIL_ON_KPI_COLUMNS_ONE_SIDE=no)
variant N "${INFOCFG[@]}"
code=$(run N); R=$W/report_N
check "exit code stays 0 (KPI values are IDENTICAL although the info columns differ)" 0 "$code"
check "KPI verdict starts with" IDENTICAL "$(cut -d: -f1 "$R/verdict.txt")"
check "info verdict starts with" DIFFERENT "$(cut -d: -f1 "$R/info_verdict.txt")"
check "info objects compared (the object only in new is not one)" 3 "$(infometric $R objects_compared)"
check "info values compared (3 objects x 4 columns)" 12 "$(infometric $R values_compared)"
check "info values equal (TAC 57252.00 against 57252 is equal)" 10 "$(infometric $R values_equal)"
check "info values different" 1 "$(infometric $R values_different)"
check "info NULL in old only" 1 "$(infometric $R values_null_old_only)"
check "the info difference is CELL_NAME of 1|2" "1|2,CELL_NAME,c12,c12-X"   "$("$DUCKDB" -csv -noheader -c "SELECT object_key, info_column, old_value, new_value FROM read_csv('$R/info_differences.csv') WHERE kind = 'DIFF'")"

echo "O. INFO_COMPARE=no (default): no info files are written"
variant O "${INFOCFG[@]}" INFO_COMPARE=no
code=$(run O); R=$W/report_O
check "no info_verdict.txt" 0 "$([ -f "$R/info_verdict.txt" ] && echo 1 || echo 0)"
check "exit code (0 = IDENTICAL)" 0 "$code"

echo "P. a bad INFO_COLS name is refused"
variant P "${INFOCFG[@]}" 'INFO_COLS="SITE_NAME;drop"'
code=$(run P)
check "exit code (2 = bad setup)" 2 "$code"

echo "Q. a tall NEW side has no info columns: the info check is NOT COMPARABLE, the KPI result is as in A"
variant Q INFO_COMPARE=yes INFO_COLS=CELL_NAME
code=$(run Q); R=$W/report_Q
check "exit code (1 = KPI DIFFERENT, as in A)" 1 "$code"
check "info verdict starts with" "NOT COMPARABLE" "$(cut -d: -f1 "$R/info_verdict.txt")"

echo "R. LIST mode: one config, a file with the table pairs, one report folder per pair"
printf 'name,old_table,new_table,key_cols,info_cols
first,old_pivot,KPI_CALCULATED,SITE_ID;CELL_ID,CELL_NAME
second,old_pivot,KPI_CALCULATED,SITE_ID;CELL_ID,
broken,old_pivot;drop,KPI_CALCULATED,SITE_ID;CELL_ID,
' > "$W/pairs.csv"
variant R MODE=list "PAIRS_FILE=$W/pairs.csv" FAIL_ON_OBJECTS_ONE_SIDE=yes
code=$(run R); R=$W/report_R
check "exit code (2 = one pair could not run)" 2 "$code"
check "first pair: KPI result as in A" DIFFERENT "$(cut -d: -f1 "$R/first/verdict.txt")"
check "first pair: values different as in A" 1 "$(metric $R/first values_different)"
check "second pair has its own report folder" 1 "$([ -f "$R/second/verdict.txt" ] && echo 1 || echo 0)"
check "rows in pairs_summary.csv (3 pairs)" 3 "$(rows $R/pairs_summary.csv)"
check "the broken pair is an ERROR" ERROR "$("$DUCKDB" -csv -noheader -c "SELECT result FROM read_csv('$R/pairs_summary.csv') WHERE name = 'broken'")"
check "info columns only for the pair that asks for them" "1,0" "$([ -f "$R/first/info_verdict.txt" ] && echo -n 1 || echo -n 0),$([ -f "$R/second/info_verdict.txt" ] && echo 1 || echo 0)"

echo "S. FINAL_REPORT=yes in list mode builds the Word report + Excel sheets; a report problem never changes the exit code"
PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then echo "  skipped (python not found)"; else
printf 'name,old_table,new_table,key_cols,info_cols
first,old_pivot,KPI_CALCULATED,SITE_ID;CELL_ID,CELL_NAME
second,old_pivot,KPI_CALCULATED,SITE_ID;CELL_ID,
' > "$W/pairs2.csv"
variant S MODE=list "PAIRS_FILE=$W/pairs2.csv" FAIL_ON_OBJECTS_ONE_SIDE=yes FINAL_REPORT=yes "FINAL_REPORT_DIR=$W/final_S" 'FINAL_REPORT_AUTHOR="Test Person"'
code=$(run S); R=$W/report_S; F=$W/final_S
check "exit code is still the comparison result (1 = DIFFERENT)" 1 "$code"
check "Word report exists" 1 "$([ -s "$F/Test Summary Report - NS Pivot Comparison.docx" ] && echo 1 || echo 0)"
check "one zip of the whole output folder exists" 1 "$([ -s "$F.zip" ] && echo 1 || echo 0)"
check "Results workbook exists" 1 "$([ -s "$F/NS Pivot Comparison - Results.xlsx" ] && echo 1 || echo 0)"
check "one results workbook per table" "1,1" "$([ -s "$F/first/first - results.xlsx" ] && echo -n 1 || echo -n 0),$([ -s "$F/second/second - results.xlsx" ] && echo 1 || echo 0)"
check "run folder was copied to Supporting_details" 1 "$([ -f "$F/Supporting_details/pairs_summary.csv" ] && echo 1 || echo 0)"
check "config_used.env of a table records the key columns it really used" "OLD_KEY_COLS=SITE_ID,CELL_ID" "$(grep '^OLD_KEY_COLS=' "$R/first/config_used.env" | tail -1)"
check "config_used.env of a table records its own old table" "OLD_TABLE=old_pivot" "$(grep '^OLD_TABLE=' "$R/second/config_used.env" | tail -1)"
check "every XML part of the Word and Excel files is well formed" "OK" "$("$PY" -I -c "
import sys, zipfile, xml.dom.minidom as m
f = sys.argv[1]
for p in ['Test Summary Report - NS Pivot Comparison.docx', 'NS Pivot Comparison - Results.xlsx', 'first/first - results.xlsx']:
    z = zipfile.ZipFile(f + '/' + p)
    for n in z.namelist():
        m.parseString(z.read(n))
print('OK')
" "$F" 2>&1 | tail -1)"
check "the Results sheet says NOT MET for table first" 1 "$("$PY" -I -c "
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1] + '/NS Pivot Comparison - Results.xlsx')
print(1 if 'NOT MET' in z.read('xl/worksheets/sheet1.xml').decode() else 0)
" "$F")"
check "the Results sheet shows % equal with the empty value counted as not equal (7 of 9 = 77.78%)" 1 "$("$PY" -I -c "
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1] + '/NS Pivot Comparison - Results.xlsx')
print(1 if '77.78%' in z.read('xl/worksheets/sheet1.xml').decode() else 0)
" "$F")"
# the same run again: the output folder exists, nothing is overwritten, and the exit code is unchanged
code=$(run S)
check "second run: exit code unchanged (1)" 1 "$code"
check "second run: says the folder already exists" 1 "$(grep -c 'already exists' "$W/S.out")"
# a bad report setting only stops the report
variant S2 MODE=list "PAIRS_FILE=$W/pairs2.csv" FAIL_ON_OBJECTS_ONE_SIDE=yes FINAL_REPORT=yes "FINAL_REPORT_DIR=$W/final_S2" 'FINAL_REPORT_TITLE="bad;title"'
code=$(run S2)
check "bad FINAL_REPORT_TITLE: exit code unchanged (1)" 1 "$code"
check "bad FINAL_REPORT_TITLE: no report folder" 0 "$([ -d "$W/final_S2" ] && echo 1 || echo 0)"
fi

echo "T. periods, repeated rows (FAIL_ON_DUPLICATES) and the PASS rule of the report"
"$DUCKDB" "$W/t_old.duckdb" < tests/make_fake_dups.sql >/dev/null || { echo "could not build the fake duplicate data" >&2; exit 2; }
"$DUCKDB" "$W/t_new.duckdb" < tests/make_fake_dups_new.sql >/dev/null || { echo "could not build the fake duplicate NEW data" >&2; exit 2; }
TOLD='OLD_DB_FILE=tests/work/t_old.duckdb'; TNEW='NEW_DB_FILE=tests/work/t_new.duckdb'
# T1: the window holds 3 periods: 09:00 on both sides, 09:15 only in OLD, 09:30 only in NEW
variant T1 "$TOLD" "$TNEW" OLD_TABLE=t_old_per NEW_TABLE=t_new 'PERIOD_TO="2025-12-19 09:45:00+00"'
code=$(run T1); R=$W/report_T1
check "T1 exit code (1: objects of two periods are on one side only)" 1 "$code"
check "T1 periods in total" 3 "$(metric $R periods_total)"
check "T1 periods on both sides" 1 "$(metric $R periods_on_both_sides)"
check "T1 periods only in OLD" 1 "$(metric $R periods_only_old)"
check "T1 periods only in NEW" 1 "$(metric $R periods_only_new)"
check "T1 period_summary.csv has one line per period" 3 "$(rows $R/period_summary.csv)"
check "T1 the 09:15 period is flagged OLD only" "2025-12-19 09:15,OLD only" \
  "$("$DUCKDB" -csv -noheader -c "SELECT period_utc, period_present FROM read_csv('$R/period_summary.csv', types = {'period_utc': 'VARCHAR'}) WHERE period_present = 'OLD only'")"
check "T1 verdict line carries the period coverage" 1 "$(grep -c 'periods on both sides=1 only old=1 only new=1' "$R/verdict.txt")"
# T2: a repeated row with conflicting values; max() makes the pair equal, so only the conflict check can show it
variant T2 "$TOLD" "$TNEW" OLD_TABLE=t_old_conf NEW_TABLE=t_new
code=$(run T2); R=$W/report_T2
check "T2 values different (max() hides the conflict)" 0 "$(metric $R values_different)"
check "T2 conflicting repeated rows" 1 "$(metric $R conflicting_duplicates)"
check "T2 repeated rows in total (object + K_1 + K_2)" 3 "$(metric $R duplicate_entries)"
check "T2 default FAIL_ON_DUPLICATES=conflicting: exit code 1 (DIFFERENT)" 1 "$code"
check "T2 duplicate_keys.csv names the conflicting KPI with min and max" "K_1,yes,10.0,12.0" \
  "$("$DUCKDB" -csv -noheader -c "SELECT kpi, conflicting, min_value, max_value FROM read_csv('$R/duplicate_keys.csv', types = {'conflicting': 'VARCHAR'}) WHERE conflicting = 'yes'")"
variant T3 "$TOLD" "$TNEW" OLD_TABLE=t_old_conf NEW_TABLE=t_new FAIL_ON_DUPLICATES=no
code=$(run T3)
check "T3 FAIL_ON_DUPLICATES=no: exit code 0 (the repeat is only listed)" 0 "$code"
# T4: identical repeated rows are harmless by default, and fail the verdict with FAIL_ON_DUPLICATES=yes
variant T4 "$TOLD" "$TNEW" OLD_TABLE=t_old_same NEW_TABLE=t_new
code=$(run T4); R=$W/report_T4
check "T4 identical repeat: no conflicting rows" 0 "$(metric $R conflicting_duplicates)"
check "T4 identical repeat: exit code 0 by default" 0 "$code"
variant T5 "$TOLD" "$TNEW" OLD_TABLE=t_old_same NEW_TABLE=t_new FAIL_ON_DUPLICATES=yes
code=$(run T5)
check "T5 FAIL_ON_DUPLICATES=yes: exit code 1 for any repeat" 1 "$code"
variant T6 "$TOLD" "$TNEW" OLD_TABLE=t_old_same NEW_TABLE=t_new FAIL_ON_DUPLICATES=maybe
code=$(run T6)
check "T6 a wrong FAIL_ON_DUPLICATES value is refused (exit 2)" 2 "$code"
# T7: the report decides PASS from the numbers, not from the run's verdict. 'extra' is IDENTICAL for the run
# (FAIL_ON_KPI_COLUMNS_ONE_SIDE=no) but has a KPI column only in OLD, so the report must say NOT MET; 'same' is PASS.
PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then echo "  T7 skipped (python not found)"; else
printf 'name,old_table,new_table,key_cols,info_cols
same,t_old_same,t_new,SITE_ID;CELL_ID,
extra,t_old_extra,t_new,SITE_ID;CELL_ID,
' > "$W/pairs_t.csv"
variant T7 "$TOLD" "$TNEW" MODE=list "PAIRS_FILE=$W/pairs_t.csv" FAIL_ON_KPI_COLUMNS_ONE_SIDE=no FINAL_REPORT=yes "FINAL_REPORT_DIR=$W/final_T7"
code=$(run T7); R=$W/report_T7; F=$W/final_T7
check "T7 exit code 0 (both tables are IDENTICAL for the run)" 0 "$code"
check "T7 both tables are IDENTICAL in pairs_summary.csv" 2 "$("$DUCKDB" -csv -noheader -c "SELECT count(*) FROM read_csv('$R/pairs_summary.csv') WHERE result = 'IDENTICAL'")"
check "T7 the report says 1 PASS / 1 NOT MET (the KPI column only in OLD is not hidden)" 1 "$("$PY" -I -c "
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1] + '/NS Pivot Comparison - Results.xlsx')
print(1 if '1 PASS / 1 NOT MET' in z.read('xl/worksheets/sheet1.xml').decode() else 0)
" "$F")"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
