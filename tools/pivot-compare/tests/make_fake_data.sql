-- Fake data for the local test. Run twice by run_local_tests.sh: once against old.duckdb, once against new.duckdb.
-- The OLD side is a wide pivot with times in Sydney time (UTC+11 in December), the NEW side a tall table with timestamptz.
-- Period under test: 2025-12-19 09:00 UTC = 2025-12-19 20:00 Sydney.
--
-- KNOWN differences (the test must report exactly these):
--   1. missing row ........ object (3,1) exists only in OLD
--   2. extra row .......... object (4,1) exists only in NEW
--   3. one wrong value .... object (1,2), K_1: old 50, new 51
--   4. NULL against value . object (2,1), K_2: old NULL, new 7
--   5. rounding inside the tolerance: object (1,1), K_3: old 0.123456785, new 0.12345679 (difference 5e-9)
--   6. documented value rule: object (2,1), K_3: old -1, new NaN  -> equal (NaN is read as -1)
--   KPI column only in OLD: K_9      KPI column only in NEW: K_8
--   Rows that must be IGNORED: another period (old 20:15 Sydney, new 09:15 UTC) and another application in NEW.
CREATE OR REPLACE TABLE old_pivot (
  PERIOD_START_TIME TIMESTAMP, SITE_ID INTEGER, CELL_ID INTEGER, CELL_NAME VARCHAR,
  K_1 DECIMAL(30,10), K_2 DECIMAL(30,10), K_3 DECIMAL(30,10), K_9 DECIMAL(30,10));
INSERT INTO old_pivot VALUES
  ('2025-12-19 20:00:00', 1, 1, 'c11', 10, 20, 0.123456785, 1),
  ('2025-12-19 20:00:00', 1, 2, 'c12', 50, 21, 31, 1),
  ('2025-12-19 20:00:00', 2, 1, 'c21', 5, NULL, -1, 1),
  ('2025-12-19 20:00:00', 3, 1, 'c31', 1, 1, 1, 1),
  ('2025-12-19 20:15:00', 9, 9, 'c99', 1, 1, 1, 1);

-- AUTO mode (test I): the old tables are found by the family name rule KPI_<APPLICATION>_<RES>_<LEVEL>_<TECH>_<VENDOR>_P.
--   LTE family: the data above (6 known differences)          -> DIFFERENT
--   5G family : same objects as NEW, K_8 equal everywhere      -> IDENTICAL
--   NR family : defined, but there is no old table             -> SKIPPED
--   a _BKP copy of the LTE table must never be picked up
CREATE OR REPLACE TABLE KPI_APP_TEST_QRLY_CELL_LTE_ERS_P AS SELECT * FROM old_pivot;
CREATE OR REPLACE TABLE KPI_APP_TEST_QRLY_CELL_LTE_ERS_P_BKP AS SELECT * FROM old_pivot;
CREATE OR REPLACE TABLE KPI_APP_TEST_QRLY_CELL_5G_ERS_P (
  PERIOD_START_TIME TIMESTAMP, SITE_ID INTEGER, CELL_ID INTEGER, K_8 DECIMAL(30,10));
INSERT INTO KPI_APP_TEST_QRLY_CELL_5G_ERS_P VALUES
  ('2025-12-19 20:00:00', 1, 1, 1), ('2025-12-19 20:00:00', 1, 2, 1),
  ('2025-12-19 20:00:00', 2, 1, 1), ('2025-12-19 20:00:00', 4, 1, 1);
