"""Exporter contracts; CLI doubles keep tests independent of prod secrets/extensions."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile
import gzip
import csv
import io

EXPORT = Path(__file__).resolve().parents[1] / 'export-on-prod.sh'

class MixedExport(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.log = self.root / 'sql.log'
        self.init = self.root / 'secret init.sql'
        self.init.write_text("-- trusted secret\nATTACH 'ducklake:catalog' AS gsb (READ_ONLY);\n")
        self.duck = self.root / 'duckdb'
        self.duck.write_text('''#!/usr/bin/env python3
import os,sys
sql=sys.stdin.read()
with open(os.environ['SQL_LOG'],'a') as f: f.write(repr(sys.argv)+'\\n'+sql+'\\n')
if os.environ.get('WRITABLE'): sys.exit(1)
if 'information_schema' in sql: print('1')
elif 'COPY' in sql:
 if os.environ.get('FAIL_COPY'): sys.exit(1)
 print('PERIOD_START_TIME,SITE_ID,NOTE')
 print('2026-10-25 00:00:00,1,"hello, world"')
else: print('1')
''')
        self.duck.chmod(0o755)
        self.pg = self.root / 'psql'
        self.pg.write_text('''#!/usr/bin/env python3
import sys,os
sql=sys.argv[-1]
with open(os.environ['SQL_LOG'],'a') as f: f.write(sql+'\\n')
if sql.startswith('COPY'): print('PERIOD_START_TIME,SITE_ID,NOTE\\n2026-10-25 00:00:00,2,pg')
else: print('1')
''')
        self.pg.chmod(0o755)
        self.config = self.root / 'export.env'
        self.config.write_text(f'''PGHOST=host
PGUSER=reader
PGDATABASE=db
PSQL_BIN={self.pg}
DUCKDB_BIN={self.duck}
DUCKLAKE_INIT='{self.init}'
PERIOD_FROM=2026-10-25
PERIOD_TO='2026-10-25 01:00'
OUT_ROOT={self.root}/out
MIN_FREE_MB=0
''')

    def run_export(self, *args, **env):
        return subprocess.run(['bash', str(EXPORT), '--config', str(self.config), '--name', 'test', *args], text=True, capture_output=True, env={**os.environ, 'SQL_LOG': str(self.log), **env})

    def test_mixed_exports_route_qualified_sources_and_preserve_layout(self):
        p = self.run_export('--postgres-tables', 'control.A', '--ducklake-tables', 'pivot.B')
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertIn('RESULT_ROWS=2', p.stdout)
        sql = self.log.read_text()
        self.assertIn('"control"."A"', sql)
        self.assertIn('"gsb"."pivot"."B"', sql)
        self.assertIn('duckdb_databases()', sql)
        self.assertNotIn('INSTALL ', sql)
        self.assertNotIn('trusted secret', p.stdout+p.stderr)
        with zipfile.ZipFile(self.root/'out/test.zip') as z:
            files = [n for n in z.namelist() if n.endswith('.csv.gz')]
            self.assertEqual(len(files), 2)
            b = next(n for n in files if '/B/' in n)
            rows = list(csv.reader(io.StringIO(gzip.decompress(z.read(b)).decode())))
            self.assertEqual(rows[1][2], 'hello, world')

    def test_unqualified_explicit_names_rejected(self):
        p = self.run_export('--ducklake-tables', 'B')
        self.assertEqual(p.returncode, 2)
        self.assertIn('schema.table', p.stderr)

    def test_basename_collisions_case_insensitive(self):
        p = self.run_export('--postgres-tables', 'one.KPI', '--ducklake-tables', 'two.kpi')
        self.assertEqual(p.returncode, 2)
        self.assertIn('duplicate', p.stderr.lower())

    def test_duck_only_needs_no_postgres_configuration(self):
        with self.config.open('a') as f: f.write('PGHOST=\nPGUSER=\nPGDATABASE=\nPSQL_BIN=/not-installed\n')
        p = self.run_export('--ducklake-tables', 'pivot.B')
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)

    def test_runtime_rejects_writable_attachment_before_copy(self):
        p = self.run_export('--ducklake-tables', 'pivot.B', WRITABLE='1')
        self.assertEqual(p.returncode, 2, p.stdout+p.stderr)
        self.assertIn('read-only', p.stderr)
        self.assertNotIn('COPY', self.log.read_text())

    def test_resume_rejects_changed_source_and_init(self):
        p = self.run_export('--ducklake-tables', 'pivot.B', FAIL_COPY='1')
        self.assertEqual(p.returncode, 1, p.stdout+p.stderr)
        p = self.run_export('--ducklake-tables', 'other.B', '--resume')
        self.assertEqual(p.returncode, 2)
        self.assertIn('identity', p.stderr)
        self.init.write_text(self.init.read_text()+'-- changed\n')
        p = self.run_export('--ducklake-tables', 'pivot.B', '--resume')
        self.assertEqual(p.returncode, 2)
        self.assertIn('identity', p.stderr)

    def test_resume_same_source(self):
        p = self.run_export('--ducklake-tables', 'pivot.B', FAIL_COPY='1')
        self.assertEqual(p.returncode, 1)
        p = self.run_export('--ducklake-tables', 'pivot.B', '--resume')
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)

    def test_missing_init_fails_without_leaking_contents(self):
        self.init.unlink()
        p = self.run_export('--ducklake-tables', 'pivot.B')
        self.assertEqual(p.returncode, 2)
        self.assertIn('DUCKLAKE_INIT', p.stderr)

    def test_explicit_check_routes_both_sources(self):
        p = self.run_export('--postgres-tables', 'control.A', '--ducklake-tables', 'pivot.B', '--check')
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertIn('control.A: time column', p.stdout)
        self.assertIn('pivot.B: time column', p.stdout)
        self.assertFalse((self.root/'out/test.zip').exists())

    def test_legacy_case_collision_rejected(self):
        p = self.run_export('--tables', 'KPI,kpi')
        self.assertEqual(p.returncode, 2)
        self.assertIn('duplicate', p.stderr)

    def test_legacy_and_explicit_flags_are_not_silently_combined(self):
        p = self.run_export('--tables', 'A', '--ducklake-tables', 'pivot.B')
        self.assertEqual(p.returncode, 2)

    def test_resume_rejects_changed_postgres_endpoint(self):
        # A failed DuckLake chunk leaves the successful Postgres chunk in place.
        p = self.run_export('--postgres-tables', 'control.A', '--ducklake-tables', 'pivot.B', FAIL_COPY='1')
        self.assertEqual(p.returncode, 1)
        with self.config.open('a') as f: f.write('PGHOST=other-host\n')
        p = self.run_export('--postgres-tables', 'control.A', '--ducklake-tables', 'pivot.B', '--resume')
        self.assertEqual(p.returncode, 2)
        self.assertIn('identity', p.stderr)

    @unittest.skipUnless(os.environ.get('DUCKDB_TEST_BIN'), 'set DUCKDB_TEST_BIN to a CLI with DuckLake preinstalled')
    def test_real_ducklake_cli_roundtrip_and_writable_rejection(self):
        cli = os.environ['DUCKDB_TEST_BIN']
        catalog = self.root/'catalog.ducklake'
        setup = f"""LOAD ducklake;
ATTACH 'ducklake:{catalog}' AS gsb (DATA_PATH '{self.root}/data');
CREATE SCHEMA gsb.pivot;
CREATE TABLE gsb.pivot.B (PERIOD_START_TIME TIMESTAMP, SITE_ID INTEGER, NOTE VARCHAR);
INSERT INTO gsb.pivot.B VALUES ('2026-10-25',1,'hello, world');"""
        p = subprocess.run([cli, '-init', '/dev/null', '-batch', '-bail', ':memory:', '-c', setup], text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        with self.config.open('a') as f: f.write(f'DUCKDB_BIN={cli}\n')
        self.init.write_text(f"LOAD ducklake; ATTACH 'ducklake:{catalog}' AS gsb (READ_ONLY);\n")
        p = self.run_export('--ducklake-tables', 'pivot.B')
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertIn('RESULT_ROWS=1', p.stdout)
        with zipfile.ZipFile(self.root/'out/test.zip') as z:
            n = next(n for n in z.namelist() if n.endswith('.csv.gz'))
            rows = list(csv.reader(io.StringIO(gzip.decompress(z.read(n)).decode())))
            self.assertEqual(rows[1], ['2026-10-25 00:00:00', '1', 'hello, world'])
        self.init.write_text(f"LOAD ducklake; ATTACH 'ducklake:{catalog}' AS gsb;\n")
        p = self.run_export('--ducklake-tables', 'pivot.B', '--check')
        self.assertEqual(p.returncode, 2, p.stdout+p.stderr)
        self.assertIn('read-only', p.stderr)

if __name__ == '__main__': unittest.main()
