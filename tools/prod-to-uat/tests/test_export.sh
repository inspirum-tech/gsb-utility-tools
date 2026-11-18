#!/usr/bin/env bash
# Tests for export-on-prod.sh with a fake psql (no database needed).
#   bash tests/test_export.sh | tail -1        -> "passed: N   failed: 0"
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPORT="$HERE/export-on-prod.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check(){ if [ "$2" = "$3" ]; then ok; else bad "$1 (expected '$3', got '$2')"; fi; }
has()  { if grep -q -F -- "$3" <<<"$2"; then ok; else bad "$1 (missing '$3')"; fi; }
hasnt(){ if grep -q -F -- "$3" <<<"$2"; then bad "$1 (should not contain '$3')"; else ok; fi; }

# ---- a fake psql: answers the queries the script sends ----------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/psql" <<'STUB'
#!/usr/bin/env bash
# the last argument is the SQL (-c "...")
sql="${@: -1}"
echo "$PGUSER@$PGHOST:$PGPORT/$PGDATABASE pw=${PGPASSWORD:-}" >> "${STUB_LOG:-/dev/null}"
[ -n "${STUB_NO_CONNECT:-}" ] && { echo "psql: could not connect" >&2; exit 2; }
case "$sql" in
  "select 1") echo 1 ;;
  *information_schema.columns*)  [[ "$sql" == *"MISSINGCOL"* || "$sql" == *"NOSUCHTABLE"* ]] && echo 0 || echo 1 ;;
  *information_schema.tables*)   [[ "$sql" == *"NOSUCHTABLE"* ]] && echo 0 || echo 1 ;;
  *"select count(*) from"*)      echo 6 ;;
  COPY*)
    if [ -n "${STUB_FAIL_ON:-}" ] && [[ "$sql" == *"$STUB_FAIL_ON"* ]]; then echo "ERROR: boom" >&2; exit 3; fi
    echo "PERIOD_START_TIME,SITE_ID,K_1"
    # one row per chunk, except the chunk that starts at STUB_EMPTY_FROM
    if [ -n "${STUB_EMPTY_FROM:-}" ] && [[ "$sql" == *">= TIMESTAMP '$STUB_EMPTY_FROM'"* ]]; then exit 0; fi
    echo "2026-10-25 00:00:00,1,1.5"; echo "2026-10-25 00:15:00,2,2.5"
    ;;
  *) echo "stub psql: unknown query: $sql" >&2; exit 9 ;;
esac
STUB
chmod +x "$WORK/bin/psql"
# a python3 that works on this PC too (on Windows "python3" can be a store stub)
PY="$(command -v python3 2>/dev/null || true)"; "$PY" -c 1 >/dev/null 2>&1 || PY="$(command -v python 2>/dev/null || true)"
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$PY" > "$WORK/bin/python3"; chmod +x "$WORK/bin/python3"
export PATH="$WORK/bin:$PATH"

mkcfg() {   # $1 file, then extra lines
  local f="$1"; shift
  cat > "$f" <<EOF
PGHOST="prodhost"
PGPORT="5432"
PGUSER="reader"
PGDATABASE="gsb"
PG_PASSWORD_ENV="TEST_PW"
SCHEMA="gsb_data_kpi_pivot"
TABLES="KPI_A_P,KPI_B-X_P"
PERIOD_FROM="2026-10-25"
PERIOD_TO="2026-10-25 03:15"
OUT_ROOT="$WORK/out"
MIN_FREE_MB="1"
EOF
  for l in "$@"; do echo "$l" >> "$f"; done
}
run() { bash "$EXPORT" "$@" 2>&1; echo "rc=$?"; }
rc()  { sed -n 's/^rc=//p' <<<"$1" | tail -1; }
export TEST_PW='p@ss word$1'

# ---- 1. config checks ----------------------------------------------------------------------------------
mkcfg "$WORK/c1.env"
o="$(run --config "$WORK/nope.env")";                          check "missing config file" "$(rc "$o")" 2
o="$(run)";                                                    check "no --config" "$(rc "$o")" 2
o="$(run --config "$WORK/c1.env" --tables 'A;drop table x')";  check "bad table name" "$(rc "$o")" 2; has "bad table msg" "$o" "must be letters, digits"
o="$(run --config "$WORK/c1.env" --from "25/10/2026")";        check "bad date" "$(rc "$o")" 2
o="$(run --config "$WORK/c1.env" --from "2026-10-26")";        check "from after to" "$(rc "$o")" 2; has "order msg" "$o" "earlier than"
o="$(run --config "$WORK/c1.env" --tables 'A,A')";             check "table twice" "$(rc "$o")" 2
o="$(run --config "$WORK/c1.env" --name 'x y')";               check "bad zip name" "$(rc "$o")" 2
mkcfg "$WORK/c2.env" 'STEP_HOURS="0"';                         o="$(run --config "$WORK/c2.env" --check)"; check "step 0" "$(rc "$o")" 2
mkcfg "$WORK/c3.env" 'TZ_MODE="NOPE"';                         o="$(run --config "$WORK/c3.env" --check)"; check "bad tz mode" "$(rc "$o")" 2
mkcfg "$WORK/c4.env" 'PG_PASSWORD_ENV="NO_SUCH_VAR"';          o="$(run --config "$WORK/c4.env" --check)"; check "empty password var" "$(rc "$o")" 2; has "password var msg" "$o" "NO_SUCH_VAR is empty"
mkcfg "$WORK/c5.env" 'TABLE_TIME_COLUMNS="KPI_A_P"';           o="$(run --config "$WORK/c5.env" --check)"; check "bad TABLE_TIME_COLUMNS" "$(rc "$o")" 2

# ---- 2. --check -------------------------------------------------------------------------------------------
o="$(run --config "$WORK/c1.env" --check --name chk1)"
check "check ok" "$(rc "$o")" 0
has "check connected" "$o" "connected to the database"
has "check rows" "$o" "gsb_data_kpi_pivot.KPI_A_P: time column PERIOD_START_TIME, 6 row(s)"
has "check chunks" "$o" "chunks per table: 4"
has "check writes nothing" "$o" "Nothing was written"
check "check wrote no zip" "$(ls "$WORK/out" 2>/dev/null | grep -c zip)" 0
o="$(run --config "$WORK/c1.env" --check --tables NOSUCHTABLE)";  check "check missing table" "$(rc "$o")" 2; has "missing table msg" "$o" "table not found"
o="$(run --config "$WORK/c5.env" --check --tables KPI_A_P)"
mkcfg "$WORK/c6.env" 'TABLE_TIME_COLUMNS="KPI_A_P:MISSINGCOL"'; o="$(run --config "$WORK/c6.env" --check)"; check "check missing time column" "$(rc "$o")" 2; has "missing col msg" "$o" "time column 'MISSINGCOL' not found"
o="$(STUB_NO_CONNECT=1 run --config "$WORK/c1.env" --check)";     check "check no connection" "$(rc "$o")" 2; has "no connection msg" "$o" "cannot connect"
# password goes to psql from the NAMED variable, never printed
STUB_LOG="$WORK/psql.log" run --config "$WORK/c1.env" --check >/dev/null
has "password reached psql" "$(cat "$WORK/psql.log")" 'pw=p@ss word$1'
o="$(run --config "$WORK/c1.env" --check)"; hasnt "password never printed" "$o" 'p@ss'

# ---- 3. a real export ---------------------------------------------------------------------------------------
o="$(run --config "$WORK/c1.env" --name nstd1)"
check "export rc" "$(rc "$o")" 0
Z="$WORK/out/nstd1.zip"
check "zip exists" "$([ -s "$Z" ] && echo yes || echo no)" yes
check "sha256 file exists" "$([ -s "$Z.sha256" ] && echo yes || echo no)" yes
has "result zip line" "$o" "RESULT_ZIP=$Z"
has "result rows line" "$o" "RESULT_ROWS=16"           # 2 tables x 4 chunks x 2 rows
check "sha256 line equals the file" "$(sed -n 's/^RESULT_SHA256=//p' <<<"$o")" "$(sha256sum "$Z" | cut -d' ' -f1)"
LIST="$("$PY" -c "import zipfile,sys;print('\n'.join(sorted(zipfile.ZipFile(sys.argv[1]).namelist())))" "$Z")"
has "zip root folder is the name" "$LIST" "nstd1/KPI_A_P/_manifest.csv"
has "zip has a hyphen table" "$LIST" "nstd1/KPI_B-X_P/KPI_B-X_P_2026-10-25_03_00_00__to__2026-10-25_03_15_00.csv.gz"
has "chunk 1 name" "$LIST" "nstd1/KPI_A_P/KPI_A_P_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz"
check "files in zip = 2 tables x (4 chunks + manifest)" "$(grep -c . <<<"$LIST")" 10
M="$(cat "$WORK/out/nstd1/KPI_A_P/_manifest.csv")"
has "manifest header" "$M" "file,rows"
has "manifest row" "$M" "KPI_A_P_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz,2"
check "manifest lines" "$(grep -c . <<<"$M")" 5
check "csv.gz content" "$(gzip -dc "$WORK/out/nstd1/KPI_A_P/KPI_A_P_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz" | head -1)" "PERIOD_START_TIME,SITE_ID,K_1"
o="$(run --config "$WORK/c1.env" --name nstd1)";   check "never overwrites a zip" "$(rc "$o")" 2; has "exists msg" "$o" "already exists"

# ---- 4. empty hour: kept as a header-only file by default; dropped with SKIP_EMPTY=yes ----------------------------------
o="$(STUB_EMPTY_FROM='2026-10-25 01:00:00' run --config "$WORK/c1.env" --name empty1 --tables KPI_A_P)"
check "empty hour rc" "$(rc "$o")" 0
M="$(cat "$WORK/out/empty1/KPI_A_P/_manifest.csv")"
has "empty chunk listed with 0 rows" "$M" "KPI_A_P_2026-10-25_01_00_00__to__2026-10-25_02_00_00.csv.gz,0"
check "empty chunk file is header only" "$(gzip -dc "$WORK/out/empty1/KPI_A_P/KPI_A_P_2026-10-25_01_00_00__to__2026-10-25_02_00_00.csv.gz" | grep -c .)" 1
mkcfg "$WORK/c7.env" 'SKIP_EMPTY="yes"'
o="$(STUB_EMPTY_FROM='2026-10-25 01:00:00' run --config "$WORK/c7.env" --name empty2 --tables KPI_A_P)"
check "SKIP_EMPTY rc" "$(rc "$o")" 0
check "SKIP_EMPTY: no file for the empty hour" "$(ls "$WORK/out/empty2/KPI_A_P" | grep -c '01_00_00__to__02_00_00')" 0
check "SKIP_EMPTY: manifest has 3 files + header" "$(grep -c . "$WORK/out/empty2/KPI_A_P/_manifest.csv")" 4

# ---- 5. a failing chunk: no zip, exit 1 ------------------------------------------------------------------------------------
o="$(STUB_FAIL_ON='2026-10-25 02:00:00' run --config "$WORK/c1.env" --name failed1 --tables KPI_A_P)"
check "failed chunk rc" "$(rc "$o")" 1
check "failed chunk: no zip" "$([ -e "$WORK/out/failed1.zip" ] && echo yes || echo no)" no
has "failed chunk message" "$o" "No zip was made"
has "errors file written" "$(cat "$WORK/out/failed1/___All_Errors.txt")" "zip was NOT made"
check "no .part left" "$(find "$WORK/out/failed1" -name '*.part' | wc -l)" 0

# ---- 6. RESUME -----------------------------------------------------------------------------------------------------------------
o="$(run --config "$WORK/c1.env" --name failed1 --tables KPI_A_P)";  check "existing folder refused" "$(rc "$o")" 2; has "folder msg" "$o" "already holds files"
mkcfg "$WORK/c8.env" 'RESUME="yes"'
o="$(run --config "$WORK/c8.env" --name failed1 --tables KPI_A_P)"
check "resume rc" "$(rc "$o")" 0
has "resume skips the done chunks" "$o" "SKIP   KPI_A_P/KPI_A_P_2026-10-25_00_00_00__to__2026-10-25_01_00_00.csv.gz exists (rows=2)"
has "resume total rows" "$o" "RESULT_ROWS=8"

# ---- 7. daylight saving: chunks are plain wall-clock text ------------------------------------------------------------------------
o="$(TZ=Australia/Sydney run --config "$WORK/c1.env" --name dst1 --tables KPI_A_P --from 2026-10-03 --to 2026-10-05)"
check "dst rc" "$(rc "$o")" 0
check "dst: 48 hourly chunks across the 2026-10-04 change" "$(ls "$WORK/out/dst1/KPI_A_P" | grep -c 'csv.gz$')" 48
check "dst: the 02:00 hour exists on 2026-10-04" "$(ls "$WORK/out/dst1/KPI_A_P" | grep -c '2026-10-04_02_00_00__to__2026-10-04_03_00_00')" 1

# ---- 8. step of 2 hours and a part-hour tail ------------------------------------------------------------------------------------------------
mkcfg "$WORK/c9.env" 'STEP_HOURS="2"'
o="$(run --config "$WORK/c9.env" --name step2 --tables KPI_A_P)"
check "step 2 rc" "$(rc "$o")" 0
check "step 2 files" "$(ls "$WORK/out/step2/KPI_A_P" | grep -c 'csv.gz$')" 2
check "step 2 last chunk ends at the period end" "$(ls "$WORK/out/step2/KPI_A_P" | grep -c '02_00_00__to__2026-10-25_03_15_00')" 1

echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
