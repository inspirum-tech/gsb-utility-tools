#!/usr/bin/env bash
# Compares OLD pivot tables (Java calculator) with the NEW calculator's output for the same periods.
# Read only on both sources; the only things written are the report files in REPORT_DIR.
#   ./run.sh [config-file]        default config file: config.env
# MODE=manual (config): one comparison of the tables named in the config.
# MODE=auto   (config): the families (pivot tables) are found from the KPI definitions; one comparison per family.
# Exit code: 0 = IDENTICAL, 1 = DIFFERENT, 3 = NOT COMPARABLE (nothing in common), 2 = bad setup.
# Connection strings are read from the environment or from ENV_FILE and are never printed.
set -euo pipefail
START_DIR="$(pwd)"
cd "$(dirname "${BASH_SOURCE[0]}")"
TOOL_DIR="$(pwd)"

# the config file is found from where you ran the script, else from the tool folder; the tool then works inside its folder
CONFIG="${1:-config.env}"
case "$CONFIG" in
  /*|[A-Za-z]:*) ;;
  *) if [ -f "$START_DIR/$CONFIG" ]; then CONFIG="$START_DIR/$CONFIG"; else CONFIG="$TOOL_DIR/$CONFIG"; fi ;;
esac
[ -f "$CONFIG" ] || { echo "config file not found: $CONFIG" >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONFIG"

die() { echo "config error: $*" >&2; exit 2; }

# ---- value checks: identifiers, numbers and paths only; nothing else reaches the SQL ----------------
need_ident()  { [[ "${!1:-}" =~ ^[A-Za-z0-9_]+$ ]] || die "$1 must be letters, digits and _ only (got '${!1:-}')"; }
opt_ident()   { [ -z "${!1:-}" ] || need_ident "$1"; }
need_number() { [[ "${!1:-}" =~ ^[0-9]+(\.[0-9]+)?([eE]-?[0-9]+)?$ ]] || die "$1 must be a non-negative number (got '${!1:-}')"; }
need_signed() { [[ "${!1:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || die "$1 must be a number (got '${!1:-}')"; }
need_yesno()  { [[ "${!1:-}" =~ ^(yes|no)$ ]] || die "$1 must be yes or no (got '${!1:-}')"; }
need_ts()     { [[ "${!1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[\ T][0-9:.]+(Z|[+-][0-9:]{2,5})?$ ]] || die "$1 must look like 2025-12-19 09:00:00+00 (got '${!1:-}')"; }
need_path()   { [[ "${!1:-}" =~ ^[A-Za-z0-9_./-]+$ ]] || die "$1 must use letters, digits and _ . / - only"; }
opt_path()    { [ -z "${!1:-}" ] || need_path "$1"; }
need_regex()  { case "${!1:-}" in ''|*\'*|*\"*|*\;*|*--*|*$'\n'*) die "$1 must be a regular expression without quotes, ; or --";; esac; }

MODE="${MODE:-manual}"
case "$MODE" in manual|auto|list) ;; *) die "MODE must be manual, auto or list";; esac
need_ts PERIOD_FROM; need_ts PERIOD_TO
for v in TOLERANCE_ABS TOLERANCE_REL FLOAT_SLACK; do need_number "$v"; done
need_signed SPECIAL_DEFAULT
for v in SPECIAL_AS_DEFAULT NULL_AS_DEFAULT FAIL_ON_OBJECTS_ONE_SIDE FAIL_ON_KPI_COLUMNS_ONE_SIDE FAIL_ON_NULL_ONE_SIDE; do need_yesno "$v"; done
# FAIL_ON_DUPLICATES: a repeated row on one side is reduced with max(), which can hide a real difference.
#   conflicting (default) = the verdict is DIFFERENT when repeated rows hold different values; yes = DIFFERENT for any repeated row; no = never
FAIL_ON_DUPLICATES="${FAIL_ON_DUPLICATES:-conflicting}"
case "$FAIL_ON_DUPLICATES" in no|conflicting|yes) ;; *) die "FAIL_ON_DUPLICATES must be no, conflicting or yes (got '$FAIL_ON_DUPLICATES')";; esac
need_regex KPI_REGEX
opt_path KPI_LIST_FILE; opt_path KPI_MAP_FILE; need_path REPORT_DIR; opt_path TEMP_DIR; need_path ENV_FILE
[[ "$MAX_DIFF_ROWS" =~ ^[0-9]+$ ]] || die "MAX_DIFF_ROWS must be a whole number"
[ -z "${THREADS:-}" ] || [[ "$THREADS" =~ ^[0-9]+$ ]] || die "THREADS must be a whole number"
[ -z "${MEMORY_LIMIT:-}" ] || [[ "$MEMORY_LIMIT" =~ ^[0-9]+(\.[0-9]+)?[A-Za-z]*$ ]] || die "MEMORY_LIMIT must look like 8GB"
[ -z "${KPI_LIST_FILE}" ] || [ -f "$KPI_LIST_FILE" ] || die "KPI_LIST_FILE not found: $KPI_LIST_FILE"
[ -z "${KPI_MAP_FILE}" ] || [ -f "$KPI_MAP_FILE" ] || die "KPI_MAP_FILE not found: $KPI_MAP_FILE"
command -v "$DUCKDB" >/dev/null 2>&1 || [ -x "$DUCKDB" ] || die "DuckDB CLI not found (DUCKDB=$DUCKDB)"

# info columns (labels such as SITE_NAME, CELL_NAME): compared and reported separately, never part of the KPI verdict
INFO_COMPARE="${INFO_COMPARE:-no}"; INFO_COLS="${INFO_COLS:-}"; INFO_SELECT=""; INFO_ON=""
need_yesno INFO_COMPARE
build_info() {  # builds the SQL pieces of INFO_COLS (called at start and again for every line of a pairs file)
  INFO_SELECT=""; INFO_ON=""
  [ "$INFO_COMPARE" = yes ] || return 0
  [[ "$INFO_COLS" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] || die "INFO_COLS must be column names separated by commas"
  local IFS_SAVE="$IFS" c; IFS=','
  for c in $INFO_COLS; do
    INFO_SELECT+="${INFO_SELECT:+, }coalesce(CAST(\"$c\" AS VARCHAR), '~~NULL~~') AS \"$c\""
    INFO_ON+="${INFO_ON:+, }\"$c\""
  done
  IFS="$IFS_SAVE"
}
build_info

if [ "$MODE" = auto ]; then
  [[ "${AUTO_APPLICATIONS:-}" =~ ^(ALL|[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*)$ ]] || die "AUTO_APPLICATIONS must be ALL or application names separated by commas (letters, digits, _)"
  for v in DEF_SCHEMA DEF_TABLE DEF_COL_KPI_ID DEF_COL_APPLICATION DEF_COL_RESOLUTION DEF_COL_LEVEL DEF_COL_TECHNOLOGY DEF_COL_VENDOR; do need_ident "$v"; done
  opt_ident AUTO_KPI_PREFIX
  [[ "${AUTO_OLD_TABLE_PATTERN:-}" =~ ^[A-Za-z0-9_{}]+$ ]] || die "AUTO_OLD_TABLE_PATTERN may use letters, digits, _ and the words {APPLICATION} {RES} {LEVEL} {TECH} {VENDOR}"
  [[ "${AUTO_RES_TOKENS:-}" =~ ^[A-Za-z0-9]+=[A-Za-z0-9_]+(,[A-Za-z0-9]+=[A-Za-z0-9_]+)*$ ]] || die "AUTO_RES_TOKENS must look like Q=QRLY,H=HRLY"
fi

# ---- sources: attach what is needed (connection strings stay in this variable only) ------------------
ATTACH_SQL=""      # holds connection strings: never printed, never written to the report folder
ATTACHED_KEYS=""   # "key=alias;" pairs, so two sides that use the same database attach it once
ALIAS=""

dsn_of() {  # $1 = name of the variable or the ENV_FILE key
  local name="$1" dsn="${!1:-}"
  if [ -z "$dsn" ] && [ -f "$ENV_FILE" ]; then
    dsn="$(grep "^${name}=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' || true)"
  fi
  [ -n "$dsn" ] || die "no connection string: set the environment variable $name or the line $name=... in $ENV_FILE"
  printf '%s' "$dsn"
}

# The DuckDB "postgres" extension is needed to read a Postgres source. Try LOAD first (works with no
# internet when the extension is already on this machine); INSTALL (a download) only when LOAD fails.
# If both fail we stop here with one clear message, not in the middle of a run.
PG_EXT_OK=no
ensure_pg_ext() {
  [ "$PG_EXT_OK" = yes ] && return 0
  if "$DUCKDB" -c "LOAD postgres;" >/dev/null 2>&1; then :
  elif "$DUCKDB" -c "INSTALL postgres; LOAD postgres;" >/dev/null 2>&1; then :
  else
    die "the DuckDB 'postgres' extension is not on this machine and could not be downloaded (no internet?). Copy it once from a machine that has it: ~/.duckdb/extensions/<duckdb version>/<platform>/postgres_scanner.duckdb_extension to the same folder for this user (see README, 'Offline servers')"
  fi
  PG_EXT_OK=yes
}

attach_source() {  # $1 = OLD, NEW or DEF; sets ALIAS (the catalog name to use in SQL)
  local P="$1" side src key v
  side="$(echo "$P" | tr 'A-Z' 'a-z')"
  v() { local n="${P}_$1"; printf '%s' "${!n:-}"; }
  src="$(v SOURCE)"
  case "$src" in postgres|attached|duckdb) ;; *) die "${P}_SOURCE must be postgres, attached or duckdb";; esac
  local envname="" f="" c=""
  case "$src" in
    postgres) envname="$(v DSN_ENV)"; [[ "$envname" =~ ^[A-Za-z0-9_]+$ ]] || die "${P}_DSN_ENV must be a variable name"; key="pg:$envname" ;;
    duckdb)   f="$(v DB_FILE)"; [[ "$f" =~ ^[A-Za-z0-9_./-]+$ ]] || die "${P}_DB_FILE must be a path (letters, digits, _ . / -)"
              [ -f "$f" ] || die "${P}_DB_FILE not found: $f"; key="db:$f" ;;
    attached) c="$(v CATALOG)"; [[ "$c" =~ ^[A-Za-z0-9_]+$ ]] || die "${P}_CATALOG must be a catalog name"; key="cat:$c" ;;
  esac
  case ";$ATTACHED_KEYS" in
    *";$key="*) ALIAS="$(printf '%s' "$ATTACHED_KEYS" | tr ';' '\n' | grep -F "$key=" | head -1 | cut -d= -f2-)" ;;
    *)
      case "$src" in
        postgres)
          ALIAS="cmp_pg_$side"; local dsn; dsn="$(dsn_of "$envname")"; ensure_pg_ext
          ATTACH_SQL+="LOAD postgres;"$'\n'"ATTACH '${dsn//\'/\'\'}' AS ${ALIAS} (TYPE postgres, READ_ONLY);"$'\n' ;;
        duckdb)   ALIAS="cmp_db_$side"; ATTACH_SQL+="ATTACH '${f}' AS ${ALIAS} (READ_ONLY);"$'\n' ;;
        attached) ALIAS="$c" ;;
      esac
      ATTACHED_KEYS+="$key=$ALIAS;" ;;
  esac
}

# ---- per side: build the pieces the SQL templates need --------------------------------------------
prep_side() {  # $1 = OLD or NEW
  local P="$1" side; side="$(echo "$P" | tr 'A-Z' 'a-z')"
  local shape kind alias
  v() { local n="${P}_$1"; printf '%s' "${!n:-}"; }
  shape="$(v SHAPE)"; kind="$(v PERIOD_KIND)"
  case "$shape" in wide|tall) ;; *) die "${P}_SHAPE must be wide or tall";; esac
  case "$kind" in local|tz) ;; *) die "${P}_PERIOD_KIND must be local or tz";; esac
  local schema table pcol; schema="$(v SCHEMA)"; table="$(v TABLE)"; pcol="$(v PERIOD_COL)"
  [ -n "$schema" ] || schema=main
  for n in "$schema" "$table" "$pcol"; do [[ "$n" =~ ^[A-Za-z0-9_]+$ ]] || die "${P}: schema, table and period column must be letters, digits, _ only"; done
  local keys; keys="$(v KEY_COLS)"
  [[ "$keys" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] || die "${P}_KEY_COLS must be names separated by commas"
  local tz; tz="$(v PERIOD_TZ)"; [ "$kind" = tz ] || { [[ "$tz" =~ ^[A-Za-z0-9_/+-]+$ ]] || die "${P}_PERIOD_TZ must be a time zone name"; }

  attach_source "$P"; alias="$ALIAS"

  # key expression: the key columns as text joined with |, NULL shown as <NULL>
  local kexpr="" col IFS_OLD="$IFS"; IFS=','
  for col in $keys; do
    [ -z "$kexpr" ] || kexpr+=" || '|' || "
    kexpr+="coalesce(CAST(\"$col\" AS VARCHAR), '<NULL>')"
  done
  IFS="$IFS_OLD"
  # optional: rewrite the key text with a regex (RE2, \1 for a group) so keys that differ only in format can match,
  # e.g. NEW_KEY_REGEX_FROM='Inner-(.*)-X$' NEW_KEY_REGEX_TO='Inner_\1'. A key that does not match is left unchanged.
  local krf krt; krf="$(v KEY_REGEX_FROM)"; krt="$(v KEY_REGEX_TO)"
  if [ -n "$krf" ]; then
    case "$krf$krt" in *$'\n'*) die "${P}_KEY_REGEX_FROM/TO must be one line";; esac
    kexpr="regexp_replace(${kexpr}, '${krf//\'/\'\'}', '${krt//\'/\'\'}')"
  fi
  NKEYS_COUNT="$(printf '%s' "$keys" | tr ',' '\n' | wc -l | tr -d ' ')"

  # period: normalised to a timestamptz (UTC instant); the window test is on the raw column so it can be pushed down
  if [ "$kind" = local ]; then
    P_EXPR="timezone('$tz', \"$pcol\")"
    FROM_NATIVE="(TIMESTAMPTZ '$PERIOD_FROM' AT TIME ZONE '$tz')"
    TO_NATIVE="(TIMESTAMPTZ '$PERIOD_TO' AT TIME ZONE '$tz')"
  else
    P_EXPR="\"$pcol\""
    FROM_NATIVE="TIMESTAMPTZ '$PERIOD_FROM'"
    TO_NATIVE="TIMESTAMPTZ '$PERIOD_TO'"
  fi

  FILTER_SQL=""
  local fc fv; fc="$(v FILTER_COL)"; fv="$(v FILTER_VALUE)"
  if [ -n "$fc" ]; then
    [[ "$fc" =~ ^[A-Za-z0-9_]+$ ]] || die "${P}_FILTER_COL must be a column name"
    case "$fv" in *$'\n'*) die "${P}_FILTER_VALUE must be one line";; esac
    FILTER_SQL=" AND \"$fc\" = '${fv//\'/\'\'}'"
  fi

  if [ "$INFO_COMPARE" = yes ] && [ "$shape" = wide ]; then
    INFO_SIDE_SQL="CREATE OR REPLACE TEMP TABLE ${side}_info AS SELECT p_utc, k, col, max(val) AS val FROM (SELECT __p AS p_utc, __k AS k, col, nullif(val, '~~NULL~~') AS val FROM (UNPIVOT (SELECT __p, __k, ${INFO_SELECT} FROM ${side}_src) ON ${INFO_ON} INTO NAME col VALUE val)) GROUP BY 1, 2, 3;"
  else
    INFO_SIDE_SQL="CREATE OR REPLACE TEMP TABLE ${side}_info AS SELECT CAST(NULL AS TIMESTAMPTZ) AS p_utc, CAST(NULL AS VARCHAR) AS k, CAST(NULL AS VARCHAR) AS col, CAST(NULL AS VARCHAR) AS val WHERE false;"
  fi

  SIDE="$side"; REF="${alias}.\"$schema\".\"$table\""; K_EXPR="$kexpr"; PER_COL="\"$pcol\""
  SIDE_KPI_REGEX="$(v KPI_REGEX)"; SIDE_PREFIX=""; KPI_COL_Q=""; VALUE_COL_Q=""
  if [ "$shape" = wide ]; then
    need_regex "${P}_KPI_REGEX"
    DUP_THRESHOLD=1
  else
    local kc vc; kc="$(v KPI_COL)"; vc="$(v VALUE_COL)"; SIDE_PREFIX="$(v KPI_PREFIX)"
    [[ "$kc" =~ ^[A-Za-z0-9_]+$ && "$vc" =~ ^[A-Za-z0-9_]+$ ]] || die "${P}_KPI_COL and ${P}_VALUE_COL are needed for a tall side"
    [[ "$SIDE_PREFIX" =~ ^[A-Za-z0-9_]*$ ]] || die "${P}_KPI_PREFIX must be letters, digits, _ only"
    KPI_COL_Q="\"$kc\""; VALUE_COL_Q="\"$vc\""
    SIDE_KPI_REGEX="$KPI_REGEX"
    DUP_THRESHOLD=2147483647   # in a tall source several rows per object are normal (one per KPI)
    # auto mode: only the rows of the KPIs that belong to this family (so other families' objects do not show up)
    if [ -n "${FAMILY_TABLE:-}" ]; then
      FILTER_SQL+=" AND CAST(${KPI_COL_Q} AS BIGINT) IN (SELECT kpi_id FROM family_kpis)"
    fi
  fi
  export SIDE REF K_EXPR PER_COL P_EXPR FROM_NATIVE TO_NATIVE FILTER_SQL SIDE_KPI_REGEX SIDE_PREFIX KPI_COL_Q VALUE_COL_Q
}

render() {  # replaces ${NAME} in a template with the variables prepared above (values are not re-expanded)
  eval "cat <<__PIVOT_COMPARE_SQL__
$(cat "$1")
__PIVOT_COMPARE_SQL__"
}

duck_settings() {
  [ -z "${MEMORY_LIMIT:-}" ] || echo "SET memory_limit = '$MEMORY_LIMIT';"
  [ -z "${TEMP_DIR:-}" ]     || echo "SET temp_directory = '$TEMP_DIR';"
  [ -z "${THREADS:-}" ]      || echo "SET threads = $THREADS;"
}

# ---- one comparison: the tables named in OLD_* / NEW_* (and FAMILY_* in auto mode) ----------------------
run_one() {
  ATTACH_SQL=""; ATTACHED_KEYS=""
  local SQL_BODY="" KEYS_OLD="" P shape_var
  FAMILY_SQL=""
  if [ -n "${FAMILY_TABLE:-}" ]; then
    FAMILY_SQL="CREATE OR REPLACE TEMP TABLE family_kpis AS SELECT kpi_id FROM read_csv('${FAMILY_KPIS_FILE}', header = true, columns = {'table_name': 'VARCHAR', 'kpi_id': 'BIGINT'}) WHERE table_name = '${FAMILY_TABLE}';"
    SQL_BODY+="$FAMILY_SQL"$'\n'
  fi
  for P in OLD NEW; do
    prep_side "$P"
    [ "$P" = OLD ] && KEYS_OLD="$NKEYS_COUNT" && DUP_THRESHOLD_OLD="$DUP_THRESHOLD"
    [ "$P" = NEW ] && DUP_THRESHOLD_NEW="$DUP_THRESHOLD" && { [ "$NKEYS_COUNT" = "$KEYS_OLD" ] || die "OLD_KEY_COLS and NEW_KEY_COLS must have the same number of columns"; }
    shape_var="${P}_SHAPE"
    if [ "${!shape_var}" = wide ]; then SQL_BODY+="$(render sql/10_side_wide.sql)"$'\n'; else SQL_BODY+="$(render sql/11_side_tall.sql)"$'\n'; fi
  done

  if [ -n "$KPI_MAP_FILE" ]; then
    KPI_MAP_SQL="CREATE OR REPLACE TEMP TABLE kpimap AS SELECT * FROM read_csv('$KPI_MAP_FILE', header = true, columns = {'old_kpi': 'VARCHAR', 'new_kpi': 'VARCHAR'});
UPDATE new_long SET kpi = m.old_kpi FROM kpimap m WHERE new_long.kpi = m.new_kpi;
UPDATE new_cols SET kpi = m.old_kpi FROM kpimap m WHERE new_cols.kpi = m.new_kpi;"
  else
    KPI_MAP_SQL=""
  fi
  if [ -n "${FAMILY_TABLE:-}" ]; then
    KPI_ALLOWED_SELECT="SELECT '${AUTO_KPI_PREFIX}' || CAST(kpi_id AS VARCHAR) AS kpi FROM family_kpis"
    [ -z "$KPI_LIST_FILE" ] || KPI_ALLOWED_SELECT+=" WHERE '${AUTO_KPI_PREFIX}' || CAST(kpi_id AS VARCHAR) IN (SELECT trim(kpi) FROM read_csv('$KPI_LIST_FILE', header = false, columns = {'kpi': 'VARCHAR'}))"
  elif [ -n "$KPI_LIST_FILE" ]; then
    KPI_ALLOWED_SELECT="SELECT trim(kpi) AS kpi FROM read_csv('$KPI_LIST_FILE', header = false, columns = {'kpi': 'VARCHAR'}) WHERE trim(kpi) <> ''"
  else
    KPI_ALLOWED_SELECT="SELECT kpi FROM old_cols UNION SELECT kpi FROM new_cols"
  fi
  export KPI_MAP_SQL KPI_ALLOWED_SELECT DUP_THRESHOLD_OLD DUP_THRESHOLD_NEW
  SQL_BODY+="$(render sql/20_compare.sql)"$'\n'
  [ "$INFO_COMPARE" != yes ] || SQL_BODY+="$(render sql/25_info.sql)"$'\n'
  SQL_BODY+="$(render sql/30_report.sql)"$'\n'

  mkdir -p "$REPORT_DIR"
  printf '%s' "$SQL_BODY" > "$REPORT_DIR/generated.sql"   # no connection strings in it
  cp "$CONFIG" "$REPORT_DIR/config_used.env"
  # list and auto mode override some settings per table; record the values this table really used (the last line wins)
  { printf '\n# ---- effective values for this table (list / auto mode override the lines above) ----\n'
    for ev in OLD_TABLE NEW_TABLE OLD_KEY_COLS NEW_KEY_COLS INFO_COMPARE INFO_COLS; do printf '%s=%s\n' "$ev" "${!ev-}"; done
  } >> "$REPORT_DIR/config_used.env"
  local T; T="$(mktemp -d)"; chmod 700 "$T"
  printf '%s\n%s\n%s' "$ATTACH_SQL" "$(duck_settings)" "$SQL_BODY" > "$T/run.sql"

  rm -f "$REPORT_DIR/verdict.txt"
  local rc=0
  if [ -n "${FAMILY_TABLE:-}" ]; then
    "$DUCKDB" -bail -f "$T/run.sql" > "$REPORT_DIR/screen.txt" || rc=$?
  else
    echo "pivot-compare: ${OLD_TABLE} (${OLD_SHAPE}, ${OLD_SOURCE}) against ${NEW_TABLE} (${NEW_SHAPE}, ${NEW_SOURCE})"
    echo "period (UTC): $PERIOD_FROM  to  $PERIOD_TO     report folder: $REPORT_DIR"
    "$DUCKDB" -bail -f "$T/run.sql" || rc=$?
  fi
  rm -rf "$T"
  [ "$rc" -eq 0 ] || { echo "the comparison stopped with an error; nothing was written to the sources" >&2; return 2; }

  [ -s "$REPORT_DIR/verdict.txt" ] || die "no verdict was written"
  case "$(cut -d: -f1 "$REPORT_DIR/verdict.txt")" in
    IDENTICAL) return 0 ;;
    DIFFERENT) return 1 ;;
    "NOT COMPARABLE") return 3 ;;
    *) return 2 ;;
  esac
}

# ---- CM comparison (CM_COMPARE=yes): the CM table of the old side against the CM table of the new side -------
CM_COMPARE="${CM_COMPARE:-no}"
CM_FAIL_ON_OBJECTS_ONE_SIDE="${CM_FAIL_ON_OBJECTS_ONE_SIDE:-yes}"
CM_FAIL_ON_COLUMNS_ONE_SIDE="${CM_FAIL_ON_COLUMNS_ONE_SIDE:-no}"
need_yesno CM_COMPARE

run_cm() {  # $1 = folder for the CM report files; returns 0 IDENTICAL, 1 DIFFERENT, 3 NOT COMPARABLE, 2 error
  local CM_REPORT_DIR="$1" P col IFS_OLD="$IFS" skip excl=""
  need_yesno CM_FAIL_ON_OBJECTS_ONE_SIDE; need_yesno CM_FAIL_ON_COLUMNS_ONE_SIDE
  [[ "${CM_KEY_COLS:-}" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] || die "CM_KEY_COLS must be names separated by commas"
  [ -z "${CM_EXCLUDE_COLS:-}" ] || [[ "$CM_EXCLUDE_COLS" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] || die "CM_EXCLUDE_COLS must be names separated by commas"
  opt_ident CM_ASOF_COL
  [ -z "${CM_ASOF_COL:-}" ] || [[ "${CM_ASOF_TZ:-}" =~ ^[A-Za-z0-9_/+-]+$ ]] || die "CM_ASOF_TZ must be a time zone name"

  CM_K_EXPR=""; IFS=','
  for col in $CM_KEY_COLS; do
    [ -z "$CM_K_EXPR" ] || CM_K_EXPR+=" || '|' || "
    CM_K_EXPR+="coalesce(CAST(\"$col\" AS VARCHAR), '<NULL>')"
  done
  # columns that are never compared: internal helper columns, key columns, the as-of column, CM_EXCLUDE_COLS (each once)
  for col in __k __a __n $CM_KEY_COLS ${CM_ASOF_COL:-} ${CM_EXCLUDE_COLS:-}; do
    case ",$excl," in *",\"$col\","*) continue;; esac
    excl+="${excl:+,}\"$col\""
  done
  IFS="$IFS_OLD"
  CM_EXCLUDE_SQL="$excl"

  ATTACH_SQL=""; ATTACHED_KEYS=""
  local ref schema table sv tv
  for P in CM_OLD CM_NEW; do
    sv="${P}_SCHEMA"; tv="${P}_TABLE"; schema="${!sv:-main}"; table="${!tv:-}"
    for col in "$schema" "$table"; do [[ "$col" =~ ^[A-Za-z0-9_]+$ ]] || die "${P}: schema and table must be letters, digits, _ only"; done
    attach_source "$P"; ref="${ALIAS}.\"${schema}\".\"${table}\""
    if [ -n "${CM_ASOF_COL:-}" ]; then
      printf -v "${P}_A_EXPR" '%s' "\"${CM_ASOF_COL}\""
      printf -v "${P}_WHERE" '%s' "WHERE \"${CM_ASOF_COL}\" <= (TIMESTAMPTZ '${PERIOD_TO}' AT TIME ZONE '${CM_ASOF_TZ}')"
    else
      printf -v "${P}_A_EXPR" '%s' "NULL"; printf -v "${P}_WHERE" '%s' ""
    fi
    printf -v "${P}_REF" '%s' "$ref"; printf -v "${P}_K_EXPR" '%s' "$CM_K_EXPR"
  done

  local SQL_BODY; SQL_BODY="$(render sql/40_cm.sql)"
  mkdir -p "$CM_REPORT_DIR"
  printf '%s' "$SQL_BODY" > "$CM_REPORT_DIR/generated_cm.sql"   # no connection strings in it
  local T; T="$(mktemp -d)"; chmod 700 "$T"
  printf '%s\n%s\n%s' "$ATTACH_SQL" "$(duck_settings)" "$SQL_BODY" > "$T/run.sql"
  rm -f "$CM_REPORT_DIR/cm_verdict.txt"
  local rc=0
  "$DUCKDB" -bail -f "$T/run.sql" || rc=$?
  rm -rf "$T"
  [ "$rc" -eq 0 ] || { echo "the CM comparison stopped with an error; nothing was written to the sources" >&2; return 2; }
  [ -s "$CM_REPORT_DIR/cm_verdict.txt" ] || die "no CM verdict was written"
  case "$(cut -d: -f1 "$CM_REPORT_DIR/cm_verdict.txt")" in
    IDENTICAL) return 0 ;; DIFFERENT) return 1 ;; "NOT COMPARABLE") return 3 ;; *) return 2 ;;
  esac
}

# ---- final output (FINAL_REPORT=yes, list mode): Word report + Excel sheets built from the report folder -----------
# Optional and read only: it reads REPORT_DIR and writes a NEW folder. A failure here only prints a message; the exit code is
# never changed by it. Needs python3 (standard library only, nothing to install). See scripts/make_final_report.py.
FINAL_REPORT="${FINAL_REPORT:-no}"; need_yesno FINAL_REPORT
make_final_report() {
  local PY out args=()
  PY="$(command -v python3 || command -v python || true)"
  if [ -z "$PY" ]; then echo "final report skipped: python3 was not found (the comparison itself is complete)" >&2; return 0; fi
  out="${FINAL_REPORT_DIR:-${REPORT_DIR%/}_FINAL_OUTPUT_RESULT}"
  need_path out
  local t="${FINAL_REPORT_TITLE:-NS Pivot Comparison}" a="${FINAL_REPORT_AUTHOR:-}"
  [[ "$t" =~ ^[A-Za-z0-9\ _-]+$ ]] || die "FINAL_REPORT_TITLE may hold letters, digits, space, _ and - only"
  [[ "$a" =~ ^[A-Za-z0-9\ ._-]*$ ]] || die "FINAL_REPORT_AUTHOR may hold letters, digits, space, . _ and - only"
  args=(--title "$t" --author "$a")
  local v f
  for v in NOTES COMMENTS FINGERPRINT; do
    f="FINAL_REPORT_${v}_FILE"; opt_path "$f"
    if [ -n "${!f:-}" ]; then
      [ -f "${!f}" ] || die "$f not found: ${!f}"
      args+=("--$(echo "$v" | tr 'A-Z' 'a-z')" "${!f}")
    fi
  done
  "$PY" "$TOOL_DIR/scripts/make_final_report.py" "$REPORT_DIR" "$out" "${args[@]}" \
    || echo "final report was not written (see the message above); the comparison itself is complete" >&2
  return 0
}

combine_rc() {  # $1 = KPI result code, $2 = CM result code -> overall exit code (a CM difference makes the run DIFFERENT)
  if [ "$1" -eq 2 ] || [ "$2" -eq 2 ]; then echo 2
  elif [ "$1" -eq 1 ] || [ "$2" -eq 1 ]; then echo 1
  elif [ "$1" -eq 3 ] || [ "$2" -eq 3 ]; then echo 3
  else echo 0; fi
}

# ---- manual mode ------------------------------------------------------------------------------------
if [ "$MODE" = manual ]; then
  FAMILY_TABLE=""
  rc=0; run_one || rc=$?
  if [ "$CM_COMPARE" = yes ]; then
    echo; echo "pivot-compare: CM comparison ${CM_OLD_SCHEMA}.${CM_OLD_TABLE} against ${CM_NEW_SCHEMA}.${CM_NEW_TABLE}"
    cmrc=0; run_cm "$REPORT_DIR/cm" || cmrc=$?
    rc="$(combine_rc "$rc" "$cmrc")"
  fi
  exit "$rc"
fi

# ---- list mode: the table pairs come from PAIRS_FILE (one comparison per line, one report folder per line) ----
# PAIRS_FILE is a CSV with the header  name,old_table,new_table,key_cols,info_cols  ; lists inside a field use ; (SITE_ID;CELL_ID).
# Everything else (sources, schemas, period, tolerance ...) comes from this config and is the same for every line.
if [ "$MODE" = list ]; then
  PAIRS_FILE="${PAIRS_FILE:-}"; need_path PAIRS_FILE; [ -f "$PAIRS_FILE" ] || die "PAIRS_FILE not found: $PAIRS_FILE"
  BASE="$REPORT_DIR"; mkdir -p "$BASE"
  echo "pivot-compare (list): $(($(wc -l < "$PAIRS_FILE") - 1)) table pairs from $PAIRS_FILE"
  echo "period (UTC): $PERIOD_FROM  to  $PERIOD_TO     report folder: $BASE"
  SUMMARY="$BASE/pairs_summary.csv"; echo "name,result,detail" > "$SUMMARY"
  N_RUN=0; N_DIFF=0; N_NC=0; N_ERR=0; N_IDENT=0
  while IFS=',' read -r name oldtbl newtbl keys infocols <&3; do
    name="${name//[$'\r\n ']/}"; [ -n "$name" ] || continue
    oldtbl="${oldtbl//[$'\r\n ']/}"; newtbl="${newtbl//[$'\r\n ']/}"; keys="${keys//[$'\r\n ']/}"; infocols="${infocols//[$'\r\n ']/}"
    [[ "$name" =~ ^[A-Za-z0-9_]+$ ]] || die "pairs file: name '$name' must be letters, digits and _ only"
    N_RUN=$((N_RUN+1))
    set +e
    ( set -e
      FAMILY_TABLE=""; OLD_TABLE="$oldtbl"; NEW_TABLE="$newtbl"; REPORT_DIR="$BASE/$name"
      OLD_KEY_COLS="${keys//;/,}"; NEW_KEY_COLS="${keys//;/,}"
      if [ -n "$infocols" ]; then INFO_COLS="${infocols//;/,}"; INFO_COMPARE=yes; fi
      build_info
      run_one > "$BASE/$name.screen.txt" 2>&1 ) < /dev/null
    rc=$?
    set -e
    detail="$( [ -s "$BASE/$name/verdict.txt" ] && cat "$BASE/$name/verdict.txt" || echo "no verdict (see $BASE/$name.screen.txt)" )"
    case "$rc" in
      0) res=IDENTICAL; N_IDENT=$((N_IDENT+1)) ;; 1) res=DIFFERENT; N_DIFF=$((N_DIFF+1)) ;; 3) res="NOT COMPARABLE"; N_NC=$((N_NC+1)) ;;
      *) res=ERROR; N_ERR=$((N_ERR+1)) ;;
    esac
    printf '%s,%s,"%s"\n' "$name" "$res" "${detail//\"/\'}" >> "$SUMMARY"
    printf '  %-16s %s\n' "$name" "$res"
    printf '      %s\n' "$detail" | cut -c1-260
  done 3< <(tail -n +2 "$PAIRS_FILE")   # the first line is the header
  echo
  echo "pairs: $N_RUN   identical: $N_IDENT   different: $N_DIFF   not comparable: $N_NC   errors: $N_ERR"
  echo "summary: $SUMMARY     details per pair: $BASE/<name>/"
  if [ "$FINAL_REPORT" = yes ]; then   # in a subshell: a wrong FINAL_REPORT_* setting stops only the report, never the result
    ( REPORT_DIR="$BASE"; make_final_report ) || echo "final report not written (see the message above); the comparison itself is complete" >&2
  fi
  if [ "$N_ERR" -gt 0 ]; then exit 2
  elif [ "$N_DIFF" -gt 0 ]; then exit 1
  elif [ "$N_RUN" -eq 0 ] || [ "$N_NC" -gt 0 ]; then exit 3
  else exit 0; fi
fi

# ---- auto mode: find the families from the KPI definitions, compare each one ----------------------------
BASE="$REPORT_DIR"; mkdir -p "$BASE"
ATTACH_SQL=""; ATTACHED_KEYS=""
attach_source DEF; DEF_ALIAS="$ALIAS"
attach_source OLD; OLD_ALIAS="$ALIAS"
OLD_SCHEMA_V="${OLD_SCHEMA:-main}"; [[ "$OLD_SCHEMA_V" =~ ^[A-Za-z0-9_]+$ ]] || die "OLD_SCHEMA must be letters, digits, _ only"
DEF_REF="${DEF_ALIAS}.\"${DEF_SCHEMA}\".\"${DEF_TABLE}\""
if [ "$AUTO_APPLICATIONS" = ALL ]; then APP_WHERE=""
else APP_WHERE="WHERE trim(\"${DEF_COL_APPLICATION}\") IN ('${AUTO_APPLICATIONS//,/\',\'}')"; fi
export BASE OLD_ALIAS OLD_SCHEMA_V DEF_REF APP_WHERE

T0="$(mktemp -d)"; chmod 700 "$T0"; trap 'rm -rf "$T0"' EXIT
{ printf '%s\n%s\n' "$ATTACH_SQL" "$(duck_settings)"; render sql/05_families.sql; } > "$T0/families.sql"
echo "pivot-compare (auto): finding the pivot tables from ${DEF_SCHEMA}.${DEF_TABLE} for applications: ${AUTO_APPLICATIONS}"
rm -f "$BASE/families.txt"
"$DUCKDB" -bail -f "$T0/families.sql" || { echo "could not read the KPI definitions" >&2; exit 2; }
[ -f "$BASE/families.txt" ] || die "no families file was written"
echo "period (UTC): $PERIOD_FROM  to  $PERIOD_TO     report folder: $BASE"

SUMMARY="$BASE/families_summary.csv"
echo "family,result,detail" > "$SUMMARY"
N_FAM=0; N_RUN=0; N_DIFF=0; N_NC=0; N_ERR=0; N_SKIP=0
while IFS='|' read -r fam oldtbl app nk <&3; do
  [ -n "$fam" ] || continue
  [[ "$fam" =~ ^[A-Za-z0-9_]+$ ]] || die "unexpected family name '$fam'"
  case "$app" in *\'*|*\"*) die "unexpected application name '$app'";; esac
  N_FAM=$((N_FAM+1))
  if [ -z "$oldtbl" ]; then
    N_SKIP=$((N_SKIP+1)); echo "$fam,SKIPPED,no old table with this name (${nk} KPIs defined)" >> "$SUMMARY"
    printf '  %-58s %s\n' "$fam" "SKIPPED (no old table; $nk KPIs defined)"; continue
  fi
  N_RUN=$((N_RUN+1))
  set +e
  ( set -e
    OLD_TABLE="$oldtbl"; FAMILY_TABLE="$fam"; FAMILY_KPIS_FILE="$BASE/family_kpis.csv"; REPORT_DIR="$BASE/$fam"
    [ -z "${NEW_FILTER_COL:-}" ] || NEW_FILTER_VALUE="$app"
    run_one ) < /dev/null
  rc=$?
  set -e
  detail="$( [ -s "$BASE/$fam/verdict.txt" ] && cat "$BASE/$fam/verdict.txt" || echo "no verdict (see the error above)" )"
  case "$rc" in
    0) res=IDENTICAL ;; 1) res=DIFFERENT; N_DIFF=$((N_DIFF+1)) ;; 3) res="NOT COMPARABLE"; N_NC=$((N_NC+1)) ;;
    *) res=ERROR; N_ERR=$((N_ERR+1)) ;;
  esac
  printf '%s,%s,"%s"\n' "$fam" "$res" "${detail//\"/\'}" >> "$SUMMARY"
  printf '  %-58s %s\n' "$fam" "$res"
  printf '      %s\n' "$detail"
done 3< "$BASE/families.txt"

echo
echo "families found: $N_FAM   compared: $N_RUN   skipped (no old table): $N_SKIP   different: $N_DIFF   not comparable: $N_NC   errors: $N_ERR"
echo "summary: $SUMMARY     details per family: $BASE/<family>/"
if [ "$N_ERR" -gt 0 ]; then rc=2
elif [ "$N_DIFF" -gt 0 ]; then rc=1
elif [ "$N_RUN" -eq 0 ] || [ "$N_NC" -gt 0 ]; then rc=3
else rc=0; fi
if [ "$CM_COMPARE" = yes ]; then
  echo; echo "pivot-compare: CM comparison ${CM_OLD_SCHEMA}.${CM_OLD_TABLE} against ${CM_NEW_SCHEMA}.${CM_NEW_TABLE}"
  cmrc=0; run_cm "$BASE/cm" || cmrc=$?
  rc="$(combine_rc "$rc" "$cmrc")"
fi
exit "$rc"
