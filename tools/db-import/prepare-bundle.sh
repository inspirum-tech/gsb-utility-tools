#!/usr/bin/env bash
# prepare-bundle.sh - build the offline bundle for db-import.sh. Run ONCE on a machine WITH internet
# (the dev server), then copy the whole db-import folder (with bundle/) to uat / prod.
#
#   ./prepare-bundle.sh [--tar]
#
# Makes ./bundle/ with: the DuckDB CLI (copy), the DuckDB extensions (postgres, ducklake, parquet,
# json, icu) for that exact DuckDB version, VERSION and SHA256SUMS. With --tar it also writes
# db-import-bundle-<version>-<date>.tar.gz (+ .sha256) for the transfer.
# Why a bundle: extension files only work with the DuckDB version that downloaded them, and uat / prod
# cannot download anything. db-import.sh checks the version and the checksums before it touches data.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUCKDB="${DUCKDB:-duckdb}"
OUT="${BUNDLE_DIR:-$HERE/bundle}"
EXTS="postgres ducklake parquet json icu"
MAKE_TAR=no; [ "${1:-}" = "--tar" ] && MAKE_TAR=yes

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

# the extensions that must be there (parquet / json / icu are built into the CLI and may not be files)
for f in postgres_scanner ducklake; do
    find "$OUT/extensions" -name "$f.duckdb_extension" | grep -q . \
        || { echo "ERROR: $f.duckdb_extension is missing from the bundle" >&2; exit 1; }
done

(cd "$OUT" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum >SHA256SUMS)
echo; echo "Bundle ready in $OUT:"; (cd "$OUT" && find . -type f | sort | xargs ls -l)

if [ "$MAKE_TAR" = yes ]; then
    T="$HERE/db-import-bundle-$VER-$(date +%Y%m%d).tar.gz"
    tar -C "$HERE" -czf "$T" bundle
    (cd "$HERE" && sha256sum "$(basename "$T")" >"$(basename "$T").sha256")
    echo; echo "Transfer file: $T (+ .sha256). On the far side: sha256sum -c <file>.sha256 && tar -C <db-import folder> -xzf <file>"
fi
echo; echo "Copy the db-import folder (including bundle/) to uat / prod."
