#!/usr/bin/env bash
# One-time migration COUNTER_DEF -> COUNTER_DEF_V2. Needs bash and psql (10+).
#
#   ./migrate.sh --dry-run <dev|uat|prod>   run everything and the checks, then ROLLBACK
#   ./migrate.sh <dev|uat|prod>             run, and COMMIT only if every check passes
#
# Settings: migrate.conf (shared), then env/<env>.conf (that environment's
# values) on top. A path to a .conf file can be given instead of an env name.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN=false
ENV_CONF=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        dev|uat|prod) ENV_CONF="$HERE/env/$arg.conf" ;;
        *) ENV_CONF="$arg" ;;
    esac
done

[ -n "$ENV_CONF" ] || { echo "ERROR: name the environment: ./migrate.sh [--dry-run] <dev|uat|prod>" >&2; exit 2; }
for conf in "$HERE/migrate.conf" "$ENV_CONF"; do
    [ -f "$conf" ] || { echo "ERROR: config not found: $conf" >&2; exit 2; }
    # shellcheck source=migrate.conf
    source "$conf"
done
ENV_NAME="$(basename "$ENV_CONF" .conf)"
if grep -q 'REPLACE_WITH' <<< "$PG_HOST$PG_USER"; then
    echo "ERROR: set PG_HOST and PG_USER in $ENV_CONF" >&2; exit 2
fi
command -v psql >/dev/null || { echo "ERROR: psql not found on PATH" >&2; exit 2; }

# Comma lists without spaces or line breaks.
squash() { printf '%s' "$1" | tr -d ' \t\r\n'; }
COPY_COLUMNS="$(squash "$COPY_COLUMNS")"
VENDORS="$(squash "$VENDORS")"
MEASUREMENT_PREFIX_VENDORS="$(squash "$MEASUREMENT_PREFIX_VENDORS")"
ERS_COUNTER_DEF_VENDORS="$(squash "$ERS_COUNTER_DEF_VENDORS")"
FILL_NULL_WITH_RUN_TIME="$(squash "$FILL_NULL_WITH_RUN_TIME")"
TIME_RESOLUTION_MAP="$(squash "$TIME_RESOLUTION_MAP")"

# COUNTER_DEF_V2 must not be one of the source tables (checked again in the
# database, by object, before anything is written).
V2="$COUNTER_DEF_V2_SCHEMA.$COUNTER_DEF_V2_TABLE"
for src in "$COUNTER_DEF_SCHEMA.$COUNTER_DEF_TABLE" "$MEASUREMENT_DEF_SCHEMA.$MEASUREMENT_DEF_TABLE" \
           "$ERS_COUNTER_DEF_SCHEMA.$ERS_COUNTER_DEF_TABLE"; do
    if [ "${V2,,}" = "${src,,}" ]; then
        echo "ERROR: COUNTER_DEF_V2 ($V2) is a source table: refusing to run" >&2; exit 2
    fi
done

# Source column of a destination column in COPY_COLUMNS ("" if not mapped).
source_of() {
    local pair
    IFS=',' read -ra pairs <<< "$COPY_COLUMNS"
    for pair in "${pairs[@]}"; do
        if [ "${pair%%=*}" = "$1" ]; then
            if [[ "$pair" == *=* ]]; then printf '%s' "${pair#*=}"; else printf '%s' "$pair"; fi
            return
        fi
    done
}
SRC_ID="$(source_of COUNTER_ID)"
SRC_VENDOR="$(source_of VENDOR)"
SRC_MEAS="$(source_of MEASUREMENT_ID)"
SRC_ENABLED="$(source_of ENABLED)"
SRC_TRES="$(source_of TIME_RESOLUTION)"
SRC_MOCN="$(source_of MOCN_NAME)"
for need in SRC_ID SRC_VENDOR SRC_MEAS; do
    [ -n "${!need}" ] || { echo "ERROR: COPY_COLUMNS must map COUNTER_ID, VENDOR and MEASUREMENT_ID" >&2; exit 2; }
done
for derived in COUNTER_NAME ATTRIBUTES SUB_COUNTER; do
    [ -z "$(source_of "$derived")" ] || { echo "ERROR: $derived is derived; remove it from COPY_COLUMNS" >&2; exit 2; }
done
TRES_MAP_ON=false
if [ -n "$TIME_RESOLUTION_MAP" ]; then
    [ -n "$SRC_TRES" ] || { echo "ERROR: TIME_RESOLUTION_MAP is set but COPY_COLUMNS has no TIME_RESOLUTION" >&2; exit 2; }
    TRES_MAP_ON=true
fi

# Expressions for the optional source columns (identifiers double-quoted).
if [ -n "$SRC_ENABLED" ]; then ENABLED_EXPR="trim(c.\"$SRC_ENABLED\"::text)"; else ENABLED_EXPR="NULL::text"; fi
if [ -n "$SRC_MOCN" ]; then MOCN_EXPR="NULLIF(trim(c.\"$SRC_MOCN\"::text), '')"; else MOCN_EXPR="NULL::text"; fi
if [ -n "$COUNTER_DEF_ATTRIBUTES_COLUMN" ]; then
    ATTRS_EXPR="COALESCE(NULLIF(trim(c.\"$COUNTER_DEF_ATTRIBUTES_COLUMN\"::text), '')::jsonb, '{}'::jsonb)"
else
    ATTRS_EXPR="'{}'::jsonb"
fi

RUN_DIR="$REPORT_DIR/$(date +%Y%m%d_%H%M%S)_$ENV_NAME$( $DRY_RUN && echo _dry-run || true )"
mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
[ -n "$PG_TIMEZONE" ] && export PGTZ="$PG_TIMEZONE"

echo "COUNTER_DEF -> COUNTER_DEF_V2 migration"
echo "  env      : $ENV_NAME ($ENV_CONF)"
echo "  database : $PG_USER@$PG_HOST:$PG_PORT/$PG_DATABASE"
echo "  source   : $COUNTER_DEF_SCHEMA.$COUNTER_DEF_TABLE  (vendors: ${VENDORS:-all}), read only"
echo "  target   : $V2  (drop existing: $DROP_EXISTING_COUNTER_DEF_V2)"
echo "  mode     : $( $DRY_RUN && echo 'DRY RUN (rolled back)' || echo 'LIVE (commit if all checks pass)' )"
echo "  reports  : $RUN_DIR"
echo

# psql writes the CSV reports into its working directory.
set +e
(
    cd "$RUN_DIR" && psql -X -q -v ON_ERROR_STOP=1 -P pager=off \
        -h "$PG_HOST" -p "$PG_PORT" -d "$PG_DATABASE" -U "$PG_USER" \
        -v src_schema="$COUNTER_DEF_SCHEMA" -v src_table="$COUNTER_DEF_TABLE" \
        -v src_id="$SRC_ID" -v src_vendor="$SRC_VENDOR" -v src_meas="$SRC_MEAS" -v src_tres="$SRC_TRES" \
        -v src_name="$COUNTER_DEF_NAME_COLUMN" -v enabled_expr="$ENABLED_EXPR" -v mocn_expr="$MOCN_EXPR" -v attrs_expr="$ATTRS_EXPR" \
        -v vendors="$VENDORS" -v prefix_vendors="$MEASUREMENT_PREFIX_VENDORS" -v array_vendors="$ERS_COUNTER_DEF_VENDORS" \
        -v meas_schema="$MEASUREMENT_DEF_SCHEMA" -v meas_table="$MEASUREMENT_DEF_TABLE" \
        -v array_schema="$ERS_COUNTER_DEF_SCHEMA" -v array_table="$ERS_COUNTER_DEF_TABLE" \
        -v dst_schema="$COUNTER_DEF_V2_SCHEMA" -v dst_table="$COUNTER_DEF_V2_TABLE" \
        -v dst_sequence="$COUNTER_DEF_V2_SEQUENCE" -v dst_index="$COUNTER_DEF_V2_INDEX" \
        -v drop_existing="$DROP_EXISTING_COUNTER_DEF_V2" -v dry_run="$DRY_RUN" \
        -v tres_map="$TIME_RESOLUTION_MAP" -v tres_map_on="$TRES_MAP_ON" \
        -v copy_columns="$COPY_COLUMNS" -v fill_null_columns="$FILL_NULL_WITH_RUN_TIME" \
        -f "$HERE/migrate.sql"
) 2>&1 | tee "$RUN_DIR/migrate.log"
rc=${PIPESTATUS[0]}
set -e

echo
if [ "$rc" -ne 0 ]; then
    echo "RESULT: FAILED (psql exit $rc). Nothing was committed. See $RUN_DIR/migrate.log"
    exit 1
fi
if $DRY_RUN; then
    echo "RESULT: DRY RUN OK. All checks passed; nothing was committed."
else
    echo "RESULT: SUCCESS. Migration committed; all checks passed."
fi
echo "Reports: $RUN_DIR"
