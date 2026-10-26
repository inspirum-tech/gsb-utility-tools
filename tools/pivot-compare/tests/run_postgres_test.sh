#!/usr/bin/env bash
# Optional test of the Postgres path (attach, numeric columns, partitioned table, timestamptz) with a throwaway
# Postgres in Docker (postgres:16-alpine, port 55432, removed at the end). Needs Docker and the DuckDB CLI (internet
# once, so DuckDB can fetch its postgres extension). The fake database is the only thing that is written.
#   tests/run_postgres_test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DUCKDB="${DUCKDB:-duckdb}"
W=tests/work_pg; rm -rf "$W"; mkdir -p "$W"
docker rm -f pc_pg >/dev/null 2>&1
docker run -d --rm --name pc_pg -e POSTGRES_PASSWORD=t -e POSTGRES_DB=gsb -p 55432:5432 postgres:16-alpine >/dev/null || exit 2
trap 'docker rm -f pc_pg >/dev/null 2>&1' EXIT
for i in $(seq 1 30); do docker exec pc_pg pg_isready -U postgres -d gsb >/dev/null 2>&1 && break; sleep 1; done
sleep 2
docker exec -i pc_pg psql -U postgres -d gsb -v ON_ERROR_STOP=1 -q < tests/pg_fixture.sql || exit 2

{ cat tests/test.env
  cat <<'EOF'
OLD_SOURCE=postgres
OLD_DSN_ENV=PIVOT_COMPARE_TEST_DSN
OLD_SCHEMA=gsb_data_kpi_pivot
OLD_TABLE=KPI_TEST_QRLY_CELL_LTE_ERS_P
NEW_SOURCE=postgres
NEW_DSN_ENV=PIVOT_COMPARE_TEST_DSN
NEW_SCHEMA=gsb_data_kpi_base
NEW_TABLE=KPI_CALCULATED
REPORT_DIR=tests/work_pg/report
EOF
} > "$W/pg.env"
export PIVOT_COMPARE_TEST_DSN="host=localhost port=55432 dbname=gsb user=postgres password=t"
./run.sh "$W/pg.env"; code=$?
echo "exit code: $code (1 = DIFFERENT is expected: the fake data has known differences)"
echo "differences.csv:"; cat "$W/report/differences.csv"
echo "objects_one_side.csv:"; cat "$W/report/objects_one_side.csv"
echo "duplicate_keys.csv:"; cat "$W/report/duplicate_keys.csv"
