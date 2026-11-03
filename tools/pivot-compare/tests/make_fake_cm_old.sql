-- Fake OLD CM table for the CM comparison test. Times are naive Sydney time (UTC+11); the test period ends 2025-12-19 09:15 UTC = 20:15.
-- Known facts (the CM report must show exactly these, together with make_fake_cm_new.sql):
--   A: same on both sides; a later CM row (2025-12-20, after the period) must be ignored; BW differs only by 1e-9 (inside the tolerance)
--   B: BW differs (10 against 15)             -> 1 DIFF
--   C: FREQ is NULL here, 300 in the new side  -> 1 NULL_OLD_ONLY
--   D: only in OLD (object only on one side)
--   OLDONLY: a column only in OLD
CREATE TABLE CM_TEST (CELL_NAME VARCHAR, INSERT_DT TIMESTAMP, BW DOUBLE, STATE VARCHAR, FREQ DOUBLE, OLDONLY VARCHAR);
INSERT INTO CM_TEST VALUES
  ('A', '2025-12-01 10:00:00', 20,  'ON',  100,  'x'),
  ('A', '2025-12-20 09:00:00', 99,  'OFF', 999,  'x'),
  ('B', '2025-12-01 10:00:00', 10,  'ON',  200,  'x'),
  ('C', '2025-12-01 10:00:00', 10,  'OFF', NULL, 'x'),
  ('D', '2025-12-01 10:00:00', 5,   'ON',  50,   'x');
