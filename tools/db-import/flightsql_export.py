#!/usr/bin/env python3
"""flightsql_export.py - helper of db-import.sh for SOURCE_TYPE="flightsql".

Reads ONE table from the gsb-kpi-data-api Flight SQL interface in small time slices and
writes one parquet file per slice into a local folder. db-import.sh then reads those
files with its normal parquet path (and they can be re-imported later with
SOURCE_TYPE="parquet", without asking the API again).

Standalone: only the Python standard library plus `pyarrow` and `adbc-driver-flightsql`
(the last two are imported only when the API is really called; they come from
bundle/pylibs on a machine without internet). Python 3.9 or newer.

Commands (all read-only towards the API):
  probe   read the table structure (SELECT ... LIMIT 0) and one count(*) of the window
  export  probe, then read the window slice by slice and write the parquet files

Output lines on stdout (machine readable, one per line):
  TYPE,<aware|naive>   COLUMN,<name>   NCOLS,<n>   SCOL,<column name> (one per column)
  COUNT,<n>   SLICE,<i>,<of>,<rows>   TOTAL,<rows>
Messages for people go to stderr. Exit codes:
  0 ok   2 bad arguments / unsupported table   3 a slice reached the row cap (cut result)
  4 connection or query error   5 output folder already holds files (use --overwrite)

Why the filter is written the way it is (proven on dev, see PLAN-FLIGHTSQL.md section 9):
the API rewrites plain and "Z" literals of the column PERIOD_START_TIME (UTC -> Sydney), which
shifts the window by 11 hours on a time-zone-aware column. So the helper never sends those:
  time-zone-aware column:  col >= TIMESTAMPTZ 'YYYY-MM-DD HH:MM:SS+00'   (an exact UTC instant)
  naive column:            col >= CAST('YYYY-MM-DD HH:MM:SS' AS TIMESTAMP) (local time as written)
Neither form is matched by the API's rewrite, so it behaves the same on every API version.
"""
import argparse
import datetime as dt
import json
import os
import re
import sys
import time
import warnings
from zoneinfo import ZoneInfo

# the ADBC driver manager prints this harmless notice on every connect
warnings.filterwarnings("ignore", message="Cannot disable autocommit")

UTC = dt.timezone.utc
IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
FMT = "%Y-%m-%d %H:%M:%S"


class HelperError(Exception):
    def __init__(self, message, code=2):
        super().__init__(message)
        self.code = code


def err(msg):
    print(msg, file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------------------------
# pure logic (tested without pyarrow and without the API: tests/test_flightsql_export.py)
# ---------------------------------------------------------------------------------------------
def check_ident(what, value):
    if not IDENT.match(value or ""):
        raise HelperError("%s '%s' is not a plain name (letters, digits, underscore)" % (what, value))
    return value


def parse_local(text):
    """'YYYY-MM-DD HH:MM:SS' (also 'T' instead of the space) -> naive datetime."""
    try:
        return dt.datetime.strptime(text.strip().replace("T", " "), FMT)
    except ValueError:
        raise HelperError("time '%s' must look like YYYY-MM-DD HH:MM:SS" % text)


def local_to_utc(naive, tz_name):
    """A local wall-clock time in tz_name -> the UTC instant (aware)."""
    try:
        zone = ZoneInfo(tz_name)
    except Exception:
        raise HelperError("unknown time zone '%s'" % tz_name)
    return naive.replace(tzinfo=zone).astimezone(UTC)


def classify(type_text):
    """Arrow type as text -> 'aware' (timestamp with a time zone), 'naive' (timestamp without) or 'other'."""
    t = str(type_text)
    if t.startswith("timestamp["):
        return "aware" if "tz=" in t else "naive"
    return "other"


def find_time_column(fields, wanted):
    """fields: list of (name, type text). Case-insensitive. Returns (real name, kind)."""
    for name, typ in fields:
        if name.lower() == wanted.lower():
            kind = classify(typ)
            if kind == "other":
                raise HelperError("time column '%s' has type %s: only timestamp columns are supported" % (name, typ))
            return name, kind
    raise HelperError("the table has no time column '%s' (set TIME_COLUMN or TABLE_TIME_COLUMNS)" % wanted)


def make_slices(from_local, to_local, minutes, tz_name, kind):
    """The window [from_local, to_local) cut into slices of `minutes`.
    aware: slices on the UTC axis (exact instants, DST-correct), returned as aware UTC datetimes.
    naive: slices on the local wall clock, returned as naive datetimes."""
    if minutes < 1:
        raise HelperError("slice minutes must be 1 or more")
    if not from_local < to_local:
        raise HelperError("the period start must be earlier than its end")
    if kind == "aware":
        lo, hi = local_to_utc(from_local, tz_name), local_to_utc(to_local, tz_name)
    else:
        lo, hi = from_local, to_local
    step, out = dt.timedelta(minutes=minutes), []
    while lo < hi:
        nxt = min(lo + step, hi)
        out.append((lo, nxt))
        lo = nxt
    return out


def literal(kind, value):
    if kind == "aware":
        return "TIMESTAMPTZ '%s+00'" % value.astimezone(UTC).strftime(FMT)
    return "CAST('%s' AS TIMESTAMP)" % value.strftime(FMT)


def where_clause(kind, col, lo, hi):
    return "%s >= %s AND %s < %s" % (col, literal(kind, lo), col, literal(kind, hi))


def table_ref(schema, table):
    check_ident("schema", schema)
    if '"' in table or "'" in table or ";" in table:
        raise HelperError("table name '%s' has a character that is not allowed" % table)
    return '%s."%s"' % (schema, table)


def slice_file_name(index, kind, lo):
    return "%05d_%s.parquet" % (index, lo.strftime("%Y%m%dT%H%M%S") + ("Z" if kind == "aware" else ""))


# ---------------------------------------------------------------------------------------------
# the API (imports pyarrow / adbc only here)
# ---------------------------------------------------------------------------------------------
def connect(host, port, timeout):
    try:
        import adbc_driver_flightsql.dbapi as fl
    except ImportError as e:
        raise HelperError("adbc_driver_flightsql / pyarrow are not installed (%s). On a machine without internet use the bundle/pylibs folder." % e, 4)
    secs = str(int(timeout))
    opts = {"adbc.flight.sql.rpc.timeout_seconds.fetch": secs,
            "adbc.flight.sql.rpc.timeout_seconds.query": secs}
    try:
        return fl.connect("grpc://%s:%s" % (host, port), db_kwargs=opts)
    except Exception as e:
        raise HelperError("cannot connect to the Flight SQL API at %s:%s: %s" % (host, port, str(e)[:300]), 4)


def run(con, sql):
    cur = con.cursor()
    try:
        cur.execute(sql)
        return cur.fetch_arrow_table()
    except Exception as e:
        raise HelperError("the API rejected or failed a query: %s | %s" % (str(e)[:300], sql[:200]), 4)
    finally:
        cur.close()


def probe(con, args):
    """-> (real time column name, kind, number of columns)"""
    ref = table_ref(args.schema, args.table)
    schema = run(con, "SELECT * FROM %s LIMIT 0" % ref).schema
    fields = [(f.name, str(f.type)) for f in schema]
    name, kind = find_time_column(fields, args.time_column)
    print("TYPE,%s" % kind)
    print("COLUMN,%s" % name)
    print("NCOLS,%d" % len(fields))
    for fname, _ in fields:
        print("SCOL,%s" % fname)
    sys.stdout.flush()
    return name, kind, len(fields)


def window_count(con, args, col, kind):
    from_l, to_l = parse_local(args.from_local), parse_local(args.to_local)
    slices = make_slices(from_l, to_l, 100000000, args.timezone, kind)   # one slice = the whole window
    lo, hi = slices[0][0], slices[-1][1]
    sql = "SELECT count(*) AS n FROM %s WHERE %s" % (table_ref(args.schema, args.table), where_clause(kind, col, lo, hi))
    n = run(con, sql).to_pylist()[0]["n"]
    print("COUNT,%d" % n, flush=True)
    return n


def export(con, args, col, kind):
    import pyarrow.parquet as pq
    ref = table_ref(args.schema, args.table)
    out_dir = os.path.join(args.out_dir, args.table)
    if os.path.isdir(out_dir) and any(f.endswith(".parquet") or f == "_DONE" for f in os.listdir(out_dir)):
        if not args.overwrite:
            raise HelperError("%s already holds files from an earlier export. Use another EXPORT_DIR, or set EXPORT_OVERWRITE=\"yes\" in the config (helper option: --overwrite)" % out_dir, 5)
        for f in os.listdir(out_dir):
            if f.endswith(".parquet") or f.endswith(".tmp") or f == "_DONE":
                os.remove(os.path.join(out_dir, f))
    os.makedirs(out_dir, exist_ok=True)

    slices = make_slices(parse_local(args.from_local), parse_local(args.to_local), args.slice_minutes, args.timezone, kind)
    total = 0
    for i, (lo, hi) in enumerate(slices, 1):
        table = run(con, "SELECT * FROM %s WHERE %s" % (ref, where_clause(kind, col, lo, hi)))
        n = table.num_rows
        if n >= args.max_rows:
            raise HelperError(
                "slice %d of %d (%s) returned %d rows, which is the row cap (%d): the API may have cut the result. "
                "Nothing was imported. Lower FLIGHT_SLICE_MINUTES (now %d) and run again."
                % (i, len(slices), lo.strftime(FMT), n, args.max_rows, args.slice_minutes), 3)
        final = os.path.join(out_dir, slice_file_name(i, kind, lo))
        tmp = final + ".tmp"
        pq.write_table(table, tmp)
        os.replace(tmp, final)             # a slice file is either complete or absent
        total += n
        print("SLICE,%d,%d,%d" % (i, len(slices), n), flush=True)
        if i < len(slices) and args.pause_seconds > 0:
            time.sleep(args.pause_seconds)
    with open(os.path.join(out_dir, "_DONE"), "w") as fh:
        json.dump({"table": args.table, "schema": args.schema, "time_column": col, "kind": kind,
                   "from_local": args.from_local, "to_local": args.to_local, "timezone": args.timezone,
                   "slices": len(slices), "rows": total,
                   "finished_utc": dt.datetime.now(UTC).strftime(FMT)}, fh)
    print("TOTAL,%d" % total, flush=True)
    return total


# ---------------------------------------------------------------------------------------------
def parse_args(argv):
    p = argparse.ArgumentParser(description="db-import helper: read a table from the Flight SQL API in time slices")
    p.add_argument("command", choices=["probe", "export"])
    p.add_argument("--host", required=True)
    p.add_argument("--port", required=True)
    p.add_argument("--schema", required=True)
    p.add_argument("--table", required=True)
    p.add_argument("--time-column", default="PERIOD_START_TIME")
    p.add_argument("--from-local", required=True, help="period start 'YYYY-MM-DD HH:MM:SS' in --timezone")
    p.add_argument("--to-local", required=True, help="period end (not included)")
    p.add_argument("--timezone", default="Australia/Sydney")
    p.add_argument("--slice-minutes", type=int, default=10)
    p.add_argument("--pause-seconds", type=float, default=2)
    p.add_argument("--max-rows", type=int, default=100000)
    p.add_argument("--timeout-seconds", type=int, default=120)
    p.add_argument("--out-dir", help="export only: parent folder; files go to <out-dir>/<table>/")
    p.add_argument("--overwrite", action="store_true")
    p.add_argument("--no-count", action="store_true", help="probe only: skip the count(*) query")
    p.add_argument("--pylibs", help="folder with pyarrow and adbc-driver-flightsql (bundle/pylibs on an offline server)")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    if args.pylibs:
        sys.path.insert(0, args.pylibs)
    try:
        check_ident("schema", args.schema)
        check_ident("time column", args.time_column)
        parse_local(args.from_local), parse_local(args.to_local)
        if args.command == "export" and not args.out_dir:
            raise HelperError("export needs --out-dir")
        if args.max_rows < 1 or args.slice_minutes < 1:
            raise HelperError("--max-rows and --slice-minutes must be 1 or more")
        con = connect(args.host, args.port, args.timeout_seconds)
        try:
            col, kind, _ = probe(con, args)
            if args.command == "probe":
                if not args.no_count:
                    window_count(con, args, col, kind)
            else:
                export(con, args, col, kind)
        finally:
            con.close()
        return 0
    except HelperError as e:
        err("ERROR: %s" % e)
        return e.code


if __name__ == "__main__":
    sys.exit(main())
