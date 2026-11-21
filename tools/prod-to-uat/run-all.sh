#!/usr/bin/env bash
# run-all.sh - runs ON UAT. One command: export on prod (over SSH) -> copy the zip to UAT -> load it (db-import) -> compare (pivot-compare).
#
#   ./run-all.sh <config.env>                 the whole chain (asks once before it starts)
#   ./run-all.sh --check <config.env>         read only: SSH, the export's own check on prod, disk space, the other configs
#   ./run-all.sh --dry-run <config.env>       export + copy for real, db-import --dry-run (rolled back), no compare
#   options:  --steps export,copy,load,compare   run only some steps (default: all of STEPS in the config)
#             --name <zip name>                  use / continue the run of that name (needed to re-run a later step)
#             --resume                           with --name: continue a stopped export (finished chunks are kept)
#             --yes                              do not ask
# Exit code: 0 all steps ok (compare IDENTICAL or not run) | 1 a step failed | 2 bad setup or config
#            3 chain ok but the comparison says DIFFERENT | 4 chain ok but the comparison says NOT COMPARABLE
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 2; }
CONF=""; CHECK=0; DRY=0; ASSUME_YES=0; O_STEPS=""; O_NAME=""; O_RESUME=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   CHECK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --yes)     ASSUME_YES=1; shift ;;
    --resume)  O_RESUME=1; shift ;;
    --steps)   O_STEPS="${2:-}"; shift 2 ;;
    --name)    O_NAME="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*)        die "unknown option $1 (see --help)" ;;
    *)         CONF="$1"; shift ;;
  esac
done
[ -n "$CONF" ] || die "name the config file: ./run-all.sh [--check|--dry-run] <config.env>"
[ -f "$CONF" ] || die "config file not found: $CONF"
CONF="$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")"
# shellcheck disable=SC1090
. "$CONF"

# ---- settings and checks -------------------------------------------------------------------------------
JOB_NAME="${JOB_NAME:-prod_to_uat}"
REMOTE_MODE="${REMOTE_MODE:-ssh}"                      # ssh | local (local = the "prod" step runs on this machine: for tests)
PROD_SSH_HOST="${PROD_SSH_HOST:-}"; PROD_SSH_USER="${PROD_SSH_USER:-}"; PROD_SSH_PORT="${PROD_SSH_PORT:-22}"
PROD_SSH_KEY="${PROD_SSH_KEY:-}"; SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-15}"
PROD_EXPORT_SCRIPT="${PROD_EXPORT_SCRIPT:-}"; PROD_EXPORT_CONFIG="${PROD_EXPORT_CONFIG:-}"; PROD_OUT_ROOT="${PROD_OUT_ROOT:-}"
TABLES="${TABLES:-}"; POSTGRES_TABLES="${POSTGRES_TABLES:-}"; DUCKLAKE_TABLES="${DUCKLAKE_TABLES:-}"
PERIOD_FROM="${PERIOD_FROM:-}"; PERIOD_TO="${PERIOD_TO:-}"
ZIP_NAME_PREFIX="${ZIP_NAME_PREFIX:-$JOB_NAME}"
LOCAL_ZIP_DIR="${LOCAL_ZIP_DIR:-}"
DB_IMPORT_DIR="${DB_IMPORT_DIR:-$HERE/../db-import}"; DB_IMPORT_CONFIG="${DB_IMPORT_CONFIG:-}"
COMPARE="${COMPARE:-no}"; PIVOT_COMPARE_DIR="${PIVOT_COMPARE_DIR:-$HERE/../pivot-compare}"; PIVOT_COMPARE_CONFIG="${PIVOT_COMPARE_CONFIG:-}"
STEPS="${O_STEPS:-${STEPS:-export,copy,load,compare}}"
REPORT_DIR="${REPORT_DIR:-$HERE/reports}"
MIN_FREE_MB="${MIN_FREE_MB:-1024}"
SSH_BIN="${SSH_BIN:-ssh}"; SCP_BIN="${SCP_BIN:-scp}"

re_ident='^[A-Za-z0-9_-]+$'; re_path='^[A-Za-z0-9_./:@+-]+$'
need() { [ -n "${!1}" ] || die "$1 is not set in $CONF"; }
chk()  { [[ "${!1}" =~ $2 ]] || die "$1 has a character that is not allowed (got '${!1}')"; }
[[ "$JOB_NAME" =~ $re_ident ]] || die "JOB_NAME must be letters, digits, _ or - only"
case "$REMOTE_MODE" in ssh|local) ;; *) die "REMOTE_MODE must be ssh or local" ;; esac
need PROD_EXPORT_SCRIPT; need PROD_EXPORT_CONFIG; need PROD_OUT_ROOT; need PERIOD_FROM; need PERIOD_TO; need LOCAL_ZIP_DIR; need DB_IMPORT_CONFIG
# Typed lists identify their source explicitly. Never guess which source legacy TABLES belongs to.
declare -a EXPORT_TABLE_ARGS=()
declare -A TABLE_BASENAMES=()
validate_tables() {
  local kind="$1" list="$2" t base key
  local -a entries=()
  if [ "$kind" != TABLES ]; then
    [[ "$list" != ,* && "$list" != *, && "$list" != *,,* ]] || die "$kind must be a comma list of schema.table names (no empty entries)"
  fi
  IFS=, read -r -a entries <<< "$list"
  # read handles one line only: multiline input is not a comma-separated selection.
  [[ "$list" != *$'\n'* ]] || die "$kind must be a single comma-separated list"
  for t in "${entries[@]}"; do
    if [ "$kind" = TABLES ]; then
      t="${t//[$' \t\r']/}"; [ -n "$t" ] || continue
      [[ "$t" =~ ^[A-Za-z0-9_-]+$ ]] || die "TABLES entry '$t' must be an unqualified table name"
    else
      [[ "$t" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] || die "$kind entry '$t' must be explicitly qualified as schema.table"
    fi
    base="${t##*.}"; key="${base,,}"
    [ -z "${TABLE_BASENAMES[$key]:-}" ] || die "table basename collision (case-insensitive): '$t' and '${TABLE_BASENAMES[$key]}'"
    TABLE_BASENAMES[$key]="$t"
  done
}
if [ -n "$POSTGRES_TABLES$DUCKLAKE_TABLES" ]; then
  [ -z "$TABLES" ] || die "TABLES cannot be combined with POSTGRES_TABLES or DUCKLAKE_TABLES (ambiguous legacy mixed mode)"
  if [ -n "$POSTGRES_TABLES" ]; then
    validate_tables POSTGRES_TABLES "$POSTGRES_TABLES"
    EXPORT_TABLE_ARGS+=(--postgres-tables "$POSTGRES_TABLES")
  fi
  if [ -n "$DUCKLAKE_TABLES" ]; then
    validate_tables DUCKLAKE_TABLES "$DUCKLAKE_TABLES"
    EXPORT_TABLE_ARGS+=(--ducklake-tables "$DUCKLAKE_TABLES")
  fi
  TABLE_SELECTION="postgres: ${POSTGRES_TABLES:-<none>} | ducklake: ${DUCKLAKE_TABLES:-<none>}"
else
  [ -n "$TABLES" ] || die "TABLES is not set (or set POSTGRES_TABLES / DUCKLAKE_TABLES)"
  validate_tables TABLES "$TABLES"
  [ "${#TABLE_BASENAMES[@]}" -gt 0 ] || die "TABLES holds no table name"
  EXPORT_TABLE_ARGS+=(--tables "$TABLES")
  TABLE_SELECTION="$TABLES"
fi
for v in PROD_EXPORT_SCRIPT PROD_EXPORT_CONFIG PROD_OUT_ROOT LOCAL_ZIP_DIR; do chk "$v" "$re_path"; done
if [ "$REMOTE_MODE" = ssh ]; then
  need PROD_SSH_HOST; need PROD_SSH_USER
  [[ "$PROD_SSH_HOST" =~ ^[A-Za-z0-9._-]+$ ]] || die "PROD_SSH_HOST has a character that is not allowed"
  [[ "$PROD_SSH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "PROD_SSH_USER has a character that is not allowed"
  [[ "$PROD_SSH_PORT" =~ ^[0-9]+$ ]] || die "PROD_SSH_PORT must be a number"
  [[ "$SSH_CONNECT_TIMEOUT" =~ ^[0-9]+$ ]] || die "SSH_CONNECT_TIMEOUT must be a number"
  [ -z "$PROD_SSH_KEY" ] || { chk PROD_SSH_KEY "$re_path"; [ -r "$PROD_SSH_KEY" ] || die "PROD_SSH_KEY $PROD_SSH_KEY is not readable"; }
fi
[[ "$MIN_FREE_MB" =~ ^[0-9]+$ ]] || die "MIN_FREE_MB must be a whole number"
case "$COMPARE" in yes|no) ;; *) die "COMPARE must be yes or no" ;; esac
[ "$COMPARE" = no ] || need PIVOT_COMPARE_CONFIG
[ -f "$DB_IMPORT_CONFIG" ] || die "DB_IMPORT_CONFIG not found: $DB_IMPORT_CONFIG"
DB_IMPORT_CONFIG="$(cd "$(dirname "$DB_IMPORT_CONFIG")" && pwd)/$(basename "$DB_IMPORT_CONFIG")"
[ -x "$DB_IMPORT_DIR/db-import.sh" ] || [ -f "$DB_IMPORT_DIR/db-import.sh" ] || die "db-import.sh not found in DB_IMPORT_DIR=$DB_IMPORT_DIR"
DB_IMPORT_DIR="$(cd "$DB_IMPORT_DIR" && pwd)"
grep -Eq '^[[:space:]]*SOURCE_TYPE="?csv"?[[:space:]]*(#.*)?$' "$DB_IMPORT_CONFIG" || die "$DB_IMPORT_CONFIG must set SOURCE_TYPE=\"csv\" (it loads the zip this script copies)"
if [ "$COMPARE" = yes ]; then
  [ -f "$PIVOT_COMPARE_CONFIG" ] || die "PIVOT_COMPARE_CONFIG not found: $PIVOT_COMPARE_CONFIG"
  PIVOT_COMPARE_CONFIG="$(cd "$(dirname "$PIVOT_COMPARE_CONFIG")" && pwd)/$(basename "$PIVOT_COMPARE_CONFIG")"
  [ -f "$PIVOT_COMPARE_DIR/run.sh" ] || die "run.sh not found in PIVOT_COMPARE_DIR=$PIVOT_COMPARE_DIR"
  PIVOT_COMPARE_DIR="$(cd "$PIVOT_COMPARE_DIR" && pwd)"
fi

# the steps: a comma list of export, copy, load, compare, in this order
declare -A WANT=()
for s in $(tr ',' ' ' <<<"$STEPS"); do
  case "$s" in export|copy|load|compare) WANT[$s]=1 ;; *) die "unknown step '$s' (export, copy, load, compare)" ;; esac
done
[ "${#WANT[@]}" -gt 0 ] || die "STEPS is empty"
[ "$COMPARE" = yes ] || unset 'WANT[compare]' 2>/dev/null || true
[ "$DRY" -eq 0 ] || unset 'WANT[compare]' 2>/dev/null || true
[ "$O_RESUME" -eq 0 ] || [ -n "$O_NAME" ] || die "--resume needs --name <the zip name of the stopped run>"

RUN_TS="$(date +%Y%m%d_%H%M%S)"
if [ -n "$O_NAME" ]; then ZIP_NAME="$O_NAME"; else ZIP_NAME="${ZIP_NAME_PREFIX}_${RUN_TS}"; fi
[[ "$ZIP_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || die "the zip name must use letters, digits and _ . - only (got '$ZIP_NAME')"
REMOTE_ZIP="$PROD_OUT_ROOT/$ZIP_NAME.zip"
LOCAL_ZIP="$LOCAL_ZIP_DIR/$ZIP_NAME.zip"
RUN_DIR="$REPORT_DIR/${RUN_TS}_${JOB_NAME}"
mkdir -p "$RUN_DIR"
exec > >(tee -a "$RUN_DIR/run-all.log") 2>&1
log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
cp "$CONF" "$RUN_DIR/config_used.env"

# ---- talking to prod ------------------------------------------------------------------------------------------
SSH_ARGS=(-p "$PROD_SSH_PORT" -o BatchMode=yes -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT" -o ServerAliveInterval=30 -o ServerAliveCountMax=6)
SCP_ARGS=(-P "$PROD_SSH_PORT" -o BatchMode=yes -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT" -o ServerAliveInterval=30)
if [ -n "$PROD_SSH_KEY" ]; then SSH_ARGS+=(-i "$PROD_SSH_KEY"); SCP_ARGS+=(-i "$PROD_SSH_KEY"); fi
remote() {      # run the words as one command on prod (every word is quoted)
  if [ "$REMOTE_MODE" = local ]; then "$@"
  else "$SSH_BIN" "${SSH_ARGS[@]}" "$PROD_SSH_USER@$PROD_SSH_HOST" "$(printf '%q ' "$@")"; fi
}
fetch() {       # $1 remote file, $2 local file
  if [ "$REMOTE_MODE" = local ]; then cp "$1" "$2"
  else "$SCP_BIN" "${SCP_ARGS[@]}" "$PROD_SSH_USER@$PROD_SSH_HOST:$1" "$2"; fi
}
export_args() { printf '%s\n' --config "$PROD_EXPORT_CONFIG" "${EXPORT_TABLE_ARGS[@]}" --from "$PERIOD_FROM" --to "$PERIOD_TO" --name "$ZIP_NAME" --out-root "$PROD_OUT_ROOT"; }
run_export() {  # $@ extra options for the export script
  local -a a=(); mapfile -t a < <(export_args)
  remote bash "$PROD_EXPORT_SCRIPT" "${a[@]}" "$@"
}
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
free_mb() { mkdir -p "$1" 2>/dev/null || true; df -Pm "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
pw_var_of_db_import() { ( set +u; . "$DB_IMPORT_CONFIG" >/dev/null 2>&1; echo "${TARGET_PASSWORD_ENV:-}" ); }

# ---- one config line for db-import: it loads THIS run's zip; the rest of its config is untouched ------------------------
make_db_import_config() {
  local f="$RUN_DIR/db-import.env"
  cp "$DB_IMPORT_CONFIG" "$f"
  printf '\n# added by run-all.sh: the zip copied in this run\nSOURCE_CSV_PATH="%s"\n' "$LOCAL_ZIP" >> "$f"
  echo "$f"
}

# ---- --check --------------------------------------------------------------------------------------------------------------
do_check() {
  local bad=0 pw
  log "CHECK  job $JOB_NAME: steps $(IFS=,; echo "${!WANT[*]}") | zip name $ZIP_NAME"
  log "CHECK  prod: $([ "$REMOTE_MODE" = ssh ] && echo "$PROD_SSH_USER@$PROD_SSH_HOST:$PROD_SSH_PORT" || echo "this machine (REMOTE_MODE=local)")  export script $PROD_EXPORT_SCRIPT"
  if [ -n "${WANT[export]:-}${WANT[copy]:-}" ]; then
    if remote true >/dev/null 2>&1; then log "OK     can log in to prod without a password prompt"
    else log "ERROR  cannot run a command on prod (host, user, key, tunnel open?)"; return 2; fi
    if remote test -f "$PROD_EXPORT_SCRIPT" >/dev/null 2>&1; then log "OK     the export script exists on prod"
    else log "ERROR  $PROD_EXPORT_SCRIPT does not exist on prod"; bad=1; fi
    if remote test -f "$PROD_EXPORT_CONFIG" >/dev/null 2>&1; then log "OK     the export config exists on prod"
    else log "ERROR  $PROD_EXPORT_CONFIG does not exist on prod"; bad=1; fi
  fi
  if [ -n "${WANT[export]:-}" ] && [ "$bad" -eq 0 ]; then
    log "CHECK  the export script's own check on prod (read only):"
    local out rc=0
    out="$(run_export --check 2>&1)" || rc=$?
    sed 's/^/         | /' <<<"$out"
    [ "$rc" -eq 0 ] || { log "ERROR  the export check failed (see above)"; bad=1; }
  fi
  if [ -n "${WANT[copy]:-}${WANT[load]:-}" ]; then
    mkdir -p "$LOCAL_ZIP_DIR" 2>/dev/null || true
    if [ -d "$LOCAL_ZIP_DIR" ] && [ -w "$LOCAL_ZIP_DIR" ]; then
      local free; free="$(free_mb "$LOCAL_ZIP_DIR")"
      if [ "${free:-0}" -lt "$MIN_FREE_MB" ]; then log "ERROR  $LOCAL_ZIP_DIR has only ${free} MB free (MIN_FREE_MB=$MIN_FREE_MB)"; bad=1
      else log "OK     $LOCAL_ZIP_DIR is writable, ${free} MB free"; fi
    else log "ERROR  $LOCAL_ZIP_DIR does not exist or is not writable"; bad=1; fi
    if [ -n "${WANT[copy]:-}" ] && [ -e "$LOCAL_ZIP" ]; then log "ERROR  $LOCAL_ZIP already exists (nothing is overwritten; choose another --name)"; bad=1; fi
  fi
  if [ -n "${WANT[load]:-}" ]; then
    pw="$(pw_var_of_db_import)"
    if [ -n "$pw" ] && [ -z "${!pw:-}" ]; then log "ERROR  the target password variable $pw (TARGET_PASSWORD_ENV in the db-import config) is empty: export it first"; bad=1
    else log "OK     db-import config $DB_IMPORT_CONFIG sets SOURCE_TYPE=csv; target password variable: ${pw:-<none: ~/.pgpass>}"; fi
    if [ -z "${WANT[copy]:-}" ] && [ ! -f "$LOCAL_ZIP" ]; then log "ERROR  the load step needs $LOCAL_ZIP (run the copy step first)"; bad=1; fi
  fi
  [ -z "${WANT[compare]:-}" ] || log "OK     pivot-compare config $PIVOT_COMPARE_CONFIG"
  if [ "$bad" -eq 0 ]; then log "CHECK  everything is fine. Nothing was written (the load step has its own --check when it runs)."; return 0; fi
  log "CHECK  problems found (see ERROR above). Nothing was written."; return 2
}
if [ "$CHECK" -eq 1 ]; then do_check; exit $?; fi

# ---- the steps -----------------------------------------------------------------------------------------------------------------
STATUS_EXPORT="-"; STATUS_COPY="-"; STATUS_LOAD="-"; STATUS_COMPARE="-"; SECS_EXPORT=0; SECS_COPY=0; SECS_LOAD=0; SECS_COMPARE=0
ZIP_SHA=""; ZIP_ROWS=""; COMPARE_RC=""

step_export() {
  local out rc=0 extra=()
  [ "$O_RESUME" -eq 0 ] || extra+=(--resume)
  out="$(mktemp)"
  run_export ${extra[@]+"${extra[@]}"} 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then rm -f "$out"; return 1; fi
  ZIP_SHA="$(sed -n 's/^RESULT_SHA256=//p' "$out" | tail -1)"; ZIP_ROWS="$(sed -n 's/^RESULT_ROWS=//p' "$out" | tail -1)"
  rm -f "$out"
  [ -n "$ZIP_SHA" ] || { log "ERROR  the export did not report a checksum"; return 1; }
}
step_copy() {
  local want size_mb free tmp="$LOCAL_ZIP_DIR/.tmp_$ZIP_NAME.zip" got
  [ ! -e "$LOCAL_ZIP" ] || { log "ERROR  $LOCAL_ZIP already exists (nothing is overwritten; choose another --name)"; return 1; }
  want="${ZIP_SHA:-$(remote cat "$REMOTE_ZIP.sha256" | cut -d' ' -f1)}"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { log "ERROR  cannot read the checksum of $REMOTE_ZIP on prod (was the export finished?)"; return 1; }
  size_mb="$(remote stat -c %s "$REMOTE_ZIP" | awk '{printf "%d", $1/1048576+1}')"
  free="$(free_mb "$LOCAL_ZIP_DIR")"
  if [ "${free:-0}" -lt $(( size_mb + MIN_FREE_MB )) ]; then log "ERROR  $LOCAL_ZIP_DIR has ${free} MB free; the zip is ${size_mb} MB and MIN_FREE_MB=$MIN_FREE_MB"; return 1; fi
  log "COPY   $REMOTE_ZIP (${size_mb} MB) -> $LOCAL_ZIP"
  rm -f "$tmp"
  fetch "$REMOTE_ZIP" "$tmp" || { rm -f "$tmp"; log "ERROR  the copy failed"; return 1; }
  got="$(sha_of "$tmp")"
  if [ "$got" != "$want" ]; then rm -f "$tmp"; log "ERROR  the copy is damaged: checksum $got, expected $want. It was removed."; return 1; fi
  mv -f "$tmp" "$LOCAL_ZIP"; ZIP_SHA="$want"
  log "OK     copied, checksum $want matches"
}
step_load() {
  local cfg flags=() rc=0
  [ -f "$LOCAL_ZIP" ] || { log "ERROR  $LOCAL_ZIP does not exist (run the copy step first)"; return 1; }
  cfg="$(make_db_import_config)"
  log "LOAD   db-import --check first (it reads the zip and the target, and changes nothing)"
  ( cd "$DB_IMPORT_DIR" && bash ./db-import.sh --check "$cfg" ) || { log "ERROR  db-import --check failed: nothing was loaded"; return 1; }
  [ "$DRY" -eq 0 ] || flags+=(--dry-run)
  log "LOAD   db-import ${flags[*]:-} (real run)"
  ( cd "$DB_IMPORT_DIR" && bash ./db-import.sh ${flags[@]+"${flags[@]}"} --yes "$cfg" ) || rc=$?
  return "$rc"
}
step_compare() {
  local rc=0
  log "COMPARE pivot-compare $PIVOT_COMPARE_CONFIG"
  ( cd "$PIVOT_COMPARE_DIR" && bash ./run.sh "$PIVOT_COMPARE_CONFIG" ) || rc=$?
  COMPARE_RC="$rc"
  case "$rc" in 0|1|3) return 0 ;; *) return 1 ;; esac      # 0 identical, 1 different, 3 not comparable are answers; the rest is a failure
}

run_step() {    # $1 name
  local n="$1" t0 rc=0 up; up="$(tr a-z A-Z <<<"$n")"
  [ -n "${WANT[$n]:-}" ] || return 0
  log "===== step: $n ====="
  t0=$(date +%s)
  "step_$n" || rc=$?
  eval "SECS_$up=$(( $(date +%s) - t0 ))"
  if [ "$rc" -eq 0 ]; then eval "STATUS_$up=OK"; log "OK     step $n finished"; else eval "STATUS_$up=FAILED"; log "FAILED step $n (exit code $rc)"; fi
  return "$rc"
}

summary() {
  {
    echo "job:        $JOB_NAME"
    echo "run:        $RUN_TS"
    echo "zip:        $ZIP_NAME   (prod: $REMOTE_ZIP)   (UAT: $LOCAL_ZIP)"
    echo "tables:     $TABLE_SELECTION"
    echo "period:     $PERIOD_FROM  to  $PERIOD_TO"
    echo "checksum:   ${ZIP_SHA:--}    rows exported: ${ZIP_ROWS:--}"
    printf '%-9s %-8s %s\n' step status seconds
    printf '%-9s %-8s %s\n' export "$STATUS_EXPORT" "$SECS_EXPORT" copy "$STATUS_COPY" "$SECS_COPY" load "$STATUS_LOAD" "$SECS_LOAD" compare "$STATUS_COMPARE" "$SECS_COMPARE"
    [ -z "$COMPARE_RC" ] || echo "compare exit code: $COMPARE_RC (0 identical, 1 different, 3 not comparable)"
    echo "report folder: $RUN_DIR"
  } | tee "$RUN_DIR/summary.txt"
}

# ---- go ------------------------------------------------------------------------------------------------------------------------------
log "BEGIN  job $JOB_NAME, zip $ZIP_NAME, steps: $(for s in export copy load compare; do [ -n "${WANT[$s]:-}" ] && printf '%s ' "$s"; done)$([ "$DRY" -eq 1 ] && echo '(DRY RUN: the load is rolled back, no compare)')"
log "       tables: $TABLE_SELECTION"
log "       period: $PERIOD_FROM to $PERIOD_TO"
if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
  read -r -p "Start? type yes: " ans; [ "$ans" = yes ] || { log "stopped by the user: nothing was done"; exit 2; }
fi
[ -n "${WANT[export]:-}${WANT[copy]:-}" ] && { remote true >/dev/null 2>&1 || { log "ERROR  cannot run a command on prod (host, user, key, tunnel open?): nothing was done"; exit 2; }; }

FAILED=""
for s in export copy load compare; do
  run_step "$s" || { FAILED="$s"; break; }
done
summary
if [ -n "$FAILED" ]; then log "STOPPED at step $FAILED: later steps were not run. Fix it, then re-run the step with:  ./run-all.sh $CONF --name $ZIP_NAME --steps ${FAILED}$( [ "$FAILED" = export ] && echo ' --resume' )"; exit 1; fi
case "${COMPARE_RC:-}" in 1) log "DONE   all steps ran; the comparison says DIFFERENT"; exit 3 ;; 3) log "DONE   all steps ran; the comparison says NOT COMPARABLE"; exit 4 ;; esac
log "DONE   all steps ran"
exit 0
