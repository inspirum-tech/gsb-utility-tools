#!/usr/bin/env bash
# Compares an OLD pivot table with a NEW one (or the new calculator's tall table) for the same periods.
# Read only on both sources; the only things written are the report files in REPORT_DIR.
#   ./run.sh [config-file]        default config file: config.env
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
need_list()   { [[ "${!1:-}" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] || die "$1 must be names separated by commas (letters, digits, _)"; }
need_number() { [[ "${!1:-}" =~ ^[0-9]+(\.[0-9]+)?([eE]-?[0-9]+)?$ ]] || die "$1 must be a non-negative number (got '${!1:-}')"; }
need_signed() { [[ "${!1:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || die "$1 must be a number (got '${!1:-}')"; }
need_yesno()  { [[ "${!1:-}" =~ ^(yes|no)$ ]] || die "$1 must be yes or no (got '${!1:-}')"; }
need_ts()     { [[ "${!1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[\ T][0-9:.]+(Z|[+-][0-9:]{2,5})?$ ]] || die "$1 must look like 2025-12-19 09:00:00+00 (got '${!1:-}')"; }
need_tz()     { [[ "${!1:-}" =~ ^[A-Za-z0-9_/+-]+$ ]] || die "$1 must be a time zone name such as Australia/Sydney or UTC"; }
need_path()   { [[ "${!1:-}" =~ ^[A-Za-z0-9_./-]+$ ]] || die "$1 must use letters, digits and _ . / - only"; }
opt_path()    { [ -z "${!1:-}" ] || need_path "$1"; }
need_regex()  { case "${!1:-}" in ''|*\'*|*\"*|*\;*|*--*|*$'\n'*) die "$1 must be a regular expression without quotes, ; or --";; esac; }

need_ts PERIOD_FROM; need_ts PERIOD_TO
for v in TOLERANCE_ABS TOLERANCE_REL FLOAT_SLACK; do need_number "$v"; done
need_signed SPECIAL_DEFAULT
for v in SPECIAL_AS_DEFAULT NULL_AS_DEFAULT FAIL_ON_OBJECTS_ONE_SIDE FAIL_ON_KPI_COLUMNS_ONE_SIDE FAIL_ON_NULL_ONE_SIDE; do need_yesno "$v"; done
need_regex KPI_REGEX
opt_path KPI_LIST_FILE; opt_path KPI_MAP_FILE; need_path REPORT_DIR; opt_path TEMP_DIR; need_path ENV_FILE
[[ "$MAX_DIFF_ROWS" =~ ^[0-9]+$ ]] || die "MAX_DIFF_ROWS must be a whole number"
[ -z "${THREADS:-}" ] || [[ "$THREADS" =~ ^[0-9]+$ ]] || die "THREADS must be a whole number"
[ -z "${MEMORY_LIMIT:-}" ] || [[ "$MEMORY_LIMIT" =~ ^[0-9]+(\.[0-9]+)?[A-Za-z]*$ ]] || die "MEMORY_LIMIT must look like 8GB"
[ -z "${KPI_LIST_FILE}" ] || [ -f "$KPI_LIST_FILE" ] || die "KPI_LIST_FILE not found: $KPI_LIST_FILE"
[ -z "${KPI_MAP_FILE}" ] || [ -f "$KPI_MAP_FILE" ] || die "KPI_MAP_FILE not found: $KPI_MAP_FILE"
command -v "$DUCKDB" >/dev/null 2>&1 || [ -x "$DUCKDB" ] || die "DuckDB CLI not found (DUCKDB=$DUCKDB)"

# ---- per side: build the pieces the SQL templates need --------------------------------------------
ATTACH_SQL=""      # holds connection strings: never printed, never written to the report folder
ATTACHED_KEYS=""   # "key=alias;" pairs, so two sides that use the same database attach it once

dsn_of() {  # $1 = name of the variable or the ENV_FILE key
  local name="$1" dsn="${!1:-}"
  if [ -z "$dsn" ] && [ -f "$ENV_FILE" ]; then
    dsn="$(grep "^${name}=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' || true)"
  fi
  [ -n "$dsn" ] || die "no connection string: set the environment variable $name or the line $name=... in $ENV_FILE"
  printf '%s' "$dsn"
}

prep_side() {  # $1 = OLD or NEW
  local P="$1" side; side="$(echo "$P" | tr 'A-Z' 'a-z')"
  local v src shape kind alias key
  v() { local n="${P}_$1"; printf '%s' "${!n:-}"; }
  src="$(v SOURCE)"; shape="$(v SHAPE)"; kind="$(v PERIOD_KIND)"
  case "$src" in postgres|attached|duckdb) ;; *) die "${P}_SOURCE must be postgres, attached or duckdb";; esac
  case "$shape" in wide|tall) ;; *) die "${P}_SHAPE must be wide or tall";; esac
  case "$kind" in local|tz) ;; *) die "${P}_PERIOD_KIND must be local or tz";; esac
  local schema table pcol; schema="$(v SCHEMA)"; table="$(v TABLE)"; pcol="$(v PERIOD_COL)"
  [ -n "$schema" ] || schema=main
  for n in "$schema" "$table" "$pcol"; do [[ "$n" =~ ^[A-Za-z0-9_]+$ ]] || die "${P}: schema, table and period column must be letters, digits, _ only"; done
  local keys; keys="$(v KEY_COLS)"
  [[ "$keys" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] || die "${P}_KEY_COLS must be names separated by commas"
  local tz; tz="$(v PERIOD_TZ)"; [ "$kind" = tz ] || { [[ "$tz" =~ ^[A-Za-z0-9_/+-]+$ ]] || die "${P}_PERIOD_TZ must be a time zone name"; }

  # where the table lives
  case "$src" in
    postgres)
      local envname; envname="$(v DSN_ENV)"; [[ "$envname" =~ ^[A-Za-z0-9_]+$ ]] || die "${P}_DSN_ENV must be a variable name"
      key="pg:$envname"
      ;;
    duckdb)
      local f; f="$(v DB_FILE)"; [[ "$f" =~ ^[A-Za-z0-9_./-]+$ ]] || die "${P}_DB_FILE must be a path (letters, digits, _ . / -)"
      [ -f "$f" ] || die "${P}_DB_FILE not found: $f"
      key="db:$f"
      ;;
    attached)
      local c; c="$(v CATALOG)"; [[ "$c" =~ ^[A-Za-z0-9_]+$ ]] || die "${P}_CATALOG must be a catalog name"
      key="cat:$c"
      ;;
  esac
  case ";$ATTACHED_KEYS" in
    *";$key="*) alias="$(printf '%s' "$ATTACHED_KEYS" | tr ';' '\n' | grep -F "$key=" | head -1 | cut -d= -f2-)" ;;
    *)
      case "$src" in
        postgres)
          alias="cmp_pg_$side"; local dsn; dsn="$(dsn_of "$envname")"
          ATTACH_SQL+="INSTALL postgres; LOAD postgres;"$'\n'"ATTACH '${dsn//\'/\'\'}' AS ${alias} (TYPE postgres, READ_ONLY);"$'\n' ;;
        duckdb)
          alias="cmp_db_$side"; ATTACH_SQL+="ATTACH '${f}' AS ${alias} (READ_ONLY);"$'\n' ;;
        attached) alias="$c" ;;
      esac
      ATTACHED_KEYS+="$key=$alias;" ;;
  esac

  # key expression: the key columns as text joined with |, NULL shown as <NULL>
  local kexpr="" col IFS_OLD="$IFS"; IFS=','
  for col in $keys; do
    [ -z "$kexpr" ] || kexpr+=" || '|' || "
    kexpr+="coalesce(CAST(\"$col\" AS VARCHAR), '<NULL>')"
  done
  IFS="$IFS_OLD"
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
  fi
  export SIDE REF K_EXPR PER_COL P_EXPR FROM_NATIVE TO_NATIVE FILTER_SQL SIDE_KPI_REGEX SIDE_PREFIX KPI_COL_Q VALUE_COL_Q
}

render() {  # replaces ${NAME} in a template with the variables prepared above (values are not re-expanded)
  eval "cat <<__PIVOT_COMPARE_SQL__
$(cat "$1")
__PIVOT_COMPARE_SQL__"
}

SQL_BODY=""
KEYS_OLD=""
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
if [ -n "$KPI_LIST_FILE" ]; then
  KPI_ALLOWED_SELECT="SELECT trim(kpi) AS kpi FROM read_csv('$KPI_LIST_FILE', header = false, columns = {'kpi': 'VARCHAR'}) WHERE trim(kpi) <> ''"
else
  KPI_ALLOWED_SELECT="SELECT kpi FROM old_cols UNION SELECT kpi FROM new_cols"
fi
export KPI_MAP_SQL KPI_ALLOWED_SELECT DUP_THRESHOLD_OLD DUP_THRESHOLD_NEW
SQL_BODY+="$(render sql/20_compare.sql)"$'\n'
SQL_BODY+="$(render sql/30_report.sql)"$'\n'

SETTINGS=""
[ -z "${MEMORY_LIMIT:-}" ] || SETTINGS+="SET memory_limit = '$MEMORY_LIMIT';"$'\n'
[ -z "${TEMP_DIR:-}" ]     || SETTINGS+="SET temp_directory = '$TEMP_DIR';"$'\n'
[ -z "${THREADS:-}" ]      || SETTINGS+="SET threads = $THREADS;"$'\n'

mkdir -p "$REPORT_DIR"
printf '%s' "$SQL_BODY" > "$REPORT_DIR/generated.sql"   # no connection strings in it
cp "$CONFIG" "$REPORT_DIR/config_used.env"

TMPDIR_RUN="$(mktemp -d)"; chmod 700 "$TMPDIR_RUN"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
printf '%s\n%s\n%s' "$ATTACH_SQL" "$SETTINGS" "$SQL_BODY" > "$TMPDIR_RUN/run.sql"

echo "pivot-compare: ${OLD_TABLE} (${OLD_SHAPE}, ${OLD_SOURCE}) against ${NEW_TABLE} (${NEW_SHAPE}, ${NEW_SOURCE})"
echo "period (UTC): $PERIOD_FROM  to  $PERIOD_TO     report folder: $REPORT_DIR"
rm -f "$REPORT_DIR/verdict.txt"
"$DUCKDB" -bail -f "$TMPDIR_RUN/run.sql" || { echo "the comparison stopped with an error; nothing was written to the sources" >&2; exit 2; }

[ -s "$REPORT_DIR/verdict.txt" ] || die "no verdict was written"
case "$(cut -d: -f1 "$REPORT_DIR/verdict.txt")" in
  IDENTICAL) exit 0 ;;
  DIFFERENT) exit 1 ;;
  "NOT COMPARABLE") exit 3 ;;
  *) exit 2 ;;
esac
