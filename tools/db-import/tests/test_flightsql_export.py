"""Logic tests for flightsql_export.py: no pyarrow, no API, no database needed.
Run: python3 tests/test_flightsql_export.py     (prints 'passed: N   failed: M')
"""
import datetime as dt
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import flightsql_export as fx  # noqa: E402

UTC = dt.timezone.utc


class T(unittest.TestCase):
    def test_sydney_midnight_is_13_utc_the_day_before(self):
        # 2026-10-25 is in Sydney daylight time (UTC+11)
        u = fx.local_to_utc(fx.parse_local("2026-10-25 00:00:00"), "Australia/Sydney")
        self.assertEqual(u, dt.datetime(2026, 10, 24, 13, 0, tzinfo=UTC))

    def test_winter_offset_is_10(self):
        u = fx.local_to_utc(fx.parse_local("2026-07-01 00:00:00"), "Australia/Sydney")
        self.assertEqual(u, dt.datetime(2026, 6, 30, 14, 0, tzinfo=UTC))

    def test_worked_example_12_slices_and_literals(self):
        s = fx.make_slices(fx.parse_local("2026-10-25 00:00:00"), fx.parse_local("2026-10-25 02:00:00"),
                           10, "Australia/Sydney", "aware")
        self.assertEqual(len(s), 12)
        self.assertEqual(fx.literal("aware", s[0][0]), "TIMESTAMPTZ '2026-10-24 13:00:00+00'")
        self.assertEqual(fx.literal("aware", s[-1][1]), "TIMESTAMPTZ '2026-10-24 15:00:00+00'")
        for (a, b), (c, d) in zip(s, s[1:]):
            self.assertEqual(b, c)          # no gap, no overlap

    def test_the_tested_aware_window_query(self):
        # same text as the query that returned 40921 rows on dev (PLAN-FLIGHTSQL section 9, row 7)
        s = fx.make_slices(fx.parse_local("2026-10-25 00:00:00"), fx.parse_local("2026-10-25 02:00:00"),
                           1000, "Australia/Sydney", "aware")
        self.assertEqual(len(s), 1)
        self.assertEqual(
            fx.where_clause("aware", "PERIOD_START_TIME", s[0][0], s[0][1]),
            "PERIOD_START_TIME >= TIMESTAMPTZ '2026-10-24 13:00:00+00' AND PERIOD_START_TIME < TIMESTAMPTZ '2026-10-24 15:00:00+00'")

    def test_the_tested_naive_window_query(self):
        s = fx.make_slices(fx.parse_local("2025-12-19 17:00:00"), fx.parse_local("2025-12-19 18:00:00"),
                           60, "Australia/Sydney", "naive")
        self.assertEqual(
            fx.where_clause("naive", "period_start_time", s[0][0], s[0][1]),
            "period_start_time >= CAST('2025-12-19 17:00:00' AS TIMESTAMP) AND period_start_time < CAST('2025-12-19 18:00:00' AS TIMESTAMP)")

    def test_dst_start_day_has_23_hours(self):
        # Sydney clocks go forward on 2026-10-04: that local day lasts 23 hours
        s = fx.make_slices(fx.parse_local("2026-10-04 00:00:00"), fx.parse_local("2026-10-05 00:00:00"),
                           60, "Australia/Sydney", "aware")
        self.assertEqual(len(s), 23)

    def test_dst_end_day_has_25_hours(self):
        s = fx.make_slices(fx.parse_local("2026-04-05 00:00:00"), fx.parse_local("2026-04-06 00:00:00"),
                           60, "Australia/Sydney", "aware")
        self.assertEqual(len(s), 25)

    def test_last_slice_is_shorter_when_not_divisible(self):
        s = fx.make_slices(fx.parse_local("2025-12-19 17:00:00"), fx.parse_local("2025-12-19 17:25:00"),
                           10, "UTC", "naive")
        self.assertEqual([(b - a).seconds // 60 for a, b in s], [10, 10, 5])

    def test_naive_slices_follow_the_wall_clock(self):
        s = fx.make_slices(fx.parse_local("2025-12-19 17:00:00"), fx.parse_local("2025-12-19 18:00:00"),
                           30, "Australia/Sydney", "naive")
        self.assertEqual([x[0].strftime("%H:%M") for x in s], ["17:00", "17:30"])

    def test_classify(self):
        self.assertEqual(fx.classify("timestamp[us, tz=Etc/UTC]"), "aware")
        self.assertEqual(fx.classify("timestamp[us, tz=UTC]"), "aware")
        self.assertEqual(fx.classify("timestamp[us]"), "naive")
        self.assertEqual(fx.classify("date32[day]"), "other")
        self.assertEqual(fx.classify("string"), "other")

    def test_find_time_column_ignores_case(self):
        f = [("SITE_ID", "int64"), ("period_start_time", "timestamp[us]")]
        self.assertEqual(fx.find_time_column(f, "PERIOD_START_TIME"), ("period_start_time", "naive"))
        f = [("PERIOD_START_TIME", "timestamp[us, tz=Etc/UTC]")]
        self.assertEqual(fx.find_time_column(f, "period_start_time"), ("PERIOD_START_TIME", "aware"))

    def test_find_time_column_refuses(self):
        with self.assertRaises(fx.HelperError):
            fx.find_time_column([("A", "int64")], "PERIOD_START_TIME")
        with self.assertRaises(fx.HelperError):
            fx.find_time_column([("PERIOD_START_TIME", "string")], "PERIOD_START_TIME")

    def test_bad_inputs(self):
        for bad in ("2026-13-01 00:00:00", "yesterday", "2026-10-25"):
            with self.assertRaises(fx.HelperError):
                fx.parse_local(bad)
        with self.assertRaises(fx.HelperError):
            fx.make_slices(fx.parse_local("2026-10-25 02:00:00"), fx.parse_local("2026-10-25 02:00:00"), 10, "UTC", "naive")
        with self.assertRaises(fx.HelperError):
            fx.make_slices(fx.parse_local("2026-10-25 00:00:00"), fx.parse_local("2026-10-25 02:00:00"), 0, "UTC", "naive")
        with self.assertRaises(fx.HelperError):
            fx.local_to_utc(fx.parse_local("2026-10-25 00:00:00"), "Mars/Base")

    def test_identifiers_and_table_ref(self):
        self.assertEqual(fx.table_ref("gsb_data_kpi_pivot_dev_V2", "KPI_NS_QRLY_NODE_CEM_ERS_NEW_P"),
                         'gsb_data_kpi_pivot_dev_V2."KPI_NS_QRLY_NODE_CEM_ERS_NEW_P"')
        for bad in ("a b", "a;drop", "a-b", "", "1abc", 'a"b'):
            with self.assertRaises(fx.HelperError):
                fx.check_ident("x", bad)
        for bad in ('T"X', "T'X", "T;X"):
            with self.assertRaises(fx.HelperError):
                fx.table_ref("s", bad)

    def test_the_api_rewrite_does_not_match_our_literals(self):
        # the API's own pattern (src/services/timezone_utils.py _PERIOD_TS_PATTERN, copied from origin/main)
        import re
        pat = re.compile(r'("?PERIOD_START_TIME"?\s*(?:>=|<=|>|<|=)\s*(?:TIMESTAMP\s+)?[\'"])([^\'"]+)([\'"])', re.IGNORECASE)
        a = fx.where_clause("aware", "PERIOD_START_TIME", dt.datetime(2026, 10, 24, 13, tzinfo=UTC), dt.datetime(2026, 10, 24, 14, tzinfo=UTC))
        n = fx.where_clause("naive", "period_start_time", dt.datetime(2025, 12, 19, 17), dt.datetime(2025, 12, 19, 18))
        self.assertIsNone(pat.search(a))
        self.assertIsNone(pat.search(n))
        # and the forms that are NOT safe do match, so this test would notice a change of the pattern's meaning
        self.assertIsNotNone(pat.search("PERIOD_START_TIME >= '2026-10-24 13:00:00'"))
        self.assertIsNotNone(pat.search("PERIOD_START_TIME >= TIMESTAMP '2026-10-24T13:00:00Z'"))

    def test_slice_file_names_sort_in_order(self):
        names = [fx.slice_file_name(i, "aware", dt.datetime(2026, 1, 1, tzinfo=UTC)) for i in (1, 2, 10, 100)]
        self.assertEqual(names, sorted(names))


if __name__ == "__main__":
    res = unittest.TextTestRunner(verbosity=0).run(unittest.defaultTestLoader.loadTestsFromTestCase(T))
    ok = res.testsRun - len(res.failures) - len(res.errors)
    print("passed: %d   failed: %d" % (ok, len(res.failures) + len(res.errors)))
    sys.exit(0 if res.wasSuccessful() else 1)
