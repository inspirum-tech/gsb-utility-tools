-- Fake data for the info-columns test (INFO_COMPARE). Run once per side by run_local_tests.sh (info_old.duckdb / info_new.duckdb):
-- the script creates both tables, the test reads only the one it needs from each file.
-- Period under test: 2025-12-19 09:00 UTC = 2025-12-19 20:00 Sydney. KPI values are equal on both sides on purpose.
-- Known facts (info columns SITE_NAME, CELL_NAME, LAC, TAC):
--   (1,1) all equal; TAC is 57252.00 in OLD and 57252 in NEW -> equal (numbers)
--   (1,2) CELL_NAME differs: 'c12' against 'c12-X'            -> 1 DIFF
--   (2,1) LAC is NULL in OLD, 200 in NEW                         -> 1 NULL_OLD_ONLY
--   (3,1) exists only in NEW                                     -> not an info value (not an object on both sides)
CREATE OR REPLACE TABLE info_old (
  PERIOD_START_TIME TIMESTAMP, SITE_ID INTEGER, CELL_ID INTEGER, SITE_NAME VARCHAR, CELL_NAME VARCHAR,
  LAC DECIMAL(10,2), TAC DECIMAL(10,2), K_1 DECIMAL(30,10));
INSERT INTO info_old VALUES
  ('2025-12-19 20:00:00', 1, 1, 's1', 'c11', 100, 57252, 1),
  ('2025-12-19 20:00:00', 1, 2, 's1', 'c12', 100, 5, 2),
  ('2025-12-19 20:00:00', 2, 1, 's2', 'c21', NULL, 6, 3);

CREATE OR REPLACE TABLE info_new (
  PERIOD_START_TIME TIMESTAMPTZ, SITE_ID BIGINT, CELL_ID BIGINT, SITE_NAME VARCHAR, CELL_NAME VARCHAR,
  LAC BIGINT, TAC BIGINT, K_1 DOUBLE);
INSERT INTO info_new VALUES
  ('2025-12-19 09:00:00+00', 1, 1, 's1', 'c11', 100, 57252, 1),
  ('2025-12-19 09:00:00+00', 1, 2, 's1', 'c12-X', 100, 5, 2),
  ('2025-12-19 09:00:00+00', 2, 1, 's2', 'c21', 200, 6, 3),
  ('2025-12-19 09:00:00+00', 3, 1, 's3', 'c31', 300, 7, 9);
