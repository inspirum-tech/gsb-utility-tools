#!/usr/bin/env bash
# export-period.sh - PROD side, READ ONLY: write tables of one period (or whole, FULL_COPY_TABLES) from a
# DuckLake / Postgres / DuckDB source into a folder that can be carried to another environment and loaded
# there with db-import.sh (SOURCE_TYPE="export").
#
#   ./export-period.sh [--check] <config.env>
#
#   --check   read only and writes nothing: connects, lists the tables, their columns and partitioning
#
# For each table <EXPORT_DIR>/<TABLE>/ gets:
#   data/data_N.parquet   the rows (zstd; NOT hive-partitioned, so every column stays in the file)
#   columns.tsv           column name, type, nullable, in table order (from the source catalog)
#   table.meta            source schema / table, mode (window | full), time column, period, time zone,
#                         rows written, partitioning (DuckLake: e.g. year("T"), month("T"), day("T")), versions
#   _DONE                 written last: a table folder without it is incomplete
# and <EXPORT_DIR>/MANIFEST.sha256 covers every file (check it after the transfer: sha256sum -c).
#
# The source is attached READ_ONLY; each table is read in one transaction (one consistent snapshot).
# A run that stopped is started again: tables with _DONE for the same period are kept, the others redone.
# Config: the same file style as db-import.sh (SOURCE_*, SOURCE_SCHEMA, TABLES, PERIOD_FROM, PERIOD_TO,
# TIMEZONE, TIME_COLUMN, TABLE_TIME_COLUMNS, FULL_COPY_TABLES, DUCKDB, DUCKDB_EXTENSION_DIR, OFFLINE) plus
# EXPORT_DIR (required), EXPORT_OVERWRITE (yes = redo every table) and EXPORT_FILE_MB (size of one file).
# The TARGET_* settings are not used. "SOURCE=TARGET" in TABLES: only the source name is used here.
set -euo pipefail
EXP_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=db-import.sh
source "$EXP_HERE/db-import.sh"          # helpers only (its main runs only when executed directly)

EXPORT_FORMAT="db-import-export/1"

exp_validate() {
    validate_side SOURCE
    case "$SOURCE_TYPE" in ducklake|postgres|duckdb) ;; *) die "export-period.sh reads SOURCE_TYPE ducklake, postgres or duckdb; got '$SOURCE_TYPE'";; esac
    [ -n "$EXPORT_DIR" ] || die "EXPORT_DIR is not set (the folder the export is written to)"
    check_re EXPORT_DIR "$EXPORT_DIR" "$re_path"
    [[ "$EXPORT_FILE_MB" =~ ^[1-9][0-9]*$ ]] || die "EXPORT_FILE_MB must be a whole number of 1 or more"
    case "$EXPORT_OVERWRITE" in yes|no) ;; *) die "EXPORT_OVERWRITE must be yes or no";; esac
    case "$OFFLINE" in yes|no) ;; *) die "OFFLINE must be yes or no";; esac
    [ -z "$DUCKDB_EXTENSION_DIR" ] || check_re DUCKDB_EXTENSION_DIR "$DUCKDB_EXTENSION_DIR" "$re_path"
    check_re TIME_COLUMN "$TIME_COLUMN" "$re_ident"
    check_re TIMEZONE "$TIMEZONE" '^[A-Za-z0-9_/+-]+$'
    FROM_TS="$(norm_ts "$PERIOD_FROM")" || die "PERIOD_FROM '$PERIOD_FROM' is not valid. Use YYYY-MM-DD or YYYY-MM-DD HH:MM[:SS]"
    TO_TS="$(norm_ts "$PERIOD_TO")"     || die "PERIOD_TO '$PERIOD_TO' is not valid. Use YYYY-MM-DD or YYYY-MM-DD HH:MM[:SS]"
    [[ "$FROM_TS" < "$TO_TS" ]] || die "PERIOD_FROM ($FROM_TS) must be earlier than PERIOD_TO ($TO_TS)"
    parse_tables
    TARGET_TYPE=""                      # nothing is attached for writing
}

exp_columns() { # table -> lines "COL<TAB>name<TAB>type<TAB>nullable" from the source catalog
    duck_run "$(duck_head)
SELECT 'COL' || chr(9) || column_name || chr(9) || data_type || chr(9) || is_nullable
FROM information_schema.columns
WHERE table_catalog = 'src' AND table_schema = '$(sqlq "$SOURCE_SCHEMA")' AND table_name = '$(sqlq "$1")'
ORDER BY ordinal_position;"
}

exp_partition() { # table -> DuckLake partition expressions, e.g. year("T"), month("T"), day("T"); empty = none / not DuckLake
    [ "$SOURCE_TYPE" = ducklake ] || return 0
    local m="__ducklake_metadata_src.\"$(v SOURCE_DUCKLAKE_METADATA_SCHEMA)\"" out
    out="$(duck_run "$(duck_head)
SELECT 'PART,' || pc.transform || ',' || c.column_name
FROM $m.ducklake_table t
JOIN $m.ducklake_schema s ON s.schema_id = t.schema_id AND s.end_snapshot IS NULL
JOIN $m.ducklake_partition_info pi ON pi.table_id = t.table_id AND pi.end_snapshot IS NULL
JOIN $m.ducklake_partition_column pc ON pc.partition_id = pi.partition_id AND pc.table_id = t.table_id
JOIN $m.ducklake_column c ON c.table_id = t.table_id AND c.column_id = pc.column_id AND c.end_snapshot IS NULL
WHERE t.end_snapshot IS NULL AND s.schema_name = '$(sqlq "$SOURCE_SCHEMA")' AND t.table_name = '$(sqlq "$1")'
ORDER BY pc.partition_key_index;" 2>&1)" || { warn "$1: could not read its partitioning from the DuckLake catalog ($(tail -1 <<<"$out")); the export has none recorded"; return 0; }
    local line tr col parts=()
    while IFS=, read -r line tr col; do
        [ "$line" = PART ] || continue
        if [ "$tr" = identity ]; then parts+=("\"$col\""); else parts+=("$tr(\"$col\")"); fi
    done <<<"$out"
    local IFS=','; local joined="${parts[*]}"; printf '%s' "${joined//,/, }"
}

exp_meta_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

exp_table() { # i -> exports one table; prints a status line
    local i="$1" t="${SRC_T[$1]}" dir="$EXPORT_DIR/${SRC_T[$1]}" tmp="$EXPORT_DIR/.${SRC_T[$1]}.tmp"
    local mode=window where="" tc; tc="$(tcol_for "$t")"
    if [ -f "$dir/_DONE" ] && [ "$EXPORT_OVERWRITE" = no ]; then
        if [ "$(exp_meta_get "$dir/table.meta" period_from)" = "$FROM_TS" ] && [ "$(exp_meta_get "$dir/table.meta" period_to)" = "$TO_TS" ] \
           && [ "$(exp_meta_get "$dir/table.meta" timezone)" = "$TIMEZONE" ]; then
            log "    $t: kept from an earlier run ($(exp_meta_get "$dir/table.meta" rows) rows)"; EXP_ROWS[$i]="$(exp_meta_get "$dir/table.meta" rows)"; return 0
        fi
        die "$dir holds an export of another period. Use another EXPORT_DIR, or EXPORT_OVERWRITE=\"yes\""
    fi
    local cols; cols="$(exp_columns "$t")" || die "cannot read the columns of $SOURCE_SCHEMA.$t (see the error above)"
    [ -n "$cols" ] || die "source table $SOURCE_SCHEMA.$t does not exist (or has no columns)"
    local c bad=0; while IFS=$'\t' read -r _ c _ _; do bad_col "$c" && { echo "ERROR: $t: column name '$c' is not supported" >&2; bad=1; }; done <<<"$cols"
    [ "$bad" = 0 ] || die "unsupported column names in $t"
    if in_list "$t" "$FULL_COPY_TABLES"; then
        mode=full
    else
        cut -f2 <<<"$cols" | grep -qxF -- "$tc" \
            || die "$t has no column $tc. Add it to FULL_COPY_TABLES to export it whole, or set TABLE_TIME_COLUMNS=$t:<column>"
        where="WHERE \"$tc\" >= TIMESTAMP '$FROM_TS' AND \"$tc\" < TIMESTAMP '$TO_TS'"
    fi
    local part; part="$(exp_partition "$t")"
    [ "$CHECK_ONLY" = no ] || { log "    $t: $(grep -c . <<<"$cols") columns, $mode$([ "$mode" = window ] && echo " on $tc"), partitioning: ${part:-none}"; return 0; }

    rm -rf "$tmp"; mkdir -p "$tmp"
    local start=$SECONDS out
    out="$(duck_run "$(duck_head)
BEGIN TRANSACTION READ ONLY;
COPY (SELECT * FROM $(tbl_expr SOURCE "$t") $where) TO '$(sqlq "$tmp/data")' (FORMAT parquet, COMPRESSION zstd, FILE_SIZE_BYTES '${EXPORT_FILE_MB}MB');
COMMIT;
SELECT 'ROWS,' || count(*) FROM read_parquet('$(sqlq "$tmp/data")/*.parquet');")" \
        || { rm -rf "$tmp"; die "export of $SOURCE_SCHEMA.$t failed (see the error above). Nothing of it was kept"; }
    local rows; rows="$(grep -m1 '^ROWS,' <<<"$out" | cut -d, -f2)"
    [[ "$rows" =~ ^[0-9]+$ ]] || { rm -rf "$tmp"; die "export of $t: the written files could not be read back"; }
    printf 'name\ttype\tnullable\n' >"$tmp/columns.tsv"
    cut -f2- <<<"$cols" >>"$tmp/columns.tsv"
    {
        echo "format=$EXPORT_FORMAT"
        echo "source=$(side_fingerprint SOURCE)"
        echo "source_type=$SOURCE_TYPE"
        echo "source_schema=$SOURCE_SCHEMA"
        echo "table=$t"
        echo "mode=$mode"
        echo "time_column=$([ "$mode" = window ] && echo "$tc")"
        echo "period_from=$FROM_TS"
        echo "period_to=$TO_TS"
        echo "timezone=$TIMEZONE"
        echo "rows=$rows"
        echo "files=$(find "$tmp/data" -name '*.parquet' | wc -l)"
        echo "partition=$part"
        echo "duckdb=$(duck_version_of "$DUCK_BIN")"
        echo "exported_at=$(date '+%Y-%m-%d %H:%M:%S %z')"
    } >"$tmp/table.meta"
    date '+%Y-%m-%d %H:%M:%S %z' >"$tmp/_DONE"
    rm -rf "$dir"; mv "$tmp" "$dir"                  # a table folder is either complete (with _DONE) or absent
    EXP_ROWS[$i]="$rows"
    log "    $t: $rows rows, $(exp_meta_get "$dir/table.meta" files) file(s), $(du -sh "$dir/data" | cut -f1), $((SECONDS - start))s, partitioning: ${part:-none}"
}

exp_main() {
    CONF=""; CHECK_ONLY=no
    local a
    for a in "$@"; do
        case "$a" in
            --check) CHECK_ONLY=yes ;;
            -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
            -*) die "unknown option $a" ;;
            *) CONF="$a" ;;
        esac
    done
    [ -n "$CONF" ] || die "name the config file: ./export-period.sh [--check] <config.env>"
    load_config
    : "${EXPORT_FILE_MB:=512}"
    exp_validate
    mkdir -p "$EXPORT_DIR"
    exec > >(tee -a "$EXPORT_DIR/export.log") 2>&1
    log "export-period job '$JOB_NAME': $SOURCE_TYPE $(side_fingerprint SOURCE) schema $SOURCE_SCHEMA (READ ONLY) -> $EXPORT_DIR"
    log "period: $FROM_TS  <=  time column  <  $TO_TS   (time zone: $TIMEZONE)$([ "$CHECK_ONLY" = yes ] && echo ', CHECK ONLY')"
    setup_duck
    declare -ga EXP_ROWS=()
    local i
    for i in "${!SRC_T[@]}"; do
        log "[$((i+1))/${#SRC_T[@]}] ${SRC_T[$i]}"
        exp_table "$i"
    done
    [ "$CHECK_ONLY" = no ] || { log "check only: nothing was written"; exit 0; }
    cp "$CONF" "$EXPORT_DIR/config_used.env"
    (cd "$EXPORT_DIR" && find . -type f ! -name MANIFEST.sha256 ! -name export.log ! -path './.*' -print0 | sort -z | xargs -0 sha256sum >MANIFEST.sha256)
    log "manifest: $EXPORT_DIR/MANIFEST.sha256 ($(wc -l <"$EXPORT_DIR/MANIFEST.sha256") files, $(du -sh "$EXPORT_DIR" | cut -f1) in total)"
    log "done. Copy the whole folder; on the other side check it with: (cd <folder> && sha256sum -c --quiet MANIFEST.sha256)"
    log "then import with db-import.sh: SOURCE_TYPE=\"export\"  SOURCE_EXPORT_DIR=\"<folder>\""
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exp_main "$@"; fi
