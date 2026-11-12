-- Fake OLD tables for group T (periods, repeated rows, PASS rule). Same layout as old_pivot in make_fake_data.sql.
-- Times are Sydney time (UTC+11 in December): 20:00 = 09:00 UTC, 20:15 = 09:15 UTC.
--   t_old_conf   object (1,1) appears twice at 09:00 with K_1 = 10 and 12 (CONFLICTING repeat), K_2 = 5 twice (equal repeat)
--   t_old_same   object (1,1) appears twice at 09:00 with identical values (a harmless repeat)
--   t_old_per    periods 09:00 and 09:15 (the NEW table holds 09:00 and 09:30)
--   t_old_extra  same values as t_old_same without the repeat, plus a KPI column K_9 that the NEW side does not have
CREATE OR REPLACE TABLE t_old_conf (PERIOD_START_TIME TIMESTAMP, SITE_ID INTEGER, CELL_ID INTEGER, K_1 DECIMAL(30,10), K_2 DECIMAL(30,10));
INSERT INTO t_old_conf VALUES
  ('2025-12-19 20:00:00', 1, 1, 10, 5), ('2025-12-19 20:00:00', 1, 1, 12, 5), ('2025-12-19 20:00:00', 2, 1, 7, 8);

CREATE OR REPLACE TABLE t_old_same (PERIOD_START_TIME TIMESTAMP, SITE_ID INTEGER, CELL_ID INTEGER, K_1 DECIMAL(30,10), K_2 DECIMAL(30,10));
INSERT INTO t_old_same VALUES
  ('2025-12-19 20:00:00', 1, 1, 12, 5), ('2025-12-19 20:00:00', 1, 1, 12, 5), ('2025-12-19 20:00:00', 2, 1, 7, 8);

CREATE OR REPLACE TABLE t_old_per (PERIOD_START_TIME TIMESTAMP, SITE_ID INTEGER, CELL_ID INTEGER, K_1 DECIMAL(30,10), K_2 DECIMAL(30,10));
INSERT INTO t_old_per VALUES
  ('2025-12-19 20:00:00', 1, 1, 12, 5), ('2025-12-19 20:00:00', 2, 1, 7, 8), ('2025-12-19 20:15:00', 1, 1, 12, 5);

CREATE OR REPLACE TABLE t_old_extra (PERIOD_START_TIME TIMESTAMP, SITE_ID INTEGER, CELL_ID INTEGER, K_1 DECIMAL(30,10), K_2 DECIMAL(30,10), K_9 DECIMAL(30,10));
INSERT INTO t_old_extra VALUES
  ('2025-12-19 20:00:00', 1, 1, 12, 5, 1), ('2025-12-19 20:00:00', 2, 1, 7, 8, 1);
