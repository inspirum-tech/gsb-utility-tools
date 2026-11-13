#!/usr/bin/env bash
# Postgres -> Postgres test of db-import.sh on the DEV server. Uses ONLY scratch schemas it creates
# itself (dbimport_test_src, dbimport_test_tgt, dbimport_test_bak) and drops them at the end.
# Nothing else in the database is read or changed.
#
#   cd <db-import folder> && bash tests/dev_scratch_test.sh 2>&1 | tee docs/dev_test_output.txt
#
# Connection (defaults match the dev gsb database; override with environment variables):
#   TEST_HOST (default 192.168.50.218)  TEST_PORT (5432)  TEST_DB (gsb)  TEST_USER (postgres)
#   TEST_PW   the password (export it), or leave unset to use ~/.pgpass
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_HOST="${TEST_HOST-192.168.50.218}"; TEST_PORT="${TEST_PORT-5432}"; TEST_DB="${TEST_DB-gsb}"; TEST_USER="${TEST_USER-postgres}"
export TEST_PW
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
SRC=dbimport_test_src; TGT=dbimport_test_tgt; BAK=dbimport_test_bak

q() { # run SQL, print the single value
    ( if [ -n "${TEST_PW:-}" ]; then export PGPASSWORD="$TEST_PW"; else unset PGPASSWORD; fi
      psql -X -q -w -t -A -v ON_ERROR_STOP=1 ${TEST_HOST:+-h $TEST_HOST} ${TEST_PORT:+-p $TEST_PORT} -U "$TEST_USER" -d "$TEST_DB" -c "$1" )
}
PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS  $1  ($3)"; else FAIL=$((FAIL+1)); echo "  FAIL  $1  expected [$2] got [$3]"; fi; }

mkcfg() { # name  extra-lines...
    local f="$W/$1.env"; shift
    cat >"$f" <<EOF
JOB_NAME="test"
SOURCE_TYPE="postgres"; SOURCE_HOST="$TEST_HOST"; SOURCE_PORT="$TEST_PORT"; SOURCE_DB="$TEST_DB"; SOURCE_USER="$TEST_USER"; SOURCE_PASSWORD_ENV="$([ -n "${TEST_PW:-}" ] && echo TEST_PW)"; SOURCE_SCHEMA="$SRC"
TARGET_TYPE="postgres"; TARGET_ENV="dev"; TARGET_HOST="$TEST_HOST"; TARGET_PORT="$TEST_PORT"; TARGET_DB="$TEST_DB"; TARGET_USER="$TEST_USER"; TARGET_PASSWORD_ENV="$([ -n "${TEST_PW:-}" ] && echo TEST_PW)"; TARGET_SCHEMA="$TGT"
TABLES="T1"
PERIOD_FROM="2026-11-01"; PERIOD_TO="2026-11-02"
BACKUP_SCHEMA="$BAK"
REPORT_DIR="$W/reports"
$*
EOF
    echo "$f"
}
run() { bash "$HERE/db-import.sh" "$@" >"$W/last.log" 2>&1; local rc=$?; echo "$rc"; }

echo "== connection / database"
eq "database" "$TEST_DB" "$(q 'select current_database()')"

echo "== setup scratch data"
q "DROP SCHEMA IF EXISTS $SRC CASCADE; DROP SCHEMA IF EXISTS $TGT CASCADE; DROP SCHEMA IF EXISTS $BAK CASCADE;
CREATE SCHEMA $SRC; CREATE SCHEMA $TGT;
CREATE TABLE $SRC.\"T1\"(\"ID\" int, \"PERIOD_START_TIME\" timestamp, \"V\" text);
INSERT INTO $SRC.\"T1\" VALUES
 (1,'2026-11-01 00:00:00','plain'),
 (2,'2026-11-01 06:15:00',NULL),
 (3,'2026-11-01 12:00:00',''),
 (4,'2026-11-01 23:45:00','with,comma \"quote\" and ''apostrophe'''),
 (5,'2026-11-02 00:00:00','EXACTLY AT PERIOD_TO - must NOT be imported'),
 (6,'2026-11-02 12:00:00','next day');
CREATE TABLE $TGT.\"T1\"(\"ID\" int, \"PERIOD_START_TIME\" timestamp, \"V\" text, \"EXTRA\" text DEFAULT 'x');
INSERT INTO $TGT.\"T1\"(\"ID\",\"PERIOD_START_TIME\",\"V\") VALUES
 (91,'2026-10-31 12:00:00','before the window - must survive'),
 (92,'2026-11-01 01:00:00','old row 1 - replaced'),
 (93,'2026-11-01 02:00:00','old row 2 - replaced'),
 (94,'2026-11-01 03:00:00','old row 3 - replaced');
CREATE TABLE $SRC.\"T2\"(\"ID\" int, \"PERIOD_START_TIME\" timestamp, \"V\" text);
INSERT INTO $SRC.\"T2\" VALUES (1,'2026-11-01 01:00:00','ok'),(2,'2026-11-01 02:00:00','bad');
CREATE TABLE $TGT.\"T2\"(\"ID\" int, \"PERIOD_START_TIME\" timestamp, \"V\" text CHECK (\"V\" <> 'bad'));
INSERT INTO $TGT.\"T2\" VALUES (50,'2026-11-01 05:00:00','keep me');" >/dev/null
eq "target T1 rows before" 4 "$(q "select count(*) from $TGT.\"T1\"")"

echo "== A. --check changes nothing"
C="$(mkcfg a)"
eq "exit code" 0 "$(run --check "$C")"
eq "target T1 rows" 4 "$(q "select count(*) from $TGT.\"T1\"")"
eq "no backup schema" 0 "$(q "select count(*) from information_schema.schemata where schema_name='$BAK'")"

echo "== B. --dry-run changes nothing (everything is rolled back, backup table too)"
eq "exit code" 0 "$(run --dry-run "$C")"
eq "target T1 rows" 4 "$(q "select count(*) from $TGT.\"T1\"")"
eq "old row still there" 1 "$(q "select count(*) from $TGT.\"T1\" where \"ID\"=92")"
eq "no backup table left" 0 "$(q "select count(*) from information_schema.tables where table_schema='$BAK'")"

echo "== C. real run: replace the period 2026-11-01"
eq "exit code" 0 "$(run "$C")"
eq "window rows = 4 from the source" 4 "$(q "select count(*) from $TGT.\"T1\" where \"PERIOD_START_TIME\" >= '2026-11-01' and \"PERIOD_START_TIME\" < '2026-11-02'")"
eq "row before the window survived" 1 "$(q "select count(*) from $TGT.\"T1\" where \"ID\"=91")"
eq "old rows are gone" 0 "$(q "select count(*) from $TGT.\"T1\" where \"ID\" in (92,93,94)")"
eq "row at PERIOD_TO not imported" 0 "$(q "select count(*) from $TGT.\"T1\" where \"ID\" in (5,6)")"
eq "NULL stays NULL" 1 "$(q "select count(*) from $TGT.\"T1\" where \"ID\"=2 and \"V\" is null")"
eq "empty string stays empty" 1 "$(q "select count(*) from $TGT.\"T1\" where \"ID\"=3 and \"V\" = ''")"
eq "comma / quote / apostrophe text" 1 "$(q "select count(*) from $TGT.\"T1\" where \"ID\"=4 and \"V\" = 'with,comma \"quote\" and ''apostrophe'''")"
eq "target-only column gets its default (imported rows)" 4 "$(q "select count(*) from $TGT.\"T1\" where \"EXTRA\"='x' and \"PERIOD_START_TIME\" >= '2026-11-01' and \"PERIOD_START_TIME\" < '2026-11-02'")"
eq "one backup table" 1 "$(q "select count(*) from information_schema.tables where table_schema='$BAK'")"
eq "backup holds the 3 replaced rows" 3 "$(q "select count(*) from $BAK.\"$(q "select table_name from information_schema.tables where table_schema='$BAK' limit 1")\"")"

echo "== D. run again: same result, no duplicates (replace is repeatable)"
sleep 1
eq "exit code" 0 "$(run "$C")"
eq "window rows still 4" 4 "$(q "select count(*) from $TGT.\"T1\" where \"PERIOD_START_TIME\" >= '2026-11-01' and \"PERIOD_START_TIME\" < '2026-11-02'")"
eq "second backup table (4 rows)" 2 "$(q "select count(*) from information_schema.tables where table_schema='$BAK'")"

echo "== E. BACKUP=off: no new backup table"
sleep 1
eq "exit code" 0 "$(run "$(mkcfg e 'BACKUP="off"')")"
eq "still 2 backup tables" 2 "$(q "select count(*) from information_schema.tables where table_schema='$BAK'")"

echo "== F. a failing import is rolled back completely"
eq "exit code 1" 1 "$(run "$(mkcfg f 'TABLES="T2"')")"
eq "target T2 unchanged (1 row)" 1 "$(q "select count(*) from $TGT.\"T2\"")"
eq "kept row still there" 1 "$(q "select count(*) from $TGT.\"T2\" where \"ID\"=50")"
eq "no backup of T2 left" 0 "$(q "select count(*) from information_schema.tables where table_schema='$BAK' and table_name like 'T2%'")"

echo "== G. LOAD_MODE=stop refuses a non-empty period; append adds rows"
eq "stop: exit code 2" 2 "$(run "$(mkcfg g 'LOAD_MODE="stop"')")"
eq "stop: nothing changed" 4 "$(q "select count(*) from $TGT.\"T1\" where \"PERIOD_START_TIME\" >= '2026-11-01' and \"PERIOD_START_TIME\" < '2026-11-02'")"
eq "append: exit code" 0 "$(run "$(mkcfg h 'LOAD_MODE="append"')")"
eq "append: duplicates (8 rows)" 8 "$(q "select count(*) from $TGT.\"T1\" where \"PERIOD_START_TIME\" >= '2026-11-01' and \"PERIOD_START_TIME\" < '2026-11-02'")"

echo "== H. refusals"
eq "missing target table: exit 2" 2 "$(run "$(mkcfg i 'TABLES="NOPE"')")"
eq "bad date: exit 2" 2 "$(run "$(mkcfg j 'PERIOD_FROM="01/11/2026"')")"

echo "== I. a table with no time column: refused unless it is listed in FULL_COPY_TABLES"
q "CREATE TABLE $SRC.\"T3\"(\"ID\" int, \"NAME\" text); INSERT INTO $SRC.\"T3\" VALUES (1,'a'),(2,'b'),(3,'c');
CREATE TABLE $TGT.\"T3\"(\"ID\" int, \"NAME\" text); INSERT INTO $TGT.\"T3\" VALUES (90,'old1'),(91,'old2');" >/dev/null
eq "not listed: exit 2" 2 "$(run "$(mkcfg k 'TABLES="T3"')")"
eq "not listed: target unchanged" 2 "$(q "select count(*) from $TGT.\"T3\"")"
eq "listed: exit 0" 0 "$(run "$(mkcfg l 'TABLES="T3"' 'FULL_COPY_TABLES="T3"')")"
eq "listed: whole table replaced (3 rows)" 3 "$(q "select count(*) from $TGT.\"T3\"")"
eq "listed: old rows gone" 0 "$(q "select count(*) from $TGT.\"T3\" where \"ID\" in (90,91)")"
eq "listed: backup holds the 2 old rows" 2 "$(q "select count(*) from $BAK.\"$(q "select table_name from information_schema.tables where table_schema='$BAK' and table_name like 'T3%' limit 1")\"")"

echo "== J. SOURCE=TARGET table names"
q "CREATE TABLE $TGT.\"T1M\" (LIKE $TGT.\"T1\" INCLUDING DEFAULTS);" >/dev/null
eq "mapped names: exit 0" 0 "$(run "$(mkcfg m 'TABLES="T1=T1M"')")"
eq "mapped target filled (4 rows)" 4 "$(q "select count(*) from $TGT.\"T1M\"")"

echo "== cleanup"
q "DROP SCHEMA IF EXISTS $SRC CASCADE; DROP SCHEMA IF EXISTS $TGT CASCADE; DROP SCHEMA IF EXISTS $BAK CASCADE;" >/dev/null
eq "scratch schemas dropped" 0 "$(q "select count(*) from information_schema.schemata where schema_name in ('$SRC','$TGT','$BAK')")"

echo; echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
