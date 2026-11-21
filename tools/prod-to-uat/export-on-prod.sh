#!/usr/bin/env bash
# export-on-prod.sh - runs ON THE PROD SERVER (started by run-all.sh over SSH, or by hand).
# Exports Postgres and DuckLake tables into ONE zip that db-import (SOURCE_TYPE="csv") loads.
# Read only on the database. Writes only under OUT_ROOT.
#
#   ./export-on-prod.sh --config export.env                    export, as set in the config
#   ./export-on-prod.sh --config export.env --check            read only: connection, tables, columns, disk, zip tool
#   options that override the config:  --tables A,B   --from "2026-10-25"   --to "2026-10-25 03:15"   --name nstd_20261118   --out-root /path
#   --resume   continue an earlier run of the same --name (finished chunks are kept)
#   --postgres-tables schema.table,... --ducklake-tables schema.table,...
#   Explicit lists replace legacy TABLES/--tables. DUCKLAKE_INIT is trusted, secret-bearing
#   operator SQL: LOAD preinstalled extensions and ATTACH DuckLake AS gsb (READ_ONLY).
#
# Result (last lines on screen, read by run-all.sh):  RESULT_ZIP=<path>  RESULT_SHA256=<hash>  RESULT_ROWS=<total rows>
# Exit code: 0 = zip written; 1 = failed (no zip is made); 2 = bad setup/config.
set -euo pipefail

log()  { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
warn() { log "WARN  $*" >&2; }
die()  { log "ERROR $*" >&2; exit 2; }

CONFIG=""; CHECK=0
O_TABLES=""; O_FROM=""; O_TO=""; O_NAME=""; O_OUT=""; O_RESUME=""
O_POSTGRES=""; O_DUCKLAKE=""; EXPLICIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config)   CONFIG="${2:-}"; shift 2 ;;
    --check)    CHECK=1; shift ;;
    --tables)   O_TABLES="${2:-}"; shift 2 ;;
    --postgres-tables) [ $# -ge 2 ] || die "--postgres-tables requires schema.table list"; O_POSTGRES="$2"; EXPLICIT=1; shift 2 ;;
    --ducklake-tables) [ $# -ge 2 ] || die "--ducklake-tables requires schema.table list"; O_DUCKLAKE="$2"; EXPLICIT=1; shift 2 ;;
    --from)     O_FROM="${2:-}"; shift 2 ;;
    --to)       O_TO="${2:-}"; shift 2 ;;
    --name)     O_NAME="${2:-}"; shift 2 ;;
    --out-root) O_OUT="${2:-}"; shift 2 ;;
    --resume)   O_RESUME="yes"; shift ;;
    -h|--help)  sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
[ -n "$CONFIG" ] || die "--config <file> is required"
[ -f "$CONFIG" ] || die "config file not found: $CONFIG"
# shellcheck disable=SC1090
. "$CONFIG"

# ---- defaults (the config may set any of these) ----------------------------------------------------
PGHOST="${PGHOST:-}"; PGPORT="${PGPORT:-5432}"; PGUSER="${PGUSER:-}"; PGDATABASE="${PGDATABASE:-}"
PG_PASSWORD_ENV="${PG_PASSWORD_ENV:-}"
SCHEMA="${SCHEMA:-gsb_data_kpi_pivot}"
TABLES="${O_TABLES:-${TABLES:-}}"
TS_COL="${TS_COL:-PERIOD_START_TIME}"
TABLE_TIME_COLUMNS="${TABLE_TIME_COLUMNS:-}"          # TABLE:COLUMN,TABLE:COLUMN for a table with another time column
PERIOD_FROM="${O_FROM:-${PERIOD_FROM:-}}"
PERIOD_TO="${O_TO:-${PERIOD_TO:-}}"
STEP_HOURS="${STEP_HOURS:-1}"
TZ_MODE="${TZ_MODE:-LITERAL}"                         # LITERAL | SYD_LOCAL_ON_UTC_TS | SYD_LOCAL_ON_TZ_COL
OUT_ROOT="${O_OUT:-${OUT_ROOT:-}}"
ZIP_NAME="${O_NAME:-${ZIP_NAME:-export_$(date +%Y%m%d_%H%M%S)}}"
SKIP_EMPTY="${SKIP_EMPTY:-no}"                        # no = an hour without rows still gets a header-only file (no gap for db-import)
RESUME="${O_RESUME:-${RESUME:-no}}"                    # yes = keep chunks of an earlier run of the same name and do the rest
PSQL_BIN="${PSQL_BIN:-psql}"
MIN_FREE_MB="${MIN_FREE_MB:-1024}"
POSTGRES_TABLES="${POSTGRES_TABLES:-}"; DUCKLAKE_TABLES="${DUCKLAKE_TABLES:-}"
DUCKDB_BIN="${DUCKDB_BIN:-duckdb}"; DUCKLAKE_INIT="${DUCKLAKE_INIT:-}"
if [ "$EXPLICIT" -eq 1 ]; then
  [ -z "$O_TABLES" ] || die "--tables cannot be combined with explicit source lists"
  POSTGRES_TABLES="$O_POSTGRES"; DUCKLAKE_TABLES="$O_DUCKLAKE"; TABLES=""
elif [ -n "$O_TABLES" ]; then
  POSTGRES_TABLES=""; DUCKLAKE_TABLES=""
elif [ -n "$POSTGRES_TABLES$DUCKLAKE_TABLES" ]; then
  TABLES=""
fi

# ---- checks: letters, digits and a few signs only; nothing else ever reaches the SQL ---------------
ident_ok() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }
norm_ts() {   # "2026-10-25" | "2026-10-25 03:15" | "2026-10-25 03:15:00" -> "2026-10-25 03:15:00"
  local v="${1//T/ }"
  if   [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then echo "$v 00:00:00"
  elif [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]; then echo "$v:00"
  elif [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then echo "$v"
  else return 1; fi
}


[[ "$PGPORT" =~ ^[0-9]+$ ]] || die "PGPORT must be a number"
ident_ok "$SCHEMA" || die "SCHEMA must be letters, digits, _ or - only (got '$SCHEMA')"
ident_ok "$TS_COL" || die "TS_COL must be letters, digits, _ or - only (got '$TS_COL')"
[[ "$STEP_HOURS" =~ ^[0-9]+$ && "$STEP_HOURS" -ge 1 ]] || die "STEP_HOURS must be a whole number, 1 or more"
case "$TZ_MODE" in LITERAL|SYD_LOCAL_ON_UTC_TS|SYD_LOCAL_ON_TZ_COL) ;; *) die "TZ_MODE must be LITERAL, SYD_LOCAL_ON_UTC_TS or SYD_LOCAL_ON_TZ_COL" ;; esac
case "$SKIP_EMPTY" in yes|no) ;; *) die "SKIP_EMPTY must be yes or no" ;; esac
case "$RESUME" in yes|no) ;; *) die "RESUME must be yes or no" ;; esac
[[ "$MIN_FREE_MB" =~ ^[0-9]+$ ]] || die "MIN_FREE_MB must be a whole number"
[ -n "$TABLES$POSTGRES_TABLES$DUCKLAKE_TABLES" ] || die "TABLES or explicit source lists must be set"
[ -n "$PERIOD_FROM" ] && [ -n "$PERIOD_TO" ] || die "PERIOD_FROM and PERIOD_TO are required"
FROM_TS="$(norm_ts "$PERIOD_FROM")" || die "PERIOD_FROM must look like 2026-10-25 or 2026-10-25 03:15 (got '$PERIOD_FROM')"
TO_TS="$(norm_ts "$PERIOD_TO")"     || die "PERIOD_TO must look like 2026-10-25 or 2026-10-25 03:15 (got '$PERIOD_TO')"
[ "$FROM_TS" \< "$TO_TS" ] || die "PERIOD_FROM must be earlier than PERIOD_TO ($FROM_TS, $TO_TS)"
[ -n "$OUT_ROOT" ] || die "OUT_ROOT is not set (the folder where the zip is written)"
[[ "$OUT_ROOT" =~ ^[A-Za-z0-9_./:-]+$ ]] || die "OUT_ROOT must use letters, digits and _ . / : - only"
[[ "$ZIP_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || die "ZIP_NAME must use letters, digits and _ . - only (got '$ZIP_NAME')"
[[ "$PSQL_BIN" =~ ^[A-Za-z0-9_./:-]+$ ]] || die "PSQL_BIN must be a plain path"

# tables: comma/space/newline separated list -> array
declare -a TBL=()
declare -A SOURCE=() SRC_SCHEMA=() SEEN=()
HAS_PG=0; HAS_DUCK=0
add_tables() {
  local backend="$1" list="$2" qualified="$3" entry s t
  while IFS= read -r entry; do
    entry="${entry//[$' \t\r']/}"; [ -z "$entry" ] && continue
    if [ "$qualified" = yes ]; then
      [[ "$entry" == *.* && "${entry#*.}" != *.* ]] || die "source name must be schema.table: $entry"
      s="${entry%%.*}"; t="${entry#*.}"
    else s="$SCHEMA"; t="$entry"; fi
    ident_ok "$s" && ident_ok "$t" || die "table name '$entry' must be letters, digits, _ or - only"
    [ -z "${SEEN[${t,,}]:-}" ] || die "duplicate output basename: $t"
    SEEN["${t,,}"]=1; TBL+=("$t"); SOURCE["$t"]="$backend"; SRC_SCHEMA["$t"]="$s"
    if [ "$backend" = postgres ]; then HAS_PG=1; else HAS_DUCK=1; fi
  done < <(printf '%s\n' "$list" | tr ',' '\n')
}
add_tables postgres "$TABLES" no
add_tables postgres "$POSTGRES_TABLES" yes
add_tables ducklake "$DUCKLAKE_TABLES" yes
[ "${#TBL[@]}" -gt 0 ] || die "source lists hold no table name"
if [ "$HAS_PG" -eq 1 ]; then
  [ -n "$PGHOST" ] || die "PGHOST is not set"
  [ -n "$PGUSER" ] || die "PGUSER is not set"
  [ -n "$PGDATABASE" ] || die "PGDATABASE is not set"
fi

declare -A TCOL=()
if [ -n "$TABLE_TIME_COLUMNS" ]; then
  while IFS= read -r pair; do
    pair="${pair//[$' \t\r']/}"; [ -z "$pair" ] && continue
    [[ "$pair" == *:* ]] || die "TABLE_TIME_COLUMNS entry '$pair' must be TABLE:COLUMN"
    ident_ok "${pair%%:*}" && ident_ok "${pair#*:}" || die "TABLE_TIME_COLUMNS entry '$pair' has a bad name"
    TCOL["${pair%%:*}"]="${pair#*:}"
  done < <(printf '%s\n' "$TABLE_TIME_COLUMNS" | tr ',' '\n')
fi
tcol() { echo "${TCOL[$1]:-$TS_COL}"; }

# ---- password: from the environment variable NAMED in the config, or ~/.pgpass; never from this file ----
unset PGPASSWORD || true
if [ "$HAS_PG" -eq 1 ] && [ -n "$PG_PASSWORD_ENV" ]; then
  [[ "$PG_PASSWORD_ENV" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "PG_PASSWORD_ENV must be the NAME of an environment variable"
  [ -n "${!PG_PASSWORD_ENV:-}" ] || die "environment variable $PG_PASSWORD_ENV is empty: export it first (read -rs $PG_PASSWORD_ENV; export $PG_PASSWORD_ENV)"
  export PGPASSWORD="${!PG_PASSWORD_ENV}"
fi
export PGHOST PGPORT PGUSER PGDATABASE

# ---- tools -----------------------------------------------------------------------------------------
if [ "$HAS_PG" -eq 1 ]; then
if ! command -v "$PSQL_BIN" >/dev/null 2>&1; then
  for p in /usr/pgsql-*/bin/psql /usr/bin/psql; do [ -x "$p" ] && { PSQL_BIN="$p"; break; }; done
fi
command -v "$PSQL_BIN" >/dev/null 2>&1 || die "psql not found (set PSQL_BIN)"
fi
if [ "$HAS_DUCK" -eq 1 ]; then
  command -v "$DUCKDB_BIN" >/dev/null 2>&1 || die "duckdb not found (set DUCKDB_BIN; extensions must be preinstalled)"
  [ -n "$DUCKLAKE_INIT" ] && [ -f "$DUCKLAKE_INIT" ] && [ -r "$DUCKLAKE_INIT" ] || die "DUCKLAKE_INIT must name a readable operator-provided SQL file"
fi
command -v gzip >/dev/null 2>&1 || die "gzip not found"
ZIP_TOOL=""
if command -v zip >/dev/null 2>&1; then ZIP_TOOL="zip"
elif command -v python3 >/dev/null 2>&1; then ZIP_TOOL="python3"
fi
command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found"
psql_q() { "$PSQL_BIN" -v ON_ERROR_STOP=1 -q -X -A -t -c "$1"; }
duck_q() {
  # Do not print stderr: init may contain credentials. No auto-install/autoload.
  # Repeat the runtime guard in EVERY fresh CLI process, before any source query.
  { printf '%s\n' '.output /dev/null' 'SET autoinstall_known_extensions=false; SET autoload_known_extensions=false;'
    cat -- "$DUCKLAKE_INIT"
    printf '\n%s\n' "SELECT CASE WHEN count(*) = 1 THEN 1 ELSE error('gsb must be a read-only DuckLake attachment') END FROM duckdb_databases() WHERE database_name='gsb' AND readonly AND type='ducklake';"
    printf '%s\n' '.output /dev/stdout' "$1"
  } | "$DUCKDB_BIN" -init /dev/null -batch -bail -noheader -csv :memory: 2>/dev/null
}
source_q() {
  local t="$1"; shift
  if [ "${SOURCE[$t]}" = postgres ]; then psql_q "$1"; else duck_q "$1"; fi
}
relation() {
  local t="$1"
  [ "${SOURCE[$t]}" != ducklake ] || printf '"gsb".'
  printf '"%s"."%s"' "${SRC_SCHEMA[$t]}" "$t"
}
if [ "$HAS_DUCK" -eq 1 ]; then
  [ "$(duck_q 'SELECT 1;')" = 1 ] || die "DuckLake validation failed: gsb must be a read-only DuckLake attachment (check DUCKLAKE_INIT privately)"
fi

# ---- chunk list: wall-clock text stepped in UTC arithmetic (no daylight-saving shift) ----------------
to_epoch()   { TZ=UTC date -d "$1 UTC" +%s; }
from_epoch() { TZ=UTC date -d "@$1" "+%F %T"; }
make_ranges() {
  local s e step t t2
  s=$(to_epoch "$1"); e=$(to_epoch "$2"); step=$(( $3 * 3600 )); t=$s
  while (( t < e )); do
    t2=$(( t + step )); (( t2 > e )) && t2=$e
    printf '%s\t%s\n' "$(from_epoch "$t")" "$(from_epoch "$t2")"
    t=$t2
  done
}
where_for() {   # $1 column, $2 from, $3 to
  case "$TZ_MODE" in
    LITERAL)             echo "\"$1\" >= TIMESTAMP '$2' AND \"$1\" < TIMESTAMP '$3'" ;;
    SYD_LOCAL_ON_UTC_TS) echo "\"$1\" >= (TIMESTAMP '$2' AT TIME ZONE 'Australia/Sydney')::timestamp AND \"$1\" < (TIMESTAMP '$3' AT TIME ZONE 'Australia/Sydney')::timestamp" ;;
    SYD_LOCAL_ON_TZ_COL) echo "(\"$1\" AT TIME ZONE 'Australia/Sydney') >= TIMESTAMP '$2' AND (\"$1\" AT TIME ZONE 'Australia/Sydney') < TIMESTAMP '$3'" ;;
  esac
}
label_ts() { echo "${1//[: ]/_}"; }

OUT_DIR="$OUT_ROOT/$ZIP_NAME"
ZIP_FILE="$OUT_ROOT/$ZIP_NAME.zip"
# Persist a digest, never credentials. Bind retained chunks to source and ranges.
IDENTITY="$({
  printf '%s\n' "$FROM_TS" "$TO_TS" "$STEP_HOURS" "$TZ_MODE" "$SKIP_EMPTY" "$TS_COL" "$TABLE_TIME_COLUMNS"
  for t in "${TBL[@]}"; do printf '%s\n' "${SOURCE[$t]}:${SRC_SCHEMA[$t]}:$t:$(tcol "$t")"; done
  if [ "$HAS_PG" -eq 1 ]; then printf '%s\n' "$PGHOST" "$PGPORT" "$PGDATABASE" "$PGUSER" "${PGSERVICE:-}" "${PGOPTIONS:-}" "${PGSSLMODE:-}"; fi
  if [ "$HAS_DUCK" -eq 1 ]; then printf '%s\n' "$DUCKDB_BIN" "$DUCKLAKE_INIT"; sha256sum < "$DUCKLAKE_INIT"; fi
} | sha256sum | cut -d' ' -f1)"
IDENTITY_FILE="$OUT_DIR/.export-identity.sha256"
if [ -d "$OUT_DIR" ] && [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ] && [ "$RESUME" = yes ]; then
  [ -f "$IDENTITY_FILE" ] && [ "$(cat "$IDENTITY_FILE")" = "$IDENTITY" ] || die "resume source identity mismatch or missing; use a new --name"
fi

# ---- --check: read only ----------------------------------------------------------------------------
do_check() {
  local bad=0 t c n
  log "CHECK  host=$PGHOST port=$PGPORT db=$PGDATABASE user=$PGUSER schema=$SCHEMA"
  log "CHECK  period $FROM_TS  <=  time column  <  $TO_TS   (step ${STEP_HOURS}h, tz_mode $TZ_MODE)"
  log "CHECK  chunks per table: $(make_ranges "$FROM_TS" "$TO_TS" "$STEP_HOURS" | wc -l)"
  if { [ "$HAS_PG" -eq 0 ] || psql_q "select 1" >/dev/null 2>&1; }; then log "OK     connected to the database"
  else log "ERROR  cannot connect (host, port, user, database, password variable?)"; return 2; fi
  for t in "${TBL[@]}"; do
    local s="${SRC_SCHEMA[$t]}" catalog=""
    [ "${SOURCE[$t]}" != ducklake ] || catalog="table_catalog='gsb' and "
    c="$(tcol "$t")"
    n="$(source_q "$t" "select count(*) from information_schema.columns where ${catalog}table_schema='$s' and table_name='$t' and column_name='$c';" 2>/dev/null || echo x)"
    if [ "$n" != "1" ]; then
      if [ "$(source_q "$t" "select count(*) from information_schema.tables where ${catalog}table_schema='$s' and table_name='$t';" 2>/dev/null || echo 0)" != "1" ]; then
        log "ERROR  $s.$t: table not found (or no right to see it)"
      else
        log "ERROR  $s.$t: time column '$c' not found"
      fi
      bad=1; continue
    fi
    n="$(source_q "$t" "select count(*) from $(relation "$t") where $(where_for "$c" "$FROM_TS" "$TO_TS");" 2>&1)" || { log "ERROR  $s.$t: cannot read: $n"; bad=1; continue; }
    log "OK     $s.$t: time column $c, $n row(s) in the period"
  done
  mkdir -p "$OUT_ROOT" 2>/dev/null || true
  if [ -d "$OUT_ROOT" ] && [ -w "$OUT_ROOT" ]; then
    local free; free="$(df -Pm "$OUT_ROOT" | awk 'NR==2{print $4}')"
    if [ "${free:-0}" -lt "$MIN_FREE_MB" ]; then log "ERROR  OUT_ROOT $OUT_ROOT has only ${free} MB free (MIN_FREE_MB=$MIN_FREE_MB)"; bad=1
    else log "OK     OUT_ROOT $OUT_ROOT is writable, ${free} MB free"; fi
  else log "ERROR  OUT_ROOT $OUT_ROOT does not exist or is not writable"; bad=1; fi
  if [ -z "$ZIP_TOOL" ]; then log "ERROR  neither zip nor python3 found: cannot make the zip"; bad=1
  else log "OK     zip made with: $ZIP_TOOL"; fi
  if [ -e "$ZIP_FILE" ]; then log "ERROR  $ZIP_FILE already exists (choose another --name; nothing is overwritten)"; bad=1; fi
  if [ -d "$OUT_DIR" ] && [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ] && [ "$RESUME" != yes ]; then
    log "ERROR  $OUT_DIR already holds files (choose another --name, or RESUME=yes to continue it)"; bad=1
  fi
  [ "$bad" -eq 0 ] && { log "CHECK  everything is fine. Nothing was written."; return 0; }
  log "CHECK  problems found (see ERROR above). Nothing was written."; return 2
}
if [ "$CHECK" -eq 1 ]; then do_check; exit $?; fi

# ---- export ------------------------------------------------------------------------------------------
[ -n "$ZIP_TOOL" ] || die "neither zip nor python3 found: cannot make the zip"
[ ! -e "$ZIP_FILE" ] || die "$ZIP_FILE already exists: choose another --name (nothing is overwritten)"
mkdir -p "$OUT_DIR"
if [ "$RESUME" != yes ] && [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
  die "$OUT_DIR already holds files: choose another --name, or set RESUME=yes to continue that run"
fi
printf '%s\n' "$IDENTITY" > "$IDENTITY_FILE"
rm -f "$OUT_DIR/___All_Errors.txt"   # left by an earlier failed attempt of this name; a new failure writes it again
free="$(df -Pm "$OUT_ROOT" | awk 'NR==2{print $4}')"
[ "${free:-0}" -ge "$MIN_FREE_MB" ] || die "OUT_ROOT has only ${free} MB free (MIN_FREE_MB=$MIN_FREE_MB)"

CURRENT_TMP=""
on_signal() { log "INTERRUPTED: removing the partial file"; [ -n "$CURRENT_TMP" ] && rm -f "$CURRENT_TMP"; exit 1; }
trap 'on_signal' INT TERM

count_rows() { gzip -dc "$1" | awk 'NR>1{c++} END{print c+0}'; }

TOTAL_ROWS=0; FAILED=""
log "BEGIN  ${#TBL[@]} table(s), period $FROM_TS to $TO_TS, step ${STEP_HOURS}h, into $OUT_DIR"
for t in "${TBL[@]}"; do
  c="$(tcol "$t")"; tdir="$OUT_DIR/$t"; mkdir -p "$tdir"
  manifest_tmp="$tdir/_manifest.csv.tmp"; echo "file,rows" > "$manifest_tmp"
  t_rows=0; t_files=0
  while IFS=$'\t' read -r f_ts t_ts; do
    [ -z "$f_ts" ] && continue
    base="${t}_$(label_ts "$f_ts")__to__$(label_ts "$t_ts").csv.gz"
    fname="$tdir/$base"; tmp="$fname.part"; CURRENT_TMP="$tmp"
    if [ -s "$fname" ]; then
      rows="$(count_rows "$fname")"; log "SKIP   $t/$base exists (rows=$rows)"
    else
      rm -f "$tmp"
      select_sql="SELECT * FROM $(relation "$t") WHERE $(where_for "$c" "$f_ts" "$t_ts") ORDER BY \"$c\", 1"
      if [ "${SOURCE[$t]}" = postgres ]; then
        copy_sql="COPY ($select_sql) TO STDOUT CSV HEADER"
      else
        copy_sql="COPY ($select_sql) TO '/dev/stdout' (FORMAT CSV, HEADER true);"
      fi
      if ! source_q "$t" "$copy_sql" | gzip -c > "$tmp"; then
        rm -f "$tmp"; log "ERROR  $t/$base: COPY failed" >&2; FAILED="$t/$base"; break
      fi
      rows="$(count_rows "$tmp")"
      if [ "$SKIP_EMPTY" = yes ] && [ "$rows" -eq 0 ]; then
        rm -f "$tmp"; log "INFO   $t/$base has no rows: not kept (SKIP_EMPTY=yes)"; CURRENT_TMP=""; continue
      fi
      mv -f "$tmp" "$fname"; log "DONE   $t/$base rows=$rows"
    fi
    CURRENT_TMP=""
    echo "$base,$rows" >> "$manifest_tmp"; t_rows=$(( t_rows + rows )); t_files=$(( t_files + 1 ))
  done < <(make_ranges "$FROM_TS" "$TO_TS" "$STEP_HOURS")
  [ -n "$FAILED" ] && { rm -f "$manifest_tmp"; break; }
  mv -f "$manifest_tmp" "$tdir/_manifest.csv"
  log "TABLE  $t: $t_files file(s), $t_rows row(s)"
  TOTAL_ROWS=$(( TOTAL_ROWS + t_rows ))
done

if [ -n "$FAILED" ]; then
  printf 'Export stopped at %s\nThe zip was NOT made. Nothing from this run should be loaded.\n' "$FAILED" > "$OUT_DIR/___All_Errors.txt"
  log "FAILED the export stopped at $FAILED. No zip was made (see $OUT_DIR/___All_Errors.txt)." >&2
  exit 1
fi

# ---- zip (the csv.gz files are already compressed: store them), then the checksum ----------------------
ZIP_TMP="$OUT_ROOT/.tmp_$ZIP_NAME.zip"; rm -f "$ZIP_TMP"
log "ZIP    $ZIP_FILE (tool: $ZIP_TOOL)"
if [ "$ZIP_TOOL" = zip ]; then
  ( cd "$OUT_ROOT" && zip -0 -r -q "$ZIP_TMP" "$ZIP_NAME" -x '*/.export-identity.sha256' ) || { rm -f "$ZIP_TMP"; log "ERROR  zip failed" >&2; exit 1; }
else
  python3 -I - "$OUT_ROOT" "$ZIP_NAME" "$ZIP_TMP" <<'PY' || { rm -f "$ZIP_TMP"; log "ERROR  zip failed" >&2; exit 1; }
import os, sys, zipfile
root, name, out = sys.argv[1:4]
with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
    for d, _, files in os.walk(os.path.join(root, name)):
        for f in sorted(files):
            if f == '.export-identity.sha256': continue
            p = os.path.join(d, f)
            z.write(p, os.path.relpath(p, root).replace(os.sep, "/"))
PY
fi
mv -f "$ZIP_TMP" "$ZIP_FILE"
( cd "$OUT_ROOT" && sha256sum "$ZIP_NAME.zip" > "$ZIP_NAME.zip.sha256" )
SHA="$(cut -d' ' -f1 "$ZIP_FILE.sha256")"
log "DONE   $ZIP_FILE ($(du -h "$ZIP_FILE" | cut -f1), $TOTAL_ROWS row(s))"
echo "RESULT_ZIP=$ZIP_FILE"
echo "RESULT_SHA256=$SHA"
echo "RESULT_ROWS=$TOTAL_ROWS"
