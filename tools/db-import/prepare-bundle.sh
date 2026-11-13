#!/usr/bin/env bash
# prepare-bundle.sh - build the offline bundle for db-import.sh. Run ONCE on a machine WITH internet
# (the dev server), then copy the whole db-import folder (with bundle/) to uat / prod.
#
#   ./prepare-bundle.sh [--tar] [--with-flightsql]
#
# Makes ./bundle/ with: the DuckDB CLI (copy), the DuckDB extensions (postgres, ducklake, parquet,
# json, icu) for that exact DuckDB version, VERSION and SHA256SUMS. With --tar it also writes
# db-import-bundle-<version>-<date>.tar.gz (+ .sha256) for the transfer.
# With --with-flightsql it also puts the Python packages of the Flight SQL source (pyarrow,
# adbc-driver-flightsql, adbc-driver-manager) into bundle/pylibs. They are built for the Python that
# runs this script (python3, or PYTHON=<path>): that version and CPU type are saved in
# bundle/pylibs/PYVERSION and db-import.sh refuses to run with another Python. Build it with the same
# Python minor version as the server that will use it (check `python3 --version` there).
# Note: the bundle folder is rebuilt from scratch every time, so always give the same options.
# Why a bundle: extension files only work with the DuckDB version that downloaded them, and uat / prod
# cannot download anything. db-import.sh checks the version and the checksums before it touches data.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUCKDB="${DUCKDB:-duckdb}"
OUT="${BUNDLE_DIR:-$HERE/bundle}"
EXTS="postgres ducklake parquet json icu"
PYTHON="${PYTHON:-python3}"
MAKE_TAR=no; WITH_FLIGHT=no
for a in "$@"; do
    case "$a" in
        --tar) MAKE_TAR=yes ;;
        --with-flightsql) WITH_FLIGHT=yes ;;
        *) echo "ERROR: unknown option $a (use --tar and/or --with-flightsql)" >&2; exit 2 ;;
    esac
done

command -v "$DUCKDB" >/dev/null 2>&1 || { echo "ERROR: DuckDB CLI not found ('$DUCKDB'). Set DUCKDB=<path>." >&2; exit 2; }
BIN="$(command -v "$DUCKDB")"
VER="$("$BIN" -init /dev/null --version | head -1 | awk '{print $1}')"
[ -n "$VER" ] || { echo "ERROR: cannot read the DuckDB version" >&2; exit 2; }
echo "DuckDB $VER ($BIN)"

rm -rf "$OUT"; mkdir -p "$OUT/extensions"
cp "$BIN" "$OUT/duckdb"; chmod +x "$OUT/duckdb"
printf '%s\n' "$VER" >"$OUT/VERSION"

# download the extensions straight into the bundle (needs internet, once)
SQL="SET extension_directory='$OUT/extensions';"
for e in $EXTS; do SQL+=" INSTALL $e;"; done
echo "$SQL" | "$OUT/duckdb" -init /dev/null

# prove they load from the bundle alone: no ~/.duckdb (empty HOME), auto-download switched off
EMPTY_HOME="$(mktemp -d)"
CHECK="SET extension_directory='$OUT/extensions'; SET autoinstall_known_extensions=false; SET autoload_known_extensions=false;"
for e in $EXTS; do CHECK+=" LOAD $e;"; done
CHECK+=" SELECT 'bundle loads without internet' AS status;"
echo "$CHECK" | HOME="$EMPTY_HOME" "$OUT/duckdb" -init /dev/null -csv -noheader | grep -q "bundle loads without internet" \
    || { echo "ERROR: the bundle does not load on its own" >&2; rm -rf "$EMPTY_HOME"; exit 1; }
rm -rf "$EMPTY_HOME"

# Python packages of the Flight SQL source
if [ "$WITH_FLIGHT" = yes ]; then
    command -v "$PYTHON" >/dev/null 2>&1 || { echo "ERROR: Python not found ('$PYTHON'). Set PYTHON=<path>." >&2; exit 2; }
    PYV="$("$PYTHON" -c 'import sys, platform; print("%d.%d %s" % (sys.version_info[0], sys.version_info[1], platform.machine()))')"
    echo "Python $PYV ($("$PYTHON" --version 2>&1)): installing pyarrow, adbc-driver-flightsql, adbc-driver-manager into the bundle (needs internet, once)"
    "$PYTHON" -m pip install --quiet --disable-pip-version-check --target "$OUT/pylibs" pyarrow adbc-driver-flightsql adbc-driver-manager
    printf '%s\n' "$PYV" >"$OUT/pylibs/PYVERSION"
    ls "$OUT/pylibs" | grep '\.dist-info$' >"$OUT/pylibs/PYPACKAGES" || true
    EMPTY_HOME2="$(mktemp -d)"
    HOME="$EMPTY_HOME2" PYTHONPATH="" "$PYTHON" -c 'import sys; sys.path.insert(0, sys.argv[1]); import pyarrow.parquet, adbc_driver_flightsql.dbapi; print("pylibs load without internet")' "$OUT/pylibs" 2>/dev/null \
        | grep -q "pylibs load without internet" \
        || { echo "ERROR: the Python packages in the bundle do not load on their own" >&2; rm -rf "$EMPTY_HOME2"; exit 1; }
    rm -rf "$EMPTY_HOME2"
    find "$OUT/pylibs" -name __pycache__ -type d -prune -exec rm -rf {} +
    echo "Python packages ready: $(tr '\n' ' ' <"$OUT/pylibs/PYPACKAGES")"
fi

# the extensions that must be there (parquet / json / icu are built into the CLI and may not be files)
for f in postgres_scanner ducklake; do
    find "$OUT/extensions" -name "$f.duckdb_extension" | grep -q . \
        || { echo "ERROR: $f.duckdb_extension is missing from the bundle" >&2; exit 1; }
done

# (python caches are not listed: python rewrites them on every run)
(cd "$OUT" && find . -type f ! -name SHA256SUMS ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
echo; echo "Bundle ready in $OUT:"; (cd "$OUT" && find . -maxdepth 2 | sort | head -40)
[ "$WITH_FLIGHT" = no ] || echo "(pylibs: $(find "$OUT/pylibs" -type f | wc -l) files, $(du -sh "$OUT/pylibs" | cut -f1))"

if [ "$MAKE_TAR" = yes ]; then
    T="$HERE/db-import-bundle-$VER-$(date +%Y%m%d).tar.gz"
    tar -C "$HERE" --exclude='__pycache__' -czf "$T" bundle
    (cd "$HERE" && sha256sum "$(basename "$T")" >"$(basename "$T").sha256")
    echo; echo "Transfer file: $T (+ .sha256). On the far side: sha256sum -c <file>.sha256 && tar -C <db-import folder> -xzf <file>"
fi
echo; echo "Copy the db-import folder (including bundle/) to uat / prod."
