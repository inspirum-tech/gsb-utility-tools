#!/usr/bin/env bash
# db-import.sh - copy tables for one time period from a source database to a target database.
#
#   ./db-import.sh [--check | --dry-run] [--yes] <config.env>
#
#   --check    read-only: connect, compare columns, count rows, print the plan, change nothing
#   --dry-run  do the whole import inside a transaction, run the checks, then ROLLBACK
#   --yes      do not ask for confirmation when TARGET_ENV=prod (for unattended runs)
#
# Source: postgres | duckdb | ducklake | parquet.  Target: postgres | duckdb | ducklake.
# Postgres -> Postgres uses psql only. Every other combination uses the DuckDB CLI, with its
# extensions loaded from ./bundle (built once on a machine with internet by prepare-bundle.sh), so
# nothing is downloaded on an offline server. Everything is set in the config file; see
# config.example.env. Needs bash 4+ (and psql and/or duckdb). Standalone: shares nothing with the
# other tools in this repository.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die()  { echo "ERROR: $*" >&2; exit 2; }
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "WARNING: $*" >&2; }
# value of the variable whose name is $1 (empty when unset)
v()    { local n="$1"; printf '%s' "${!n-}"; }

# ---------------------------------------------------------------------------------------------
# Small helpers (pure functions; tests/test_functions.sh calls them)
# ---------------------------------------------------------------------------------------------
BS='\'; SQ="'"

re_ident='^[A-Za-z0-9_]+$'
re_host='^[A-Za-z0-9._:-]+$'
re_path='^[A-Za-z0-9_./*{}:@+=-]+$'
re_port='^[0-9]{1,5}$'

check_re() { # what value regex
    [[ "$2" =~ $3 ]] || die "$1 has a value or character that is not allowed: '$2'"
}

# libpq key=value quoting for a password, then the caller SQL-escapes the whole string
# (sed, not ${s//x/y}: bash 5.1 and 5.2 treat a backslash in that replacement differently)
libpq_val() { local s; s="$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")"; printf "'%s'" "$s"; }
sqlq()      { printf '%s' "${1//$SQ/$SQ$SQ}"; }

# 2026-11-01 -> "2026-11-01 00:00:00";  "2026-11-01 06:00" -> "2026-11-01 06:00:00"; anything else: fail
norm_ts() {
    local x="${1/T/ }" out
    if   [[ "$x" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]];                         then out="$x 00:00:00"
    elif [[ "$x" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]];       then out="$x:00"
    elif [[ "$x" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then out="$x"
    else return 1; fi
    date -d "$out" >/dev/null 2>&1 || return 1     # a real calendar date and time
    printf '%s' "$out"
}

bad_col() { # true (0) when a column name cannot be used safely
    case "$1" in ""|*'"'*|*"'"*|*"$BS"*|*,*|*$'\n'*|*$'\r'*) return 0 ;; esac
    return 1
}

quote_cols() { # "A B C" is not used: input is newline separated names -> "A", "B", "C"
    local out="" c
    while IFS= read -r c; do [ -n "$c" ] || continue; out+="${out:+, }\"$c\""; done <<<"$1"
    printf '%s' "$out"
}

in_list() { # item comma_list
    local it="$1" e
    for e in ${2//,/ }; do [ "$e" = "$it" ] && return 0; done
    return 1
}

tcol_for() { # source table name -> its time column
    local t="$1" tc="$TIME_COLUMN" e
    for e in ${TABLE_TIME_COLUMNS//,/ }; do
        [ "${e%%:*}" = "$t" ] && tc="${e#*:}"
    done
    printf '%s' "$tc"
}

# TABLES="A,B=C" -> SRC_T=(A B) TGT_T=(A C)
parse_tables() {
    local raw it s t
    raw="$(printf '%s' "$TABLES" | tr -d ' \t\r\n')"
    [ -n "$raw" ] || die "TABLES is empty"
    SRC_T=(); TGT_T=()
    IFS=',' read -ra items <<<"$raw"
    for it in "${items[@]}"; do
        [ -n "$it" ] || continue
        if [[ "$it" == *=* ]]; then s="${it%%=*}"; t="${it#*=}"; else s="$it"; t="$it"; fi
        check_re "table name '$s'" "$s" "$re_ident"
        check_re "table name '$t'" "$t" "$re_ident"
        SRC_T+=("$s"); TGT_T+=("$t")
    done
    [ "${#SRC_T[@]}" -gt 0 ] || die "TABLES is empty"
}

# ---------------------------------------------------------------------------------------------
# Connection settings of one side. P is SOURCE or TARGET.
# ---------------------------------------------------------------------------------------------
pwval() { # password of side $1, read from the environment variable named in <P>_PASSWORD_ENV
    local n; n="$(v "$1_PASSWORD_ENV")"
    [ -n "$n" ] || return 0
    check_re "$1_PASSWORD_ENV" "$n" "$re_ident"
    [ -n "${!n-}" ] || die "$1_PASSWORD_ENV=$n, but the environment variable $n is empty or not exported"
    printf '%s' "${!n}"
}

pg_args() { # psql connection options of side $1 (host/port/user optional: empty = socket / default)
    local P="$1" out="" x
    x="$(v "${P}_HOST")"; if [ -n "$x" ]; then out+=" -h $x"; fi
    x="$(v "${P}_PORT")"; if [ -n "$x" ]; then out+=" -p $x"; fi
    x="$(v "${P}_USER")"; if [ -n "$x" ]; then out+=" -U $x"; fi
    out+=" -d $(v "${P}_DB")"
    printf '%s' "$out"
}

# libpq connection string of side $1 (used inside DuckDB ATTACH)
pg_conninfo() {
    local P="$1" out pw x
    out="dbname=$(v "${P}_DB")"
    x="$(v "${P}_HOST")"; if [ -n "$x" ]; then out+=" host=$x"; fi
    x="$(v "${P}_PORT")"; if [ -n "$x" ]; then out+=" port=$x"; fi
    x="$(v "${P}_USER")"; if [ -n "$x" ]; then out+=" user=$x"; fi
    pw="$(pwval "$P")"; if [ -n "$pw" ]; then out+=" password=$(libpq_val "$pw")"; fi
    printf '%s' "$out"
}

# where a side lives, to refuse "source table == target table"
side_fingerprint() {
    local P="$1"
    case "$(v "${P}_TYPE")" in
        postgres|ducklake) printf '%s:%s/%s' "$(v "${P}_HOST")" "$(v "${P}_PORT")" "$(v "${P}_DB")" ;;
        duckdb)            printf '%s' "$(v "${P}_DB_FILE")" ;;
        parquet)           printf 'parquet:%s' "$(v "${P}_PARQUET_GLOB")" ;;
    esac
}

validate_side() {
    local P="$1" type; type="$(v "${P}_TYPE")"
    case "$type" in
        postgres)
            [ -n "$(v "${P}_DB")" ]     || die "${P}_DB is not set"
            [ -n "$(v "${P}_SCHEMA")" ] || die "${P}_SCHEMA is not set"
            check_re "${P}_DB" "$(v "${P}_DB")" "$re_ident"
            [ -z "$(v "${P}_HOST")" ] || check_re "${P}_HOST" "$(v "${P}_HOST")" "$re_host"
            [ -z "$(v "${P}_PORT")" ] || check_re "${P}_PORT" "$(v "${P}_PORT")" "$re_port"
            [ -z "$(v "${P}_USER")" ] || check_re "${P}_USER" "$(v "${P}_USER")" "$re_ident"
            check_re "${P}_SCHEMA" "$(v "${P}_SCHEMA")" "$re_ident" ;;
        ducklake)
            [ -n "$(v "${P}_DB")" ]     || die "${P}_DB is not set (the Postgres database that holds the DuckLake metadata)"
            [ -n "$(v "${P}_SCHEMA")" ] || die "${P}_SCHEMA is not set"
            [ -n "$(v "${P}_DUCKLAKE_DATA_PATH")" ] || die "${P}_DUCKLAKE_DATA_PATH is not set"
            check_re "${P}_DB" "$(v "${P}_DB")" "$re_ident"
            [ -z "$(v "${P}_HOST")" ] || check_re "${P}_HOST" "$(v "${P}_HOST")" "$re_host"
            [ -z "$(v "${P}_PORT")" ] || check_re "${P}_PORT" "$(v "${P}_PORT")" "$re_port"
            [ -z "$(v "${P}_USER")" ] || check_re "${P}_USER" "$(v "${P}_USER")" "$re_ident"
            check_re "${P}_SCHEMA" "$(v "${P}_SCHEMA")" "$re_ident"
            check_re "${P}_DUCKLAKE_DATA_PATH" "$(v "${P}_DUCKLAKE_DATA_PATH")" "$re_path"
            check_re "${P}_DUCKLAKE_METADATA_SCHEMA" "$(v "${P}_DUCKLAKE_METADATA_SCHEMA")" "$re_ident" ;;
        duckdb)
            [ -n "$(v "${P}_DB_FILE")" ] || die "${P}_DB_FILE is not set"
            check_re "${P}_DB_FILE" "$(v "${P}_DB_FILE")" "$re_path"
            check_re "${P}_SCHEMA" "$(v "${P}_SCHEMA")" "$re_ident" ;;
        parquet)
            [ "$P" = SOURCE ] || die "TARGET_TYPE=parquet is not supported (parquet can only be a source)"
            [ -n "$(v "${P}_PARQUET_GLOB")" ] || die "${P}_PARQUET_GLOB is not set (example: /data/{TABLE}/*.parquet)"
            check_re "${P}_PARQUET_GLOB" "$(v "${P}_PARQUET_GLOB")" "$re_path" ;;
        *) die "${P}_TYPE must be postgres, duckdb, ducklake or parquet (target: not parquet); got '$type'" ;;
    esac
    pwval "$P" >/dev/null
}

# ---------------------------------------------------------------------------------------------
# Engine "pg": Postgres -> Postgres with psql only
# ---------------------------------------------------------------------------------------------
pg_run() { # side [psql args...]; SQL on stdin when no -c / -f is given
    local P="$1" pw; shift
    pw="$(pwval "$P")"
    (
        if [ -n "$pw" ]; then export PGPASSWORD="$pw"; else unset PGPASSWORD; fi
        export PGCONNECT_TIMEOUT=10 PGTZ="$TIMEZONE"
        # shellcheck disable=SC2046
        exec psql -X -q -w -t -A -v ON_ERROR_STOP=1 $(pg_args "$P") "$@"
    )
}

pg_cols() { # side schema table
    pg_run "$1" -c "SELECT column_name FROM information_schema.columns WHERE table_schema='$2' AND table_name='$3' ORDER BY ordinal_position"
}

pg_count() { # side schema table where
    pg_run "$1" -c "SELECT count(*) FROM \"$2\".\"$3\" $4"
}

build_pg_sql() { # i tmpdir -> the SQL the target psql runs (one transaction)
    local i="$1" tmp="$2"
    local st="${SRC_T[$i]}" tt="${TGT_T[$i]}" cols_q w="${WHERE[$i]}"
    cols_q="$(quote_cols "${COMMON[$i]}")"
    local srcsql="$tmp/src_$i.sql" prog
    printf 'COPY (SELECT %s FROM "%s"."%s" %s) TO STDOUT WITH (FORMAT csv);\n' \
        "$cols_q" "$SOURCE_SCHEMA" "$st" "$w" >"$srcsql"
    if [ -n "$(pwval SOURCE)" ]; then prog='env PGPASSWORD="$IMPORT_SRC_PW"'; else prog='env -u PGPASSWORD'; fi
    prog+=" PGCONNECT_TIMEOUT=10 PGTZ=$TIMEZONE psql -X -q -w -v ON_ERROR_STOP=1$(pg_args SOURCE) -f $srcsql"

    local sql="\\set ON_ERROR_STOP on
BEGIN;
"
    if [ -n "${BK_NAME[$i]}" ]; then
        sql+="CREATE SCHEMA IF NOT EXISTS \"$BACKUP_SCHEMA\";
CREATE TABLE \"$BACKUP_SCHEMA\".\"${BK_NAME[$i]}\" AS SELECT * FROM \"$TARGET_SCHEMA\".\"$tt\" $w;
"
    fi
    if [ "$LOAD_MODE" = replace ]; then
        sql+="DELETE FROM \"$TARGET_SCHEMA\".\"$tt\" $w;
"
    fi
    sql+="\\copy \"$TARGET_SCHEMA\".\"$tt\" ($cols_q) FROM PROGRAM '$prog' WITH (FORMAT csv)
DO \$chk\$ DECLARE n bigint; BEGIN
  SELECT count(*) INTO n FROM \"$TARGET_SCHEMA\".\"$tt\" $w;
  IF n <> ${EXPECT[$i]} THEN RAISE EXCEPTION 'row count check failed: expected ${EXPECT[$i]}, found %', n; END IF;
END \$chk\$;
SELECT 'RESULT,' || count(*) FROM \"$TARGET_SCHEMA\".\"$tt\" $w;
"
    if [ -n "${BK_NAME[$i]}" ]; then
        sql+="SELECT 'BACKUP,' || count(*) FROM \"$BACKUP_SCHEMA\".\"${BK_NAME[$i]}\";
"
    fi
    if [ "$DRY_RUN" = yes ]; then sql+="ROLLBACK;"; else sql+="COMMIT;"; fi
    printf '%s\n' "$sql"
}

# ---------------------------------------------------------------------------------------------
# Engine "duck": any combination that involves DuckDB / DuckLake / parquet
# ---------------------------------------------------------------------------------------------
duck_run() { # sql -> stdout (list mode, no header). The SQL (with passwords) goes through stdin only.
    # -list, not -csv: csv mode wraps a value that contains a comma in quotes ("SCOL,0,NAME"); list mode prints it as is
    printf '%s\n' "$1" | "$DUCK_BIN" -init /dev/null -list -noheader
}

side_alias() { [ "$1" = SOURCE ] && printf 'src' || printf 'tgt'; }

duck_attach() { # side readonly(yes|no)
    local P="$1" ro="$2" alias type opt=""; alias="$(side_alias "$P")"; type="$(v "${P}_TYPE")"
    [ "$ro" = yes ] && opt=", READ_ONLY"
    case "$type" in
        postgres) printf "ATTACH '%s' AS %s (TYPE postgres%s);\n" "$(sqlq "$(pg_conninfo "$P")")" "$alias" "$opt" ;;
        duckdb)   printf "ATTACH '%s' AS %s%s;\n" "$(sqlq "$(v "${P}_DB_FILE")")" "$alias" "${opt:+ (READ_ONLY)}" ;;
        ducklake) printf "ATTACH 'ducklake:postgres:%s' AS %s (DATA_PATH '%s', METADATA_SCHEMA '%s'%s);\n" \
                      "$(sqlq "$(pg_conninfo "$P")")" "$alias" "$(sqlq "$(v "${P}_DUCKLAKE_DATA_PATH")")" \
                      "$(sqlq "$(v "${P}_DUCKLAKE_METADATA_SCHEMA")")" "$opt" ;;
        parquet)  : ;;   # read with read_parquet(), nothing to attach
    esac
}

duck_head() { # the start of every DuckDB script
    local out=".bail on
" ext
    if [ "$OFFLINE" = yes ]; then
        out+="SET extension_directory='$(sqlq "$BUNDLE_DIR/extensions")';
SET autoinstall_known_extensions=false;
SET autoload_known_extensions=false;
"
    fi
    out+="SET TimeZone='$(sqlq "$TIMEZONE")';
"
    for ext in $DUCK_EXTS; do
        if [ "$OFFLINE" = yes ]; then out+="LOAD $ext;
"; else out+="INSTALL $ext;
LOAD $ext;
"; fi
    done
    out+="$(duck_attach SOURCE yes)
$(duck_attach TARGET no)
"
    printf '%s' "$out"
}

tbl_expr() { # side table
    local P="$1" t="$2" alias; alias="$(side_alias "$P")"
    if [ "$(v "${P}_TYPE")" = parquet ]; then
        local g; g="$(v "${P}_PARQUET_GLOB")"
        printf "read_parquet('%s')" "$(sqlq "${g//\{TABLE\}/$t}")"
    else
        printf '%s."%s"."%s"' "$alias" "$(v "${P}_SCHEMA")" "$t"
    fi
}

build_duck_sql() { # i -> one transaction
    local i="$1" cols_q S T st tt w
    st="${SRC_T[$i]}"; tt="${TGT_T[$i]}"; w="${WHERE[$i]}"
    cols_q="$(quote_cols "${COMMON[$i]}")"
    S="$(tbl_expr SOURCE "$st")"; T="$(tbl_expr TARGET "$tt")"
    local sql; sql="$(duck_head)
BEGIN;
"
    if [ -n "${BK_NAME[$i]}" ]; then
        sql+="CREATE SCHEMA IF NOT EXISTS tgt.\"$BACKUP_SCHEMA\";
CREATE TABLE tgt.\"$BACKUP_SCHEMA\".\"${BK_NAME[$i]}\" AS SELECT * FROM $T $w;
"
    fi
    if [ "$LOAD_MODE" = replace ]; then sql+="DELETE FROM $T $w;
"; fi
    sql+="INSERT INTO $T ($cols_q) SELECT $cols_q FROM $S $w;
SELECT CASE WHEN (SELECT count(*) FROM $T $w) = ${EXPECT[$i]}
            THEN 'RESULT,' || ${EXPECT[$i]}
            ELSE error('row count check failed: expected ${EXPECT[$i]}') END;
"
    if [ -n "${BK_NAME[$i]}" ]; then
        sql+="SELECT 'BACKUP,' || count(*) FROM tgt.\"$BACKUP_SCHEMA\".\"${BK_NAME[$i]}\";
"
    fi
    if [ "$DRY_RUN" = yes ]; then sql+="ROLLBACK;"; else sql+="COMMIT;"; fi
    printf '%s\n' "$sql"
}

# ---------------------------------------------------------------------------------------------
# Offline bundle (DuckDB engine only)
# ---------------------------------------------------------------------------------------------
duck_version_of() { "$1" -init /dev/null --version 2>/dev/null | head -1 | awk '{print $1}'; }

setup_duck() {
    DUCK_BIN="$DUCKDB"
    if [ -x "$BUNDLE_DIR/duckdb" ]; then DUCK_BIN="$BUNDLE_DIR/duckdb"; fi
    command -v "$DUCK_BIN" >/dev/null 2>&1 || [ -x "$DUCK_BIN" ] \
        || die "DuckDB CLI not found ('$DUCK_BIN'). Set DUCKDB=<path> in the config, or run prepare-bundle.sh on dev and copy bundle/ here."
    DUCK_EXTS=""
    local P t; for P in SOURCE TARGET; do
        t="$(v "${P}_TYPE")"
        case "$t" in postgres) DUCK_EXTS+=" postgres" ;; ducklake) DUCK_EXTS+=" postgres ducklake" ;; parquet) DUCK_EXTS+=" parquet" ;; esac
    done
    DUCK_EXTS="$(printf '%s\n' $DUCK_EXTS | sort -u | tr '\n' ' ')"
    log "DuckDB: $DUCK_BIN ($(duck_version_of "$DUCK_BIN")); extensions needed: ${DUCK_EXTS:-none}"
    [ "$OFFLINE" = yes ] || { warn "OFFLINE=no: DuckDB may download extensions (only for a machine with internet)"; return 0; }

    [ -d "$BUNDLE_DIR/extensions" ] && [ -f "$BUNDLE_DIR/VERSION" ] \
        || die "offline bundle not found in $BUNDLE_DIR. On a machine with internet run ./prepare-bundle.sh and copy the bundle/ folder next to this script (README, 'Offline')."
    if [ -f "$BUNDLE_DIR/SHA256SUMS" ]; then
        (cd "$BUNDLE_DIR" && sha256sum -c --quiet SHA256SUMS) \
            || die "bundle checksum failed: the bundle was damaged or not fully copied. Copy it again."
    else
        warn "no SHA256SUMS in the bundle: copy integrity not verified"
    fi
    local want have; want="$(tr -d ' \r\n' <"$BUNDLE_DIR/VERSION")"; have="$(duck_version_of "$DUCK_BIN")"
    [ "$want" = "$have" ] || die "DuckDB version is $have but the bundle was built for $want. Use the DuckDB in bundle/duckdb, or rebuild the bundle with this version."
    local e f
    for e in $DUCK_EXTS; do
        [ "$e" = parquet ] && continue          # built into the DuckDB CLI
        f="$e"; [ "$e" = postgres ] && f="postgres_scanner"
        find "$BUNDLE_DIR/extensions" -name "$f.duckdb_extension" | grep -q . \
            || die "extension '$e' is not in the bundle ($f.duckdb_extension). Rebuild the bundle on dev."
    done
}

# ---------------------------------------------------------------------------------------------
# Config, preflight, execution
# ---------------------------------------------------------------------------------------------
declare -a SRC_T TGT_T SRC_COLS TGT_COLS COMMON MODE TC WHERE SRC_CNT TGT_CNT EXPECT BK_NAME
declare -a STATUS AFTER BKROWS SECS MSG

load_config() {
    [ -f "$CONF" ] || die "config not found: $CONF"
    if grep -q $'\r' "$CONF"; then die "config has Windows line endings. Run: dos2unix $CONF"; fi
    # shellcheck disable=SC1090
    source "$CONF"
    : "${JOB_NAME:=$(basename "$CONF" .env)}"
    : "${SOURCE_TYPE:=}" "${TARGET_TYPE:=}" "${TARGET_ENV:=}"
    : "${SOURCE_PORT:=}" "${TARGET_PORT:=}"
    : "${SOURCE_DUCKLAKE_METADATA_SCHEMA:=metadata}" "${TARGET_DUCKLAKE_METADATA_SCHEMA:=metadata}"
    : "${SOURCE_SCHEMA:=}" "${TARGET_SCHEMA:=${SOURCE_SCHEMA}}"
    : "${LOAD_MODE:=replace}" "${BACKUP:=on}" "${BACKUP_SCHEMA:=import_backup}"
    : "${TIME_COLUMN:=PERIOD_START_TIME}" "${TABLE_TIME_COLUMNS:=}" "${FULL_COPY_TABLES:=}"
    : "${PERIOD_FROM:=}" "${PERIOD_TO:=}" "${TABLES:=}" "${ON_ERROR:=stop}"
    : "${TIMEZONE:=UTC}"
    : "${OFFLINE:=yes}" "${DUCKDB:=duckdb}" "${BUNDLE_DIR:=$HERE/bundle}" "${REPORT_DIR:=$HERE/reports}"
}

validate_config() {
    validate_side SOURCE; validate_side TARGET
    case "$TARGET_ENV" in dev|uat|prod) ;; *) die "TARGET_ENV must be dev, uat or prod (it decides whether a confirmation is asked)";; esac
    case "$LOAD_MODE" in replace|append|stop) ;; *) die "LOAD_MODE must be replace, append or stop";; esac
    case "$BACKUP" in on|off) ;; *) die "BACKUP must be on or off";; esac
    case "$ON_ERROR" in stop|continue) ;; *) die "ON_ERROR must be stop or continue";; esac
    case "$OFFLINE" in yes|no) ;; *) die "OFFLINE must be yes or no";; esac
    check_re BACKUP_SCHEMA "$BACKUP_SCHEMA" "$re_ident"
    check_re TIME_COLUMN "$TIME_COLUMN" "$re_ident"
    check_re TIMEZONE "$TIMEZONE" '^[A-Za-z0-9_/+-]+$'
    local e; for e in ${TABLE_TIME_COLUMNS//,/ }; do
        [[ "$e" == *:* ]] || die "TABLE_TIME_COLUMNS entry '$e' must look like TABLE:COLUMN"
        check_re "TABLE_TIME_COLUMNS table" "${e%%:*}" "$re_ident"; check_re "TABLE_TIME_COLUMNS column" "${e#*:}" "$re_ident"
    done
    for e in ${FULL_COPY_TABLES//,/ }; do check_re "FULL_COPY_TABLES entry" "$e" "$re_ident"; done
    FROM_TS="$(norm_ts "$PERIOD_FROM")" || die "PERIOD_FROM '$PERIOD_FROM' is not valid. Use YYYY-MM-DD or YYYY-MM-DD HH:MM[:SS]"
    TO_TS="$(norm_ts "$PERIOD_TO")"     || die "PERIOD_TO '$PERIOD_TO' is not valid. Use YYYY-MM-DD or YYYY-MM-DD HH:MM[:SS]"
    [[ "$FROM_TS" < "$TO_TS" ]] || die "PERIOD_FROM ($FROM_TS) must be earlier than PERIOD_TO ($TO_TS)"
    parse_tables
    if [ "$SOURCE_TYPE" = postgres ] && [ "$TARGET_TYPE" = postgres ]; then ENGINE=pg; else ENGINE=duck; fi
    if [ "$(side_fingerprint SOURCE)" = "$(side_fingerprint TARGET)" ] && [ "$SOURCE_SCHEMA" = "$TARGET_SCHEMA" ]; then
        local i; for i in "${!SRC_T[@]}"; do
            [ "${SRC_T[$i]}" != "${TGT_T[$i]}" ] || die "source and target are the same table (${SRC_T[$i]} in the same database and schema). Check SOURCE_* / TARGET_*"
        done
    fi
}

# fills SRC_COLS / TGT_COLS (newline separated column names, in table order)
preflight_cols() {
    local i out
    if [ "$ENGINE" = pg ]; then
        for i in "${!SRC_T[@]}"; do
            out="$(pg_cols SOURCE "$SOURCE_SCHEMA" "${SRC_T[$i]}")" || die "cannot read the columns of the source (see the error above)"
            [ -n "$out" ] || die "source table $SOURCE_SCHEMA.${SRC_T[$i]} does not exist (or has no columns)"
            SRC_COLS[$i]="$out"
            out="$(pg_cols TARGET "$TARGET_SCHEMA" "${TGT_T[$i]}")" || die "cannot read the columns of the target (see the error above)"
            [ -n "$out" ] || die "target table $TARGET_SCHEMA.${TGT_T[$i]} does not exist. The script never creates the target table."
            TGT_COLS[$i]="$out"
        done
    else
        local sql line tag idx col; sql="$(duck_head)"$'\n'
        for i in "${!SRC_T[@]}"; do
            sql+="SELECT 'SCOL,$i,' || column_name FROM (DESCRIBE SELECT * FROM $(tbl_expr SOURCE "${SRC_T[$i]}"));
SELECT 'TCOL,$i,' || column_name FROM (DESCRIBE SELECT * FROM $(tbl_expr TARGET "${TGT_T[$i]}"));
"
        done
        out="$(duck_run "$sql")" || die "DuckDB could not read the table columns (see the error above)"
        for i in "${!SRC_T[@]}"; do SRC_COLS[$i]=""; TGT_COLS[$i]=""; done
        while IFS=, read -r tag idx col; do
            case "$tag" in
                SCOL) SRC_COLS[$idx]+="$col"$'\n' ;;
                TCOL) TGT_COLS[$idx]+="$col"$'\n' ;;
            esac
        done <<<"$out"
        for i in "${!SRC_T[@]}"; do
            [ -n "${SRC_COLS[$i]}" ] || die "source table ${SRC_T[$i]} has no columns"
            [ -n "${TGT_COLS[$i]}" ] || die "target table ${TGT_T[$i]} has no columns"
        done
    fi
}

has_col() { grep -qxF -- "$2" <<<"$1"; }

# decide, per table: window or full copy, columns to copy, WHERE text
decide_tables() {
    local i errs=0 c missing tc st
    for i in "${!SRC_T[@]}"; do
        st="${SRC_T[$i]}"; tc="$(tcol_for "$st")"; TC[$i]="$tc"
        while IFS= read -r c; do
            [ -n "$c" ] || continue
            if bad_col "$c"; then echo "ERROR: $st: column name '$c' has a character that is not supported" >&2; errs=$((errs+1)); fi
        done <<<"${SRC_COLS[$i]}"
        missing=""
        while IFS= read -r c; do
            [ -n "$c" ] || continue
            has_col "${TGT_COLS[$i]}" "$c" || missing+="$c "
        done <<<"${SRC_COLS[$i]}"
        if [ -n "$missing" ]; then
            echo "ERROR: $st: these source columns are not in the target table: $missing" >&2; errs=$((errs+1))
        fi
        COMMON[$i]="${SRC_COLS[$i]}"
        local in_s=no in_t=no
        has_col "${SRC_COLS[$i]}" "$tc" && in_s=yes
        has_col "${TGT_COLS[$i]}" "$tc" && in_t=yes
        if [ "$in_s" = yes ] && [ "$in_t" = yes ]; then
            MODE[$i]=window
            WHERE[$i]="WHERE \"$tc\" >= TIMESTAMP '$FROM_TS' AND \"$tc\" < TIMESTAMP '$TO_TS'"
        elif [ "$in_s" = no ] && [ "$in_t" = no ] && in_list "$st" "$FULL_COPY_TABLES"; then
            MODE[$i]=full; WHERE[$i]=""
        elif [ "$in_s" = no ] && [ "$in_t" = no ]; then
            echo "ERROR: $st: no column $tc in source or target. If this table is meant to be copied whole, add it to FULL_COPY_TABLES; otherwise set TABLE_TIME_COLUMNS=$st:<column>." >&2; errs=$((errs+1))
        else
            echo "ERROR: $st: time column $tc exists in the source: $in_s, in the target: $in_t. It must be on both sides." >&2; errs=$((errs+1))
        fi
    done
    [ "$errs" -eq 0 ] || die "preflight failed: $errs problem(s) above. Nothing was changed."
}

preflight_counts() {
    local i out
    if [ "$ENGINE" = pg ]; then
        for i in "${!SRC_T[@]}"; do
            SRC_CNT[$i]="$(pg_count SOURCE "$SOURCE_SCHEMA" "${SRC_T[$i]}" "${WHERE[$i]}")" || die "source count failed"
            TGT_CNT[$i]="$(pg_count TARGET "$TARGET_SCHEMA" "${TGT_T[$i]}" "${WHERE[$i]}")" || die "target count failed"
        done
    else
        local sql tag idx s t; sql="$(duck_head)"$'\n'
        for i in "${!SRC_T[@]}"; do
            sql+="SELECT 'CNT,$i,' || (SELECT count(*) FROM $(tbl_expr SOURCE "${SRC_T[$i]}") ${WHERE[$i]}) || ',' || (SELECT count(*) FROM $(tbl_expr TARGET "${TGT_T[$i]}") ${WHERE[$i]});
"
        done
        out="$(duck_run "$sql")" || die "DuckDB count failed (see the error above)"
        while IFS=, read -r tag idx s t; do
            [ "$tag" = CNT ] || continue
            SRC_CNT[$idx]="$s"; TGT_CNT[$idx]="$t"
        done <<<"$out"
    fi
    local stamp; stamp="$RUN_TS"
    for i in "${!SRC_T[@]}"; do
        [[ "${SRC_CNT[$i]:-}" =~ ^[0-9]+$ && "${TGT_CNT[$i]:-}" =~ ^[0-9]+$ ]] || die "could not read the row counts for ${SRC_T[$i]}"
        case "$LOAD_MODE" in
            replace|stop) EXPECT[$i]="${SRC_CNT[$i]}" ;;
            append)       EXPECT[$i]=$(( ${TGT_CNT[$i]} + ${SRC_CNT[$i]} )) ;;
        esac
        BK_NAME[$i]=""
        if [ "$BACKUP" = on ] && [ "$LOAD_MODE" = replace ] && [ "${TGT_CNT[$i]}" -gt 0 ]; then
            local suffix="_bak_$stamp" base="${TGT_T[$i]}"
            BK_NAME[$i]="${base:0:$((63 - ${#suffix}))}$suffix"      # Postgres cuts names at 63 characters
        fi
        if [ "$LOAD_MODE" = stop ] && [ "${TGT_CNT[$i]}" -gt 0 ]; then
            echo "ERROR: ${TGT_T[$i]}: the target already has ${TGT_CNT[$i]} row(s) for this period and LOAD_MODE=stop" >&2
            STOP_FOUND=yes
        fi
    done
    [ "${STOP_FOUND:-no}" = no ] || die "LOAD_MODE=stop: the target is not empty for the period. Nothing was changed."
}

print_plan() {
    local i
    echo
    printf '%-4s %-34s %-34s %-7s %12s %12s  %s\n' "#" "SOURCE TABLE" "TARGET TABLE" "MODE" "SOURCE ROWS" "TARGET ROWS" "BACKUP"
    for i in "${!SRC_T[@]}"; do
        printf '%-4s %-34s %-34s %-7s %12s %12s  %s\n' "$((i+1))" "${SRC_T[$i]}" "${TGT_T[$i]}" "${MODE[$i]}" \
            "${SRC_CNT[$i]}" "${TGT_CNT[$i]}" "${BK_NAME[$i]:--}"
    done
    echo
    case "$LOAD_MODE" in
        replace) echo "LOAD_MODE=replace: target rows in the period are deleted, then the source rows are inserted." ;;
        append)  echo "LOAD_MODE=append: source rows are inserted, nothing is deleted (running twice gives duplicates)." ;;
        stop)    echo "LOAD_MODE=stop: the target was empty for the period, source rows are inserted." ;;
    esac
}

confirm_target() {
    [ "$TARGET_ENV" = prod ] || return 0
    [ "$ASSUME_YES" = yes ] && return 0
    [ -t 0 ] || die "the target is PROD: run this from a terminal and confirm, or pass --yes"
    local name; name="$(v TARGET_DB)"; [ -n "$name" ] || name="$(basename "$(v TARGET_DB_FILE)")"
    echo "The target is PROD ($name). Type the target database name to continue:"
    local ans; read -r ans
    [ "$ans" = "$name" ] || die "not confirmed, nothing was changed"
}

run_table() { # i
    local i="$1" sql out rc=0 start=$SECONDS
    if [ "$ENGINE" = pg ]; then
        sql="$(build_pg_sql "$i" "$TMP")"
        out="$( export IMPORT_SRC_PW; IMPORT_SRC_PW="$(pwval SOURCE)"; printf '%s\n' "$sql" | pg_run TARGET )" || rc=$?
    else
        sql="$(build_duck_sql "$i")"
        out="$(duck_run "$sql")" || rc=$?
    fi
    SECS[$i]=$((SECONDS - start))
    local after bk
    after="$(grep -m1 '^RESULT,' <<<"$out" | cut -d, -f2 || true)"
    bk="$(grep -m1 '^BACKUP,' <<<"$out" | cut -d, -f2 || true)"
    AFTER[$i]="${after:-}"; BKROWS[$i]="${bk:--}"
    if [ "$rc" -eq 0 ] && [ -n "$after" ]; then
        if [ "$DRY_RUN" = yes ]; then STATUS[$i]="DRY-RUN OK (rolled back)"; else STATUS[$i]="OK"; fi
        MSG[$i]=""
        return 0
    fi
    STATUS[$i]="FAILED"; MSG[$i]="exit code $rc; the transaction was rolled back (see the error above)"
    return 1
}

write_summary() {
    local f="$RUN_DIR/summary.csv" i
    echo "table_source,table_target,mode,source_rows,target_rows_before,backup_table,backup_rows,target_rows_after,status,seconds,message" >"$f"
    for i in "${!SRC_T[@]}"; do
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "${SRC_T[$i]}" "${TGT_T[$i]}" "${MODE[$i]}" "${SRC_CNT[$i]}" "${TGT_CNT[$i]}" \
            "${BK_NAME[$i]:--}" "${BKROWS[$i]:--}" "${AFTER[$i]:--}" "${STATUS[$i]:-NOT RUN}" "${SECS[$i]:--}" "${MSG[$i]:-}" >>"$f"
    done
    log "summary: $f"
}

main() {
    CONF=""; DRY_RUN=no; CHECK_ONLY=no; ASSUME_YES=no
    local a
    for a in "$@"; do
        case "$a" in
            --dry-run) DRY_RUN=yes ;;
            --check)   CHECK_ONLY=yes ;;
            --yes)     ASSUME_YES=yes ;;
            -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
            -*)        die "unknown option $a" ;;
            *)         CONF="$a" ;;
        esac
    done
    [ -n "$CONF" ] || die "name the config file: ./db-import.sh [--check|--dry-run] [--yes] <config.env>"
    [ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash 4 or newer is required"
    load_config
    validate_config

    RUN_TS="$(date +%Y%m%d_%H%M%S)"
    RUN_DIR="$REPORT_DIR/${RUN_TS}_${JOB_NAME}"
    mkdir -p "$RUN_DIR"
    exec > >(tee -a "$RUN_DIR/run.log") 2>&1
    TMP="$(mktemp -d)"; check_re "temp folder" "$TMP" "$re_path"
    trap 'rm -rf "$TMP"' EXIT
    cp "$CONF" "$RUN_DIR/config_used.env"

    log "db-import job '$JOB_NAME'  ($SOURCE_TYPE -> $TARGET_TYPE, target env: $TARGET_ENV, engine: $ENGINE)"
    log "period: $FROM_TS  <=  $TIME_COLUMN  <  $TO_TS   (time zone: $TIMEZONE)"
    log "mode: LOAD_MODE=$LOAD_MODE BACKUP=$BACKUP$([ "$DRY_RUN" = yes ] && echo ', DRY-RUN (rolled back at the end)')$([ "$CHECK_ONLY" = yes ] && echo ', CHECK ONLY (no change)')"
    log "report folder: $RUN_DIR"
    if [ "$ENGINE" = pg ]; then
        command -v psql >/dev/null 2>&1 || die "psql not found"
        log "psql: $(psql --version)"
    else
        setup_duck
    fi
    [ "$BACKUP" = on ] || warn "BACKUP=off: the rows that are replaced will NOT be saved anywhere"

    preflight_cols
    decide_tables
    preflight_counts
    print_plan
    [ "$CHECK_ONLY" = no ] || { log "check only: nothing was changed"; exit 0; }
    confirm_target

    local i failed=0
    for i in "${!SRC_T[@]}"; do
        log "[$((i+1))/${#SRC_T[@]}] ${SRC_T[$i]} -> ${TGT_T[$i]}"
        if run_table "$i"; then
            log "    ${STATUS[$i]}: target rows in the period ${TGT_CNT[$i]} -> ${AFTER[$i]} (source ${SRC_CNT[$i]}), backup rows ${BKROWS[$i]}, ${SECS[$i]}s"
        else
            failed=$((failed+1)); log "    FAILED: ${MSG[$i]}"
            [ "$ON_ERROR" = continue ] || break
        fi
    done
    write_summary
    if [ "$failed" -gt 0 ]; then log "finished with $failed failed table(s)"; exit 1; fi
    log "finished: all tables OK"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
