-- Throwaway Postgres fixture shaped like dev: a partitioned OLD pivot (unconstrained numeric K_ columns, naive Sydney time)
-- and the NEW tall table (timestamptz). Same fake values as make_fake_data*.sql, plus one large, precise number.
CREATE SCHEMA gsb_data_kpi_pivot;
CREATE SCHEMA gsb_data_kpi_base;
CREATE TABLE gsb_data_kpi_pivot."KPI_TEST_QRLY_CELL_LTE_ERS_P" (
  "PERIOD_START_TIME" timestamp NOT NULL, "SITE_ID" integer, "CELL_ID" integer, "SITE_NAME" varchar, "CELL_NAME" varchar,
  "LAC" numeric, "UPDATE_TIMESTAMP" timestamp, "K_1" numeric, "K_2" numeric, "K_3" numeric, "K_4" numeric, "K_9" numeric
) PARTITION BY RANGE ("PERIOD_START_TIME");
CREATE TABLE gsb_data_kpi_pivot."KPI_TEST_QRLY_CELL_LTE_ERS_P_P_20251219_2000" PARTITION OF gsb_data_kpi_pivot."KPI_TEST_QRLY_CELL_LTE_ERS_P"
  FOR VALUES FROM ('2025-12-19 20:00:00') TO ('2025-12-19 20:15:00');
CREATE TABLE gsb_data_kpi_pivot."KPI_TEST_QRLY_CELL_LTE_ERS_P_P_20251219_2015" PARTITION OF gsb_data_kpi_pivot."KPI_TEST_QRLY_CELL_LTE_ERS_P"
  FOR VALUES FROM ('2025-12-19 20:15:00') TO ('2025-12-19 20:30:00');
INSERT INTO gsb_data_kpi_pivot."KPI_TEST_QRLY_CELL_LTE_ERS_P" VALUES
  ('2025-12-19 20:00:00', 1, 1, 's1', 'c11', 5, now(), 10, 20, 0.123456785, 1234567.12345678, 1),
  ('2025-12-19 20:00:00', 1, 2, 's1', 'c12', 5, now(), 50, 21, 31, 0.5, 1),
  ('2025-12-19 20:00:00', 2, 1, 's2', 'c21', 5, now(), 5, NULL, -1, 0.5, 1),
  ('2025-12-19 20:00:00', 3, 1, 's3', 'c31', 5, now(), 1, 1, 1, 0.5, 1),
  ('2025-12-19 20:00:00', NULL, NULL, 'x', 'nokey', 5, now(), 1, 1, 1, 0.5, 1),
  ('2025-12-19 20:15:00', 9, 9, 's9', 'c99', 5, now(), 1, 1, 1, 0.5, 1);

CREATE TABLE gsb_data_kpi_base."KPI_CALCULATED" (
  "PERIOD_START_TIME" timestamptz, "SITE_ID" bigint, "CELL_ID" bigint, "KPI_ID" bigint, "KPI_VALUE" double precision, "APPLICATION" text);
INSERT INTO gsb_data_kpi_base."KPI_CALCULATED"
SELECT timestamptz '2025-12-19 09:00:00+00', s, c, kid, v, 'APP_TEST'
FROM (VALUES
  (1, 1, 1, 10.0::float8), (1, 1, 2, 20.0), (1, 1, 3, 0.12345679), (1, 1, 4, 1234567.12345678), (1, 1, 8, 1.0),
  (1, 2, 1, 51.0), (1, 2, 2, 21.0), (1, 2, 3, 31.0), (1, 2, 4, 0.5), (1, 2, 8, 1.0),
  (2, 1, 1, 5.0), (2, 1, 2, 7.0), (2, 1, 3, 'NaN'), (2, 1, 4, 0.5), (2, 1, 8, 1.0),
  (4, 1, 1, 1.0), (4, 1, 2, 1.0), (4, 1, 3, 1.0), (4, 1, 4, 0.5), (4, 1, 8, 1.0)
) t(s, c, kid, v);
INSERT INTO gsb_data_kpi_base."KPI_CALCULATED" VALUES
  ('2025-12-19 09:00:00+00', 1, 1, 1, 999.0, 'OTHER_APP'),
  ('2025-12-19 09:15:00+00', 9, 9, 1, 1.0, 'APP_TEST');
