#!/usr/bin/env bash
# Tests for run-all.sh: the real export-on-prod.sh (fake psql) + fake db-import and pivot-compare. REMOTE_MODE=local, so no SSH.
#   bash tests/test_run_all.sh | tail -1        -> "passed: N   failed: 0"
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNALL="$HERE/run-all.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check(){ if [ "$2" = "$3" ]; then ok; else bad "$1 (expected '$3', got '$2')"; fi; }
has()  { if grep -q -F -- "$3" <<<"$2"; then ok; else bad "$1 (missing '$3')"; fi; }
hasnt(){ if grep -q -F -- "$3" <<<"$2"; then bad "$1 (should not contain '$3')"; else ok; fi; }

mkdir -p "$WORK/bin" "$WORK/dbi" "$WORK/pc"
cp "$HERE/export-on-prod.sh" "$WORK/export-on-prod.sh"   # a path without spaces (the tool refuses spaces in paths it sends to prod)
# fake psql (same idea as test_export.sh)
cat > "$WORK/bin/psql" <<'STUB'
#!/usr/bin/env bash
sql="${@: -1}"
case "$sql" in
  "select 1") echo 1 ;;
  *information_schema.columns*) echo 1 ;;
  *information_schema.tables*)  echo 1 ;;
  *"select count(*) from"*)     echo 6 ;;
  COPY*)
    if [ -n "${STUB_FAIL_ON:-}" ] && [[ "$sql" == *"$STUB_FAIL_ON"* ]]; then echo "ERROR: boom" >&2; exit 3; fi
    echo "PERIOD_START_TIME,SITE_ID,K_1"; echo "2026-10-25 00:00:00,1,1.5"; echo "2026-10-25 00:15:00,2,2.5" ;;
  *) echo "stub psql: unknown query: $sql" >&2; exit 9 ;;
esac
STUB
chmod +x "$WORK/bin/psql"
PY="$(command -v python3 2>/dev/null || true)"; "$PY" -c 1 >/dev/null 2>&1 || PY="$(command -v python 2>/dev/null || true)"
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$PY" > "$WORK/bin/python3"; chmod +x "$WORK/bin/python3"
export PATH="$WORK/bin:$PATH"

# fake db-import: records its arguments and the zip its config points to; fails when told to
cat > "$WORK/dbi/db-import.sh" <<'STUB'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$DBI_LOG"
cfg="${@: -1}"
# shellcheck disable=SC1090
( . "$cfg"; echo "SOURCE: $SOURCE_TYPE TARGET: $TARGET_TYPE"; echo "ZIP: $SOURCE_CSV_PATH"; [ -f "$SOURCE_CSV_PATH" ] && echo "ZIP EXISTS" || echo "ZIP MISSING" ) >> "$DBI_LOG"
case " $* " in *" --check "*) [ -n "${DBI_FAIL_CHECK:-}" ] && exit 2 ;; esac
[ -n "${DBI_FAIL:-}" ] && { echo "db-import: failed"; exit 1; }
echo "db-import ok"; exit 0
STUB
cat > "$WORK/pc/run.sh" <<'STUB'
#!/usr/bin/env bash
echo "COMPARE ARGS: $*" >> "$DBI_LOG"
exit "${PC_RC:-0}"
STUB
export DBI_LOG="$WORK/dbi.log"
: > "$WORK/pc.env"
cat > "$WORK/dbi.env" <<EOF
SOURCE_TYPE="csv"
SOURCE_CSV_PATH="/will/be/replaced.zip"
TARGET_TYPE="ducklake"
TARGET_PASSWORD_ENV="TEST_TARGET_PW"
EOF
cat > "$WORK/export.env" <<EOF
PGHOST="prodhost"
PGUSER="reader"
PGDATABASE="gsb"
PG_PASSWORD_ENV="TEST_PW"
MIN_FREE_MB="1"
EOF
export TEST_PW='x' TEST_TARGET_PW='y'

mkcfg() {   # $1 file, extra lines after
  local f="$1"; shift
  cat > "$f" <<EOF
JOB_NAME="chain"
REMOTE_MODE="local"
PROD_EXPORT_SCRIPT="$WORK/export-on-prod.sh"
PROD_EXPORT_CONFIG="$WORK/export.env"
PROD_OUT_ROOT="$WORK/prod_out"
TABLES="KPI_A_P,KPI_B_P"
PERIOD_FROM="2026-10-25"
PERIOD_TO="2026-10-25 02:00"
LOCAL_ZIP_DIR="$WORK/uat_zips"
DB_IMPORT_DIR="$WORK/dbi"
DB_IMPORT_CONFIG="$WORK/dbi.env"
COMPARE="yes"
PIVOT_COMPARE_DIR="$WORK/pc"
PIVOT_COMPARE_CONFIG="$WORK/pc.env"
REPORT_DIR="$WORK/reports"
MIN_FREE_MB="1"
EOF
  for l in "$@"; do echo "$l" >> "$f"; done
}
run() { bash "$RUNALL" "$@" 2>&1; echo "rc=$?"; }
rc()  { sed -n 's/^rc=//p' <<<"$1" | tail -1; }

# ---- 1. setup errors ---------------------------------------------------------------------------------------------
mkcfg "$WORK/a.env"
o="$(run "$WORK/nope.env")";                                   check "missing config" "$(rc "$o")" 2
o="$(run)";                                                    check "no config" "$(rc "$o")" 2
mkcfg "$WORK/b.env" 'REMOTE_MODE="telnet"';                    o="$(run --check "$WORK/b.env")"; check "bad remote mode" "$(rc "$o")" 2
mkcfg "$WORK/c.env" 'TABLES=""';                               o="$(run --check "$WORK/c.env")"; check "no tables" "$(rc "$o")" 2; has "no tables msg" "$o" "TABLES is not set"
mkcfg "$WORK/d.env" 'STEPS="export,fly"';                      o="$(run --check "$WORK/d.env")"; check "bad step" "$(rc "$o")" 2; has "bad step msg" "$o" "unknown step 'fly'"
mkcfg "$WORK/e.env" 'PROD_OUT_ROOT="/x;rm -rf /"';             o="$(run --check "$WORK/e.env")"; check "bad path" "$(rc "$o")" 2
mkcfg "$WORK/f.env" 'REMOTE_MODE="ssh"';                       o="$(run --check "$WORK/f.env")"; check "ssh without host" "$(rc "$o")" 2; has "host msg" "$o" "PROD_SSH_HOST is not set"
printf 'SOURCE_TYPE="postgres"\n' > "$WORK/dbi_pg.env"
mkcfg "$WORK/g.env" "DB_IMPORT_CONFIG=\"$WORK/dbi_pg.env\"";   o="$(run --check "$WORK/g.env")"; check "db-import config not csv" "$(rc "$o")" 2; has "csv msg" "$o" 'must set SOURCE_TYPE="csv"'
o="$(run --check "$WORK/a.env" --resume)";                     check "--resume without --name" "$(rc "$o")" 2

# ---- 2. --check ----------------------------------------------------------------------------------------------------------
: > "$DBI_LOG"
o="$(run --check "$WORK/a.env" --name chk1)"
check "check rc" "$(rc "$o")" 0
has "check: login" "$o" "can log in to prod"
has "check: export script found" "$o" "the export script exists on prod"
has "check: export's own check ran" "$o" "the export script's own check on prod"
has "check: export check says fine" "$o" "everything is fine. Nothing was written."
has "check: target password var" "$o" "target password variable: TEST_TARGET_PW"
check "check wrote no zip on prod" "$(ls "$WORK/prod_out" 2>/dev/null | grep -c zip)" 0
check "check did not call db-import" "$(cat "$DBI_LOG" | wc -l)" 0
o="$(TEST_TARGET_PW= run --check "$WORK/a.env")";              check "check: empty target password" "$(rc "$o")" 2; has "empty pw msg" "$o" "TEST_TARGET_PW"

# ---- 3. the whole chain -----------------------------------------------------------------------------------------------------
: > "$DBI_LOG"
o="$(run --yes "$WORK/a.env" --name run1)"
check "chain rc" "$(rc "$o")" 0
has "export step ok" "$o" "OK     step export finished"
has "copy step ok" "$o" "OK     step copy finished"
has "load step ok" "$o" "OK     step load finished"
has "compare step ok" "$o" "OK     step compare finished"
has "checksum matches" "$o" "matches"
check "verified source zip removed" "$([ -s "$WORK/prod_out/run1.zip" ] && echo yes || echo no)" no
check "zip on UAT" "$([ -s "$WORK/uat_zips/run1.zip" ] && echo yes || echo no)" yes
check "the two zips are identical" "$(cut -d" " -f1 "$WORK/prod_out/run1.zip.sha256")" "$(sha256sum < "$WORK/uat_zips/run1.zip" | cut -d" " -f1)"
L="$(cat "$DBI_LOG")"
has "db-import was checked first" "$L" "ARGS: --check "
has "db-import then ran for real with --yes" "$L" "ARGS: --yes "
hasnt "db-import real run has no --dry-run" "$L" "--dry-run"
has "db-import got this run's zip" "$L" "ZIP: $WORK/uat_zips/run1.zip"
has "that zip existed when db-import ran" "$L" "ZIP EXISTS"
has "compare got its config" "$L" "COMPARE ARGS: $WORK/pc.env"
R="$(ls -d "$WORK/reports"/*_chain | tail -1)"
check "report: summary file" "$([ -s "$R/summary.txt" ] && echo yes || echo no)" yes
has "summary: rows" "$(cat "$R/summary.txt")" "rows exported: 8"
has "summary: steps" "$(cat "$R/summary.txt")" "export    OK"
check "the user's db-import config was not edited" "$(grep -c 'will/be/replaced' "$WORK/dbi.env")" 1
has "the run's copy of the config points at the zip" "$(cat "$R/db-import.env")" "SOURCE_CSV_PATH=\"$WORK/uat_zips/run1.zip\""

# ---- 4. a failing step stops the chain ---------------------------------------------------------------------------------------
: > "$DBI_LOG"
o="$(STUB_FAIL_ON=">= TIMESTAMP '2026-10-25 01:00:00'" run --yes "$WORK/a.env" --name fail1)"
check "export fails: rc" "$(rc "$o")" 1
has "export failed" "$o" "FAILED step export"
hasnt "copy did not run" "$o" "===== step: copy"
check "nothing was copied to UAT" "$([ -e "$WORK/uat_zips/fail1.zip" ] && echo yes || echo no)" no
check "db-import was not called" "$(wc -l < "$DBI_LOG" | tr -d ' ')" 0
has "tells how to resume" "$o" "--name fail1 --steps export --resume"
# resume: finished chunks kept, the zip gets made
o="$(run --yes "$WORK/a.env" --name fail1 --steps export --resume)"
check "resume rc" "$(rc "$o")" 0
has "resume skipped finished chunks" "$o" "SKIP   "

: > "$DBI_LOG"
o="$(DBI_FAIL=1 run --yes "$WORK/a.env" --name fail2)"
check "load fails: rc" "$(rc "$o")" 1
has "load failed" "$o" "FAILED step load"
hasnt "compare did not run" "$o" "===== step: compare"
has "tells how to re-run the load" "$o" "--name fail2 --steps load"
: > "$DBI_LOG"
o="$(DBI_FAIL_CHECK=1 run --yes "$WORK/a.env" --name fail3)"
check "db-import --check fails: rc" "$(rc "$o")" 1
has "nothing loaded after a failed check" "$o" "nothing was loaded"
check "the real db-import run did not start" "$(grep -c '^ARGS: --yes' "$DBI_LOG")" 0

# ---- 5. re-running one step ----------------------------------------------------------------------------------------------------------
: > "$DBI_LOG"
o="$(run --yes "$WORK/a.env" --name run1 --steps load)"
check "load only: rc" "$(rc "$o")" 0
hasnt "load only: no export" "$o" "===== step: export"
has "load only: used the zip already on UAT" "$(cat "$DBI_LOG")" "ZIP: $WORK/uat_zips/run1.zip"
o="$(run --yes "$WORK/a.env" --name run1 --steps copy)"
check "copy again: refused, nothing overwritten" "$(rc "$o")" 1; has "copy again msg" "$o" "already exists"
o="$(run --yes "$WORK/a.env" --name nosuch --steps load)";  check "load without a zip" "$(rc "$o")" 1; has "no zip msg" "$o" "does not exist"

# ---- 6. dry run and the compare answers --------------------------------------------------------------------------------------------------
: > "$DBI_LOG"
o="$(run --yes --dry-run "$WORK/a.env" --name dry1)"
check "dry run rc" "$(rc "$o")" 0
has "dry run: db-import --dry-run" "$(cat "$DBI_LOG")" "ARGS: --dry-run --yes"
check "dry run retains prod zip" "$([ -s "$WORK/prod_out/dry1.zip" ] && echo yes)" yes
hasnt "dry run: no compare" "$o" "===== step: compare"
o="$(PC_RC=1 run --yes "$WORK/a.env" --name cmp1)";          check "compare DIFFERENT -> exit 3" "$(rc "$o")" 3; has "different msg" "$o" "comparison says DIFFERENT"
o="$(PC_RC=3 run --yes "$WORK/a.env" --name cmp2)";          check "compare NOT COMPARABLE -> exit 4" "$(rc "$o")" 4
o="$(PC_RC=2 run --yes "$WORK/a.env" --name cmp3)";          check "compare bad setup -> exit 1" "$(rc "$o")" 1; has "compare failed msg" "$o" "FAILED step compare"
mkcfg "$WORK/h.env" 'COMPARE="no"'
o="$(run --yes "$WORK/h.env" --name cmp4)";                  check "COMPARE=no" "$(rc "$o")" 0; hasnt "COMPARE=no: no compare step" "$o" "===== step: compare"

# ---- 7. a damaged copy is detected and removed ------------------------------------------------------------------------------------------------
o="$(run --yes "$WORK/a.env" --name dmg1 --steps export)"
echo "tampered" >> "$WORK/prod_out/dmg1.zip"                # the zip on prod no longer matches its .sha256
o="$(run --yes "$WORK/a.env" --name dmg1 --steps copy)"
check "damaged copy: rc" "$(rc "$o")" 1
check "bad checksum retains prod zip" "$([ -s "$WORK/prod_out/dmg1.zip" ] && echo yes)" yes
has "damaged copy msg" "$o" "the copy is damaged"
check "damaged copy removed" "$(ls "$WORK/uat_zips" | grep -c 'dmg1')" 0

# ---- 8. source-specific export lists: wrapper argument contract and unchanged CSV load ---------------------
# Recording exporter isolates wrapper forwarding from the source exporters' database clients.
cat > "$WORK/record-export.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' BEGIN "$@" END >> "$EXPORT_LOG"
out=''; name=''; checking=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out-root) out="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --check) checking=1; shift ;;
    *) shift ;;
  esac
done
[ "$checking" -eq 0 ] || exit 0
mkdir -p "$out"
python3 - "$out/$name.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('KPI_A_P_202610250000.csv', 'PERIOD_START_TIME,SITE_ID,K_1\n2026-10-25 00:00:00,1,1.5\n')
PY
sha="$(sha256sum "$out/$name.zip" | cut -d' ' -f1)"
printf '%s  %s\n' "$sha" "$name.zip" > "$out/$name.zip.sha256"
printf 'RESULT_SHA256=%s\nRESULT_ROWS=1\n' "$sha"
STUB
export EXPORT_LOG="$WORK/export.log"
for mode in postgres ducklake mixed; do
  pg=''; dl=''
  [ "$mode" = ducklake ] || pg='pg_schema.KPI_A_P,other.KPI_B_P'
  [ "$mode" = postgres ] || dl='lake_schema.KPI_C_P'
  mkcfg "$WORK/typed.env" 'TABLES=""' "POSTGRES_TABLES=\"$pg\"" "DUCKLAKE_TABLES=\"$dl\"" "PROD_EXPORT_SCRIPT=\"$WORK/record-export.sh\""
  : > "$EXPORT_LOG"; : > "$DBI_LOG"
  o="$(run --check "$WORK/typed.env" --name "typed_$mode")"
  check "$mode check rc" "$(rc "$o")" 0
  E="$(cat "$EXPORT_LOG")"
  if [ -n "$pg" ]; then has "$mode check postgres forwarding" "$E" $'--postgres-tables\n'"$pg"; fi
  if [ -n "$dl" ]; then has "$mode check lake forwarding" "$E" $'--ducklake-tables\n'"$dl"; fi
  : > "$EXPORT_LOG"
  o="$(run --yes "$WORK/typed.env" --name "typed_$mode")"
  check "$mode chain rc" "$(rc "$o")" 0
  E="$(cat "$EXPORT_LOG")"
  hasnt "$mode no legacy flag" "$E" '--tables'
  if [ -n "$pg" ]; then has "$mode postgres flag" "$E" $'--postgres-tables\n'"$pg"; else hasnt "$mode no postgres flag" "$E" '--postgres-tables'; fi
  if [ -n "$dl" ]; then has "$mode ducklake flag" "$E" $'--ducklake-tables\n'"$dl"; else hasnt "$mode no ducklake flag" "$E" '--ducklake-tables'; fi
  has "$mode downstream CSV source and target untouched" "$(cat "$DBI_LOG")" "SOURCE: csv TARGET: ducklake"
  has "$mode downstream still CSV zip" "$(cat "$DBI_LOG")" "ZIP: $WORK/uat_zips/typed_$mode.zip"
  hasnt "$mode downstream no source flags" "$(cat "$DBI_LOG")" '--postgres-tables'
  hasnt "$mode downstream no lake flags" "$(cat "$DBI_LOG")" '--ducklake-tables'
done

# All invalid selections fail locally, before contacting the exporter (including --check).
for extra in \
  'POSTGRES_TABLES="s.A"' \
  'DUCKLAKE_TABLES="s.A"' \
  'TABLES=""; POSTGRES_TABLES="A"' \
  'TABLES=""; DUCKLAKE_TABLES="catalog.s.A"' \
  'TABLES=""; POSTGRES_TABLES="s.A,"' \
  'TABLES=""; POSTGRES_TABLES=",s.A"' \
  'TABLES=""; DUCKLAKE_TABLES="s.A,,s.B"' \
  'TABLES=""; POSTGRES_TABLES="s.A;touch_bad"' \
  'TABLES=""; POSTGRES_TABLES="s.A,other.a"' \
  'TABLES=""; DUCKLAKE_TABLES="s.A,other.a"' \
  'TABLES=""; POSTGRES_TABLES="s.A"; DUCKLAKE_TABLES="other.a"' \
  'TABLES="A,a"'; do
  mkcfg "$WORK/invalid.env" "PROD_EXPORT_SCRIPT=\"$WORK/record-export.sh\"" "$extra"
  : > "$EXPORT_LOG"
  o="$(run --check "$WORK/invalid.env")"
  check "invalid selection $extra" "$(rc "$o")" 2
  check "invalid selection never contacts exporter $extra" "$(wc -c < "$EXPORT_LOG" | tr -d ' ')" 0
done

echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
