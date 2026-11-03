-- Fake NEW CM table for the CM comparison test (see make_fake_cm_old.sql for the list of known differences).
--   E: only in NEW (object only on one side); NEWONLY: a column only in NEW
CREATE TABLE CM_TEST (CELL_NAME VARCHAR, INSERT_DT TIMESTAMP, BW DOUBLE, STATE VARCHAR, FREQ DOUBLE, NEWONLY VARCHAR);
INSERT INTO CM_TEST VALUES
  ('A', '2025-12-01 10:00:00', 20.000000001, 'ON',  100, 'y'),
  ('A', '2025-12-20 09:00:00', 77,           'OFF', 888, 'y'),
  ('B', '2025-12-01 10:00:00', 15,           'ON',  200, 'y'),
  ('C', '2025-12-01 10:00:00', 10,           'OFF', 300, 'y'),
  ('E', '2025-12-01 10:00:00', 7,            'ON',  70,  'y');
