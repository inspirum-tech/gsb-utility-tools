-- Writes the report files into ${REPORT_DIR} and prints the summary. Read only on the sources.
COPY (
  SELECT strftime(p_utc AT TIME ZONE 'UTC', '%Y-%m-%d %H:%M') AS period_utc, k AS object_key, kpi,
         ov AS old_value, nv AS new_value, abs_diff, kind
  FROM cmp WHERE kind IN ('DIFF', 'NULL_OLD_ONLY', 'NULL_NEW_ONLY')
  ORDER BY kpi, period_utc, object_key LIMIT ${MAX_DIFF_ROWS}
) TO '${REPORT_DIR}/differences.csv' (HEADER, DELIMITER ',');

COPY (
  SELECT side AS only_on_side, strftime(p_utc AT TIME ZONE 'UTC', '%Y-%m-%d %H:%M') AS period_utc, k AS object_key, n_rows AS source_rows
  FROM keys_one_side ORDER BY side, period_utc, object_key
) TO '${REPORT_DIR}/objects_one_side.csv' (HEADER, DELIMITER ',');

COPY (SELECT side AS only_on_side, kpi FROM cols_one_side ORDER BY side, kpi)
TO '${REPORT_DIR}/kpi_columns_one_side.csv' (HEADER, DELIMITER ',');

COPY (
  SELECT side, strftime(p_utc AT TIME ZONE 'UTC', '%Y-%m-%d %H:%M') AS period_utc, k AS object_key, kpi, n AS source_rows,
         CASE WHEN conflicting THEN 'yes' ELSE 'no' END AS conflicting, min_value, max_value
  FROM duplicates ORDER BY conflicting DESC, side, period_utc, object_key, kpi
) TO '${REPORT_DIR}/duplicate_keys.csv' (HEADER, DELIMITER ',');

-- One line per period (UTC) found on either side: is the period on both sides, objects and values per period.
COPY (
  SELECT strftime(p_utc AT TIME ZONE 'UTC', '%Y-%m-%d %H:%M') AS period_utc, period_present,
         old_objects, new_objects, common_objects, only_old_objects, only_new_objects,
         values_compared, values_equal, values_different, values_null_old_only, values_null_new_only
  FROM period_summary ORDER BY p_utc
) TO '${REPORT_DIR}/period_summary.csv' (HEADER, DELIMITER ',');

COPY (
  SELECT kpi, compared, equal_count AS equal, different, null_old_only, null_new_only, max_abs_diff, null_both AS empty_both
  FROM kpi_summary ORDER BY different DESC, null_old_only + null_new_only DESC, kpi
) TO '${REPORT_DIR}/kpi_summary.csv' (HEADER, DELIMITER ',');

COPY (
  SELECT 'verdict' AS metric, verdict AS value FROM verdict
  UNION ALL SELECT m.metric, CAST(m.value AS VARCHAR)
  FROM (UNPIVOT (SELECT * EXCLUDE (verdict) FROM verdict) ON COLUMNS(*) INTO NAME metric VALUE value) m
) TO '${REPORT_DIR}/summary.csv' (HEADER, DELIMITER ',');

-- On screen
.headers on
.mode duckbox
SELECT 'objects (period + key)' AS what, old_objects AS old_side, new_objects AS new_side, common_objects AS in_both,
       only_old_objects AS only_old, only_new_objects AS only_new FROM verdict;
SELECT 'source rows' AS what, old_source_rows AS old_side, new_source_rows AS new_side FROM verdict;
SELECT 'KPI columns' AS what, old_kpi_columns AS old_side, new_kpi_columns AS new_side, common_kpi_columns AS in_both,
       only_old_kpi_columns AS only_old, only_new_kpi_columns AS only_new FROM verdict;
SELECT 'periods' AS what, periods_total AS total, periods_on_both_sides AS on_both_sides, periods_only_old AS only_old,
       periods_only_new AS only_new FROM verdict;
SELECT 'values' AS what, values_compared AS compared, values_equal AS equal, values_different AS different,
       values_null_old_only AS null_old_only, values_null_new_only AS null_new_only, duplicate_entries,
       conflicting_duplicates FROM verdict;
SELECT kpi, compared, equal_count AS equal, different, null_old_only, null_new_only, max_abs_diff
FROM kpi_summary WHERE different + null_old_only + null_new_only > 0
ORDER BY different DESC, null_old_only + null_new_only DESC, kpi LIMIT 10;

COPY (
  SELECT verdict || ': objects only old=' || only_old_objects || ' only new=' || only_new_objects
    || ', KPI columns only old=' || only_old_kpi_columns || ' only new=' || only_new_kpi_columns
    || ', values compared=' || values_compared || ' different=' || values_different
    || ' null_old_only=' || values_null_old_only || ' null_new_only=' || values_null_new_only
    || ', common objects=' || common_objects || ', common KPI columns=' || common_kpi_columns
    || ', periods on both sides=' || periods_on_both_sides || ' only old=' || periods_only_old || ' only new=' || periods_only_new
    || ', duplicate entries=' || duplicate_entries || ' conflicting=' || conflicting_duplicates AS line
  FROM verdict
) TO '${REPORT_DIR}/verdict.txt' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
.headers off
.mode list
SELECT line FROM (
  SELECT verdict || ': objects only old=' || only_old_objects || ' only new=' || only_new_objects
    || ', KPI columns only old=' || only_old_kpi_columns || ' only new=' || only_new_kpi_columns
    || ', values compared=' || values_compared || ' different=' || values_different
    || ' null_old_only=' || values_null_old_only || ' null_new_only=' || values_null_new_only
    || ', common objects=' || common_objects || ', common KPI columns=' || common_kpi_columns
    || ', periods on both sides=' || periods_on_both_sides || ' only old=' || periods_only_old || ' only new=' || periods_only_new
    || ', duplicate entries=' || duplicate_entries || ' conflicting=' || conflicting_duplicates AS line
  FROM verdict);
