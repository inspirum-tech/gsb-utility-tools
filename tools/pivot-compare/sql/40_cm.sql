-- CM (configuration management) comparison: the CM table of the OLD side against the CM table of the NEW side.
-- Read only. One object = the key columns joined with | ; one value = one CM column, compared as text, or as numbers
-- (with the KPI tolerance) when both sides are numbers. When CM_ASOF_COL is set, the row in force at PERIOD_TO is used
-- for every object (the latest row with ASOF_COL <= PERIOD_TO), so a CM change after the period cannot cause a difference.
-- Result tables per side: cm_old_src / cm_new_src (one row per object), cm_old_long / cm_new_long (k, col, val).

CREATE OR REPLACE TEMP TABLE cm_old_src AS
SELECT ${CM_OLD_K_EXPR} AS __k, ${CM_OLD_A_EXPR} AS __a, count(*) OVER (PARTITION BY ${CM_OLD_K_EXPR}) AS __n, *
FROM ${CM_OLD_REF}
${CM_OLD_WHERE}
QUALIFY row_number() OVER (PARTITION BY ${CM_OLD_K_EXPR} ORDER BY ${CM_OLD_A_EXPR} DESC NULLS LAST) = 1;

CREATE OR REPLACE TEMP TABLE cm_new_src AS
SELECT ${CM_NEW_K_EXPR} AS __k, ${CM_NEW_A_EXPR} AS __a, count(*) OVER (PARTITION BY ${CM_NEW_K_EXPR}) AS __n, *
FROM ${CM_NEW_REF}
${CM_NEW_WHERE}
QUALIFY row_number() OVER (PARTITION BY ${CM_NEW_K_EXPR} ORDER BY ${CM_NEW_A_EXPR} DESC NULLS LAST) = 1;

CREATE OR REPLACE TEMP TABLE cm_old_long AS
SELECT __k AS k, col, nullif(val, '~~NULL~~') AS val FROM (
  UNPIVOT (SELECT __k, coalesce(COLUMNS(* EXCLUDE (${CM_EXCLUDE_SQL}))::VARCHAR, '~~NULL~~') FROM cm_old_src)
  ON COLUMNS(* EXCLUDE (__k)) INTO NAME col VALUE val);

CREATE OR REPLACE TEMP TABLE cm_new_long AS
SELECT __k AS k, col, nullif(val, '~~NULL~~') AS val FROM (
  UNPIVOT (SELECT __k, coalesce(COLUMNS(* EXCLUDE (${CM_EXCLUDE_SQL}))::VARCHAR, '~~NULL~~') FROM cm_new_src)
  ON COLUMNS(* EXCLUDE (__k)) INTO NAME col VALUE val);

CREATE OR REPLACE TEMP TABLE cm_cmp AS
SELECT o.k, o.col, o.val AS ov, n.val AS nv,
  CASE
    WHEN o.val IS NULL AND n.val IS NULL THEN 'EQUAL'
    WHEN o.val IS NULL THEN 'NULL_OLD_ONLY'
    WHEN n.val IS NULL THEN 'NULL_NEW_ONLY'
    WHEN trim(o.val) = trim(n.val) THEN 'EQUAL'
    WHEN try_cast(o.val AS DOUBLE) IS NOT NULL AND try_cast(n.val AS DOUBLE) IS NOT NULL
         AND abs(try_cast(o.val AS DOUBLE) - try_cast(n.val AS DOUBLE))
             <= ${TOLERANCE_ABS} + ${TOLERANCE_REL} * abs(try_cast(o.val AS DOUBLE)) + ${FLOAT_SLACK} THEN 'EQUAL'
    ELSE 'DIFF'
  END AS kind
FROM cm_old_long o JOIN cm_new_long n ON o.k = n.k AND o.col = n.col;

CREATE OR REPLACE TEMP TABLE cm_keys_one_side AS
SELECT 'old' AS side, __k AS k FROM cm_old_src WHERE __k NOT IN (SELECT __k FROM cm_new_src)
UNION ALL
SELECT 'new', __k FROM cm_new_src WHERE __k NOT IN (SELECT __k FROM cm_old_src);

CREATE OR REPLACE TEMP TABLE cm_cols_one_side AS
SELECT 'old' AS side, col FROM (SELECT DISTINCT col FROM cm_old_long) WHERE col NOT IN (SELECT col FROM cm_new_long)
UNION ALL
SELECT 'new', col FROM (SELECT DISTINCT col FROM cm_new_long) WHERE col NOT IN (SELECT col FROM cm_old_long);

CREATE OR REPLACE TEMP TABLE cm_verdict AS
WITH m AS (
  SELECT
    (SELECT count(*) FROM cm_old_src) AS old_objects,
    (SELECT count(*) FROM cm_new_src) AS new_objects,
    (SELECT count(*) FROM cm_old_src WHERE __k IN (SELECT __k FROM cm_new_src)) AS common_objects,
    (SELECT count(*) FROM cm_keys_one_side WHERE side = 'old') AS only_old_objects,
    (SELECT count(*) FROM cm_keys_one_side WHERE side = 'new') AS only_new_objects,
    (SELECT count(DISTINCT col) FROM cm_old_long) AS old_columns,
    (SELECT count(DISTINCT col) FROM cm_new_long) AS new_columns,
    (SELECT count(DISTINCT col) FROM cm_cmp) AS common_columns,
    (SELECT count(*) FROM cm_cols_one_side WHERE side = 'old') AS only_old_columns,
    (SELECT count(*) FROM cm_cols_one_side WHERE side = 'new') AS only_new_columns,
    (SELECT count(*) FROM cm_cmp) AS values_compared,
    (SELECT count(*) FROM cm_cmp WHERE kind = 'EQUAL') AS values_equal,
    (SELECT count(*) FROM cm_cmp WHERE kind = 'DIFF') AS values_different,
    (SELECT count(*) FROM cm_cmp WHERE kind = 'NULL_OLD_ONLY') AS values_null_old_only,
    (SELECT count(*) FROM cm_cmp WHERE kind = 'NULL_NEW_ONLY') AS values_null_new_only,
    (SELECT count(*) FROM cm_old_src WHERE __n > 1) + (SELECT count(*) FROM cm_new_src WHERE __n > 1) AS objects_with_several_rows
)
SELECT CASE
    WHEN common_objects = 0 OR common_columns = 0 THEN 'NOT COMPARABLE'
    WHEN values_different > 0 THEN 'DIFFERENT'
    WHEN '${FAIL_ON_NULL_ONE_SIDE}' = 'yes' AND values_null_old_only + values_null_new_only > 0 THEN 'DIFFERENT'
    WHEN '${CM_FAIL_ON_OBJECTS_ONE_SIDE}' = 'yes' AND only_old_objects + only_new_objects > 0 THEN 'DIFFERENT'
    WHEN '${CM_FAIL_ON_COLUMNS_ONE_SIDE}' = 'yes' AND only_old_columns + only_new_columns > 0 THEN 'DIFFERENT'
    ELSE 'IDENTICAL' END AS verdict, *
FROM m;

CREATE OR REPLACE TEMP TABLE cm_column_summary AS
SELECT col, count(*) AS compared, count(*) FILTER (WHERE kind = 'EQUAL') AS equal_count,
       count(*) FILTER (WHERE kind = 'DIFF') AS different,
       count(*) FILTER (WHERE kind = 'NULL_OLD_ONLY') AS null_old_only,
       count(*) FILTER (WHERE kind = 'NULL_NEW_ONLY') AS null_new_only
FROM cm_cmp GROUP BY col;

COPY (SELECT k AS object_key, col AS cm_column, ov AS old_value, nv AS new_value, kind
      FROM cm_cmp WHERE kind <> 'EQUAL' ORDER BY col, object_key LIMIT ${MAX_DIFF_ROWS})
TO '${CM_REPORT_DIR}/cm_differences.csv' (HEADER, DELIMITER ',');

COPY (SELECT side AS only_on_side, k AS object_key FROM cm_keys_one_side ORDER BY side, k)
TO '${CM_REPORT_DIR}/cm_objects_one_side.csv' (HEADER, DELIMITER ',');

COPY (SELECT side AS only_on_side, col AS cm_column FROM cm_cols_one_side ORDER BY side, col)
TO '${CM_REPORT_DIR}/cm_columns_one_side.csv' (HEADER, DELIMITER ',');

COPY (SELECT * FROM cm_column_summary ORDER BY different DESC, null_old_only + null_new_only DESC, col)
TO '${CM_REPORT_DIR}/cm_column_summary.csv' (HEADER, DELIMITER ',');

COPY (
  SELECT 'verdict' AS metric, verdict AS value FROM cm_verdict
  UNION ALL SELECT m.metric, CAST(m.value AS VARCHAR)
  FROM (UNPIVOT (SELECT * EXCLUDE (verdict) FROM cm_verdict) ON COLUMNS(*) INTO NAME metric VALUE value) m
) TO '${CM_REPORT_DIR}/cm_summary.csv' (HEADER, DELIMITER ',');

COPY (
  SELECT verdict || ': CM objects only old=' || only_old_objects || ' only new=' || only_new_objects
    || ', CM columns only old=' || only_old_columns || ' only new=' || only_new_columns
    || ', values compared=' || values_compared || ' different=' || values_different
    || ' null_old_only=' || values_null_old_only || ' null_new_only=' || values_null_new_only
    || ', common objects=' || common_objects || ', common CM columns=' || common_columns AS line
  FROM cm_verdict
) TO '${CM_REPORT_DIR}/cm_verdict.txt' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');

.headers off
.mode list
SELECT 'CM  ' || line FROM (
  SELECT verdict || ': CM objects only old=' || only_old_objects || ' only new=' || only_new_objects
    || ', CM columns only old=' || only_old_columns || ' only new=' || only_new_columns
    || ', values compared=' || values_compared || ' different=' || values_different
    || ' null_old_only=' || values_null_old_only || ' null_new_only=' || values_null_new_only
    || ', common objects=' || common_objects || ', common CM columns=' || common_columns AS line
  FROM cm_verdict);
