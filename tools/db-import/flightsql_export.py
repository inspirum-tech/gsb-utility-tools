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
  probe   read the table structure (SELECT ... LIMIT 0); with --count also count the rows of the
          window, in chunks of --count-minutes (one count(*) over days of data times out on the
          big tables; a count costs about as much as the read itself, so it is off by default)
  export  probe, then read the window slice by slice and write the parquet files. A slice that comes
          back with --max-rows rows (the API's cap, which cuts silently) is read again in pages of
          half the cap with ORDER BY ALL LIMIT/OFFSET and checked against count(*) (--split-on-cap);
          without that option the slice fails (exit 3). RESUMES: a slice
          whose file is already in the folder (same table, window, time zone and slice length,
          recorded in _PLAN.json) is kept and not asked again; only the missing slices are read.
          A folder made for another window / slice length is refused (use --overwrite or another folder).

Every query is retried (--retries, waiting --retry-wait seconds, doubled each time) when the API
times out or the connection drops; the connection is re-opened before the retry. Other errors
(bad SQL, unknown table) are not retried.

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
TRANSIENT = ("deadline exceeded", "timeout", "timed out", "unavailable", "connection reset", "broken pipe",
             "connection refused", "eof", "goaway", "transport", "socket closed", "cancelled", "canceled")


def is_transient(text):
    """True for errors worth a retry (time limit, tunnel or network hiccup)."""
    t = str(text).lower()
    return any(k in t for k in TRANSIENT)


def retry_waits(retries, first_wait):
    """Seconds to wait before retry 1..n: first_wait, doubled each time."""
    return [first_wait * (2 ** i) for i in range(max(0, retries))]


class Api:
    """One connection to the API that re-opens itself and retries transient failures."""

    def __init__(self, host, port, timeout, retries=3, retry_wait=5.0, max_msg_mb=1024):
        self.host, self.port, self.timeout = host, port, timeout
        self.retries, self.retry_wait, self.max_msg_mb = retries, retry_wait, max_msg_mb
        self.con = None
        self.connect()

    def connect(self):
        self.close()
        try:
            import adbc_driver_flightsql.dbapi as fl
        except ImportError as e:
            raise HelperError("adbc_driver_flightsql / pyarrow are not installed (%s). On a machine without internet use the bundle/pylibs folder." % e, 4)
        secs = str(int(self.timeout))
        opts = {"adbc.flight.sql.rpc.timeout_seconds.fetch": secs,
                "adbc.flight.sql.rpc.timeout_seconds.query": secs,
                # the API sends a whole slice as one gRPC message; the driver's default limit is 16 MiB
                # ("received message larger than max"), a 15-minute slice of a wide table is bigger
                "adbc.flight.sql.client_option.with_max_msg_size": str(int(self.max_msg_mb) * 1024 * 1024)}
        try:
            self.con = fl.connect("grpc://%s:%s" % (self.host, self.port), db_kwargs=opts)
        except Exception as e:
            raise HelperError("cannot connect to the Flight SQL API at %s:%s: %s" % (self.host, self.port, str(e)[:300]), 4)

    def close(self):
        if self.con is not None:
            try:
                self.con.close()
            except Exception:
                pass
            self.con = None

    def run_once(self, sql):
        cur = self.con.cursor()
        try:
            cur.execute(sql)
            return cur.fetch_arrow_table()
        finally:
            cur.close()

    def run(self, sql):
        waits = retry_waits(self.retries, self.retry_wait)
        attempt = 0
        while True:
            try:
                return self.run_once(sql)
            except Exception as e:
                text = str(e)
                if attempt >= len(waits) or not is_transient(text):
                    what = "after %d retries " % attempt if attempt else ""
                    raise HelperError("the API rejected or failed a query %s: %s | %s" % (what, text[:300], sql[:200]), 4)
                err("  retry %d of %d in %gs (%s)" % (attempt + 1, len(waits), waits[attempt], text[:120].replace("\n", " ")))
                time.sleep(waits[attempt])
                attempt += 1
                try:
                    self.connect()
                except HelperError as ce:
                    err("  reconnect failed: %s" % ce)   # the next loop turn raises or retries again


def probe(con, args):
    """-> (real time column name, kind, number of columns)"""
    ref = table_ref(args.schema, args.table)
    schema = con.run("SELECT * FROM %s LIMIT 0" % ref).schema
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
    """count(*) of the window in chunks of --count-minutes (default: the export slice), summed.
    One count over days of a big table exceeds the API time limit; a 15-minute chunk never does."""
    from_l, to_l = parse_local(args.from_local), parse_local(args.to_local)
    minutes = args.count_minutes or args.slice_minutes
    chunks = make_slices(from_l, to_l, minutes, args.timezone, kind)
    ref = table_ref(args.schema, args.table)
    n, started = 0, time.time()
    for i, (lo, hi) in enumerate(chunks, 1):
        sql = "SELECT count(*) AS n FROM %s WHERE %s" % (ref, where_clause(kind, col, lo, hi))
        n += con.run(sql).to_pylist()[0]["n"]
        if i % 50 == 0 or i == len(chunks):
            err("  counted %d of %d chunks: %d rows so far (%.0fs)" % (i, len(chunks), n, time.time() - started))
    print("COUNT,%d" % n, flush=True)
    return n


PLAN_FILE, DONE_FILE = "_PLAN.json", "_DONE"


def export_plan(args, col, kind):
    """What the files in the folder stand for. Two exports may share a folder only if this is equal."""
    return {"schema": args.schema, "table": args.table, "time_column": col, "kind": kind,
            "from_local": args.from_local, "to_local": args.to_local, "timezone": args.timezone,
            "slice_minutes": args.slice_minutes}


def existing_export(out_dir, plan, overwrite):
    """Decide what to do with a folder that already holds files.
    -> 'empty' (nothing there), 'resume' (same plan: keep the slice files), or raises.
    overwrite=True wipes the folder and returns 'empty'."""
    if not os.path.isdir(out_dir):
        return "empty"
    files = os.listdir(out_dir)
    has_data = any(f.endswith(".parquet") or f == DONE_FILE for f in files)
    if overwrite:
        for f in files:
            if f.endswith(".parquet") or f.endswith(".tmp") or f in (DONE_FILE, PLAN_FILE):
                os.remove(os.path.join(out_dir, f))
        return "empty"
    if not has_data:
        return "empty"
    plan_path = os.path.join(out_dir, PLAN_FILE)
    if not os.path.isfile(plan_path):
        raise HelperError("%s already holds parquet files but no %s (an export made by an older version, or not by this tool). "
                          "Use another EXPORT_DIR, or set EXPORT_OVERWRITE=\"yes\" to replace them (helper option: --overwrite)" % (out_dir, PLAN_FILE), 5)
    with open(plan_path) as fh:
        old = json.load(fh)
    if old != plan:
        diff = ", ".join("%s: %s -> %s" % (k, old.get(k), plan.get(k)) for k in sorted(set(old) | set(plan)) if old.get(k) != plan.get(k))
        raise HelperError("%s holds an export of another window or slice length (%s). Use another EXPORT_DIR, or set "
                          "EXPORT_OVERWRITE=\"yes\" to replace it (helper option: --overwrite)" % (out_dir, diff), 5)
    return "resume"


def page_size(max_rows):
    """Pages are half the cap, so a full page is never mistaken for a cut one."""
    return max(1, max_rows // 2)


def read_in_pages(con, ref, where, max_rows):
    """A slice that reached the API's row cap, read again in pages of max_rows/2 rows with a fixed order
    (ORDER BY ALL), then checked against count(*) of the same slice: the pages must add up exactly.
    One time stamp cannot be split by time, so this is the only way to read it completely."""
    import pyarrow as pa
    size, offset, parts = page_size(max_rows), 0, []
    while True:
        part = con.run("SELECT * FROM %s WHERE %s ORDER BY ALL LIMIT %d OFFSET %d" % (ref, where, size, offset))
        parts.append(part)
        offset += part.num_rows
        if part.num_rows < size:
            break
    table = pa.concat_tables(parts)
    expected = con.run("SELECT count(*) AS n FROM %s WHERE %s" % (ref, where)).to_pylist()[0]["n"]
    if table.num_rows != expected:
        raise HelperError("paged read of a slice gave %d rows but count(*) says %d (the data changed while it was read, or the "
                          "API did not honour LIMIT/OFFSET). Nothing was imported; run again." % (table.num_rows, expected), 3)
    err("  paged read complete: %d rows in %d pages of up to %d, equal to count(*)" % (table.num_rows, len(parts), size))
    return table


def export(con, args, col, kind):
    import pyarrow.parquet as pq
    ref = table_ref(args.schema, args.table)
    out_dir = os.path.join(args.out_dir, args.table)
    plan = export_plan(args, col, kind)
    state = existing_export(out_dir, plan, args.overwrite)
    os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):                       # a half-written slice from a run that was killed
        if f.endswith(".tmp"):
            os.remove(os.path.join(out_dir, f))
    with open(os.path.join(out_dir, PLAN_FILE), "w") as fh:
        json.dump(plan, fh)

    slices = make_slices(parse_local(args.from_local), parse_local(args.to_local), args.slice_minutes, args.timezone, kind)
    total, kept, fetched = 0, 0, 0
    for i, (lo, hi) in enumerate(slices, 1):
        final = os.path.join(out_dir, slice_file_name(i, kind, lo))
        if state == "resume" and os.path.isfile(final):
            n = pq.read_metadata(final).num_rows
            total += n; kept += 1
            print("SLICE,%d,%d,%d,kept" % (i, len(slices), n), flush=True)
            continue
        where = where_clause(kind, col, lo, hi)
        table = con.run("SELECT * FROM %s WHERE %s" % (ref, where))
        n, how = table.num_rows, "new"
        if n >= args.max_rows:
            # the API cuts a result at its row cap silently: this slice may be incomplete
            if not args.split_on_cap:
                raise HelperError(
                    "slice %d of %d (%s) returned %d rows, which is the row cap (%d): the API may have cut the result. "
                    "Nothing was imported. Lower FLIGHT_SLICE_MINUTES (now %d) and run again."
                    % (i, len(slices), lo.strftime(FMT), n, args.max_rows, args.slice_minutes), 3)
            err("  slice %d of %d (%s): %d rows = the API row cap, the result may be cut: reading it again in pages"
                % (i, len(slices), lo.strftime(FMT), n))
            table = read_in_pages(con, ref, where, args.max_rows)
            n, how = table.num_rows, "paged"
        tmp = final + ".tmp"
        pq.write_table(table, tmp)
        os.replace(tmp, final)             # a slice file is either complete or absent
        total += n; fetched += 1
        print("SLICE,%d,%d,%d,%s" % (i, len(slices), n, how), flush=True)
        if i < len(slices) and args.pause_seconds > 0:
            time.sleep(args.pause_seconds)
    if kept:
        err("  %s: %d slice(s) were already on disk from an earlier run and were kept, %d read from the API" % (args.table, kept, fetched))
    with open(os.path.join(out_dir, DONE_FILE), "w") as fh:
        json.dump(dict(plan, slices=len(slices), rows=total, kept=kept, fetched=fetched,
                       finished_utc=dt.datetime.now(UTC).strftime(FMT)), fh)
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
    p.add_argument("--slice-minutes", type=int, default=15)
    p.add_argument("--count-minutes", type=int, default=0, help="probe: chunk size of the count(*); 0 = --slice-minutes")
    p.add_argument("--pause-seconds", type=float, default=2)
    p.add_argument("--max-rows", type=int, default=100000)
    p.add_argument("--timeout-seconds", type=int, default=120)
    p.add_argument("--retries", type=int, default=3, help="retries of a query after a time limit or network error")
    p.add_argument("--max-msg-mb", type=int, default=1024, help="largest gRPC message the client accepts, in MiB (driver default 16)")
    p.add_argument("--split-on-cap", action="store_true", help="a slice that reaches --max-rows is read again in pages and checked with count(*), instead of failing")
    p.add_argument("--retry-wait", type=float, default=5, help="seconds before the first retry; doubled each time")
    p.add_argument("--out-dir", help="export only: parent folder; files go to <out-dir>/<table>/")
    p.add_argument("--overwrite", action="store_true")
    p.add_argument("--count", action="store_true", help="probe only: also count the rows of the window (chunked)")
    p.add_argument("--no-count", action="store_true", help="(kept for old callers: counting is off by default)")
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
        if args.count_minutes < 0 or args.retries < 0 or args.retry_wait < 0:
            raise HelperError("--count-minutes, --retries and --retry-wait must be 0 or more")
        if args.max_msg_mb < 16:
            raise HelperError("--max-msg-mb must be 16 or more")
        con = Api(args.host, args.port, args.timeout_seconds, args.retries, args.retry_wait, args.max_msg_mb)
        try:
            col, kind, _ = probe(con, args)
            if args.command == "probe":
                if args.count and not args.no_count:
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
