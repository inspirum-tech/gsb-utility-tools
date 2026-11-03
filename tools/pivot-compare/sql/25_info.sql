-- Info columns (INFO_COLS, for example SITE_NAME, CELL_NAME, LAC, SAC, TAC): compared for the objects (period + key) that exist on
-- both sides. They are labels copied from CM or mapping data, not calculated, so this check is REPORTED SEPARATELY and never
-- changes the KPI verdict or the exit code. Needs wide sides (the info columns must be columns of the source table).
CREATE OR REPLACE TEMP TABLE info_cmp AS
SELECT o.p_utc, o.k, o.col, o.val AS ov, n.val AS nv,
  CASE
    WHEN o.val IS NULL AND n.val IS NULL THEN 'EQUAL'
    WHEN o.val IS NULL THEN 'NULL_OLD_ONLY'
    WHEN n.val IS NULL THEN 'NULL_NEW_ONLY'
    WHEN trim(o.val) = trim(n.val) THEN 'EQUAL'
    WHEN try_cast(o.val AS DOUBLE) IS NOT NULL AND try_cast(n.val AS DOUBLE) IS NOT NULL
         AND try_cast(o.val AS DOUBLE) = try_cast(n.val AS DOUBLE) THEN 'EQUAL'
    ELSE 'DIFF'
  END AS kind
FROM old_info o JOIN new_info n ON o.p_utc = n.p_utc AND o.k = n.k AND o.col = n.col;

CREATE OR REPLACE TEMP TABLE info_verdict AS
WITH m AS (
  SELECT count(*) AS values_compared,
         count(*) FILTER (WHERE kind = 'EQUAL') AS values_equal,
         count(*) FILTER (WHERE kind = 'DIFF') AS values_different,
         count(*) FILTER (WHERE kind = 'NULL_OLD_ONLY') AS values_null_old_only,
         count(*) FILTER (WHERE kind = 'NULL_NEW_ONLY') AS values_null_new_only,
         count(DISTINCT col) AS info_columns,
         count(DISTINCT (p_utc, k)) AS objects_compared
  FROM info_cmp)
SELECT CASE WHEN values_compared = 0 THEN 'NOT COMPARABLE'
            WHEN values_different + values_null_old_only + values_null_new_only > 0 THEN 'DIFFERENT'
            ELSE 'IDENTICAL' END AS verdict, *
FROM m;

COPY (SELECT strftime(p_utc AT TIME ZONE 'UTC', '%Y-%m-%d %H:%M') AS period_utc, k AS object_key, col AS info_column,
             ov AS old_value, nv AS new_value, kind
      FROM info_cmp WHERE kind <> 'EQUAL' ORDER BY col, period_utc, object_key LIMIT ${MAX_DIFF_ROWS})
TO '${REPORT_DIR}/info_differences.csv' (HEADER, DELIMITER ',');

COPY (SELECT col AS info_column, count(*) AS compared, count(*) FILTER (WHERE kind = 'EQUAL') AS equal_count,
             count(*) FILTER (WHERE kind = 'DIFF') AS different,
             count(*) FILTER (WHERE kind = 'NULL_OLD_ONLY') AS null_old_only,
             count(*) FILTER (WHERE kind = 'NULL_NEW_ONLY') AS null_new_only
      FROM info_cmp GROUP BY col ORDER BY different DESC, col)
TO '${REPORT_DIR}/info_column_summary.csv' (HEADER, DELIMITER ',');

COPY (
  SELECT 'verdict' AS metric, verdict AS value FROM info_verdict
  UNION ALL SELECT m.metric, CAST(m.value AS VARCHAR)
  FROM (UNPIVOT (SELECT * EXCLUDE (verdict) FROM info_verdict) ON COLUMNS(*) INTO NAME metric VALUE value) m
) TO '${REPORT_DIR}/info_summary.csv' (HEADER, DELIMITER ',');

COPY (
  SELECT verdict || ': info columns=' || info_columns || ', objects compared=' || objects_compared
    || ', values compared=' || values_compared || ' different=' || values_different
    || ' null_old_only=' || values_null_old_only || ' null_new_only=' || values_null_new_only AS line
  FROM info_verdict
) TO '${REPORT_DIR}/info_verdict.txt' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');

.headers off
.mode list
SELECT 'INFO ' || line FROM (
  SELECT verdict || ': info columns=' || info_columns || ', objects compared=' || objects_compared
    || ', values compared=' || values_compared || ' different=' || values_different
    || ' null_old_only=' || values_null_old_only || ' null_new_only=' || values_null_new_only AS line
  FROM info_verdict);
