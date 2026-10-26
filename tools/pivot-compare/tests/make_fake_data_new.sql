-- Fake NEW side (tall table), see make_fake_data.sql for the list of known differences.
CREATE OR REPLACE TABLE KPI_CALCULATED (
  PERIOD_START_TIME TIMESTAMPTZ, SITE_ID BIGINT, CELL_ID BIGINT, KPI_ID BIGINT, KPI_VALUE DOUBLE, APPLICATION VARCHAR);
INSERT INTO KPI_CALCULATED
SELECT TIMESTAMPTZ '2025-12-19 09:00:00+00', s, c, kid, v, 'APP_TEST'
FROM (VALUES
  (1, 1, 1, 10.0), (1, 1, 2, 20.0), (1, 1, 3, 0.12345679), (1, 1, 8, 1.0),
  (1, 2, 1, 51.0), (1, 2, 2, 21.0), (1, 2, 3, 31.0),        (1, 2, 8, 1.0),
  (2, 1, 1, 5.0),  (2, 1, 2, 7.0),  (2, 1, 3, 'NaN'::DOUBLE), (2, 1, 8, 1.0),
  (4, 1, 1, 1.0),  (4, 1, 2, 1.0),  (4, 1, 3, 1.0),         (4, 1, 8, 1.0)
) t(s, c, kid, v);
INSERT INTO KPI_CALCULATED VALUES
  ('2025-12-19 09:00:00+00', 1, 1, 1, 999.0, 'OTHER_APP'),
  ('2025-12-19 09:15:00+00', 9, 9, 1, 1.0, 'APP_TEST');
