-- Compares the two sides built by 10_side_wide.sql / 11_side_tall.sql. Works on the temp tables only.
${KPI_MAP_SQL}

CREATE OR REPLACE TEMP TABLE kpi_allowed AS
${KPI_ALLOWED_SELECT};
DELETE FROM kpi_allowed WHERE NOT regexp_matches(kpi, '${KPI_REGEX}');

CREATE OR REPLACE TEMP TABLE common_cols AS
SELECT o.kpi FROM old_cols o JOIN new_cols n ON o.kpi = n.kpi SEMI JOIN kpi_allowed a ON o.kpi = a.kpi;

CREATE OR REPLACE TEMP TABLE cols_one_side AS
SELECT 'old' AS side, kpi FROM old_cols WHERE kpi NOT IN (SELECT kpi FROM new_cols)
  AND kpi IN (SELECT kpi FROM kpi_allowed)
UNION ALL
SELECT 'new', kpi FROM new_cols WHERE kpi NOT IN (SELECT kpi FROM old_cols)
  AND kpi IN (SELECT kpi FROM kpi_allowed);

CREATE OR REPLACE TEMP TABLE common_keys AS
SELECT o.p_utc, o.k FROM old_keys o JOIN new_keys n ON o.p_utc = n.p_utc AND o.k = n.k;

CREATE OR REPLACE TEMP TABLE keys_one_side AS
SELECT 'old' AS side, p_utc, k, n_rows FROM old_keys o
  WHERE NOT EXISTS (SELECT 1 FROM new_keys n WHERE n.p_utc = o.p_utc AND n.k = o.k)
UNION ALL
SELECT 'new', p_utc, k, n_rows FROM new_keys n
  WHERE NOT EXISTS (SELECT 1 FROM old_keys o WHERE o.p_utc = n.p_utc AND o.k = n.k);

-- A repeated key on one side (more than one source row for the same object and period, or for the same KPI):
-- the values are reduced with max() on both sides; the repeats are listed so nobody is surprised.
CREATE OR REPLACE TEMP TABLE duplicates AS
SELECT 'old' AS side, p_utc, k, '*' AS kpi, n_rows AS n FROM old_keys WHERE n_rows > ${DUP_THRESHOLD_OLD}
UNION ALL
SELECT 'new', p_utc, k, '*', n_rows FROM new_keys WHERE n_rows > ${DUP_THRESHOLD_NEW}
UNION ALL
SELECT 'old', p_utc, k, kpi, n FROM old_long WHERE n > 1
UNION ALL
SELECT 'new', p_utc, k, kpi, n FROM new_long WHERE n > 1;

-- One row per (object, period, KPI) that has a value on at least one side, for objects and KPIs on both sides.
CREATE OR REPLACE TEMP TABLE cmp_raw AS
SELECT coalesce(o.p_utc, n.p_utc) AS p_utc, coalesce(o.k, n.k) AS k, coalesce(o.kpi, n.kpi) AS kpi,
       o.val AS ov, n.val AS nv
FROM (SELECT l.* FROM old_long l
        SEMI JOIN common_keys c ON l.p_utc = c.p_utc AND l.k = c.k
        SEMI JOIN common_cols cc ON l.kpi = cc.kpi) o
FULL JOIN (SELECT l.* FROM new_long l
        SEMI JOIN common_keys c ON l.p_utc = c.p_utc AND l.k = c.k
        SEMI JOIN common_cols cc ON l.kpi = cc.kpi) n
  ON o.p_utc = n.p_utc AND o.k = n.k AND o.kpi = n.kpi;

-- The documented value rule (Java: null, NaN and infinite KPI values become the default), then the verdict per value.
CREATE OR REPLACE TEMP TABLE cmp AS
SELECT p_utc, k, kpi, ov, nv,
  CASE
    WHEN ov2 IS NULL AND nv2 IS NULL THEN 'BOTH_NULL'
    WHEN ov2 IS NULL THEN 'NULL_OLD_ONLY'
    WHEN nv2 IS NULL THEN 'NULL_NEW_ONLY'
    WHEN ov2 = nv2 OR abs(ov2 - nv2) <= ${TOLERANCE_ABS} + ${TOLERANCE_REL} * abs(ov2) + ${FLOAT_SLACK} THEN 'EQUAL'
    ELSE 'DIFF'
  END AS kind,
  CASE WHEN ov2 IS NOT NULL AND nv2 IS NOT NULL THEN abs(ov2 - nv2) END AS abs_diff
FROM (
  SELECT p_utc, k, kpi, ov, nv,
    coalesce(CASE WHEN '${SPECIAL_AS_DEFAULT}' = 'yes' AND (isnan(ov) OR isinf(ov)) THEN ${SPECIAL_DEFAULT} ELSE ov END,
             CASE WHEN '${NULL_AS_DEFAULT}' = 'yes' THEN ${SPECIAL_DEFAULT} END) AS ov2,
    coalesce(CASE WHEN '${SPECIAL_AS_DEFAULT}' = 'yes' AND (isnan(nv) OR isinf(nv)) THEN ${SPECIAL_DEFAULT} ELSE nv END,
             CASE WHEN '${NULL_AS_DEFAULT}' = 'yes' THEN ${SPECIAL_DEFAULT} END) AS nv2
  FROM cmp_raw
);

-- Per KPI: compared = every object that exists on both sides (a value NULL on both sides counts as equal).
CREATE OR REPLACE TEMP TABLE kpi_summary AS
SELECT cc.kpi,
       (SELECT count(*) FROM common_keys) AS compared,
       (SELECT count(*) FROM common_keys) - coalesce(s.n_diff, 0) - coalesce(s.n_null_old, 0) - coalesce(s.n_null_new, 0) AS equal_count,
       coalesce(s.n_diff, 0) AS different,
       coalesce(s.n_null_old, 0) AS null_old_only,
       coalesce(s.n_null_new, 0) AS null_new_only,
       s.max_abs_diff
FROM common_cols cc
LEFT JOIN (
  SELECT kpi,
         count(*) FILTER (WHERE kind = 'DIFF') AS n_diff,
         count(*) FILTER (WHERE kind = 'NULL_OLD_ONLY') AS n_null_old,
         count(*) FILTER (WHERE kind = 'NULL_NEW_ONLY') AS n_null_new,
         max(CASE WHEN abs_diff IS NOT NULL AND isfinite(abs_diff) THEN abs_diff END) AS max_abs_diff
  FROM cmp GROUP BY kpi
) s ON s.kpi = cc.kpi;

CREATE OR REPLACE TEMP TABLE totals AS
SELECT
  (SELECT count(*) FROM old_keys) AS old_objects,
  (SELECT count(*) FROM new_keys) AS new_objects,
  (SELECT coalesce(sum(n_rows), 0) FROM old_keys) AS old_source_rows,
  (SELECT coalesce(sum(n_rows), 0) FROM new_keys) AS new_source_rows,
  (SELECT count(*) FROM common_keys) AS common_objects,
  (SELECT count(*) FROM keys_one_side WHERE side = 'old') AS only_old_objects,
  (SELECT count(*) FROM keys_one_side WHERE side = 'new') AS only_new_objects,
  (SELECT count(*) FROM old_cols) AS old_kpi_columns,
  (SELECT count(*) FROM new_cols) AS new_kpi_columns,
  (SELECT count(*) FROM common_cols) AS common_kpi_columns,
  (SELECT count(*) FROM cols_one_side WHERE side = 'old') AS only_old_kpi_columns,
  (SELECT count(*) FROM cols_one_side WHERE side = 'new') AS only_new_kpi_columns,
  (SELECT coalesce(sum(compared), 0) FROM kpi_summary) AS values_compared,
  (SELECT coalesce(sum(equal_count), 0) FROM kpi_summary) AS values_equal,
  (SELECT coalesce(sum(different), 0) FROM kpi_summary) AS values_different,
  (SELECT coalesce(sum(null_old_only), 0) FROM kpi_summary) AS values_null_old_only,
  (SELECT coalesce(sum(null_new_only), 0) FROM kpi_summary) AS values_null_new_only,
  (SELECT count(*) FROM duplicates) AS duplicate_entries;

CREATE OR REPLACE TEMP TABLE verdict AS
SELECT
  CASE
    WHEN common_objects = 0 OR common_kpi_columns = 0 THEN 'NOT COMPARABLE'
    WHEN values_different > 0
      OR ('${FAIL_ON_OBJECTS_ONE_SIDE}' = 'yes' AND only_old_objects + only_new_objects > 0)
      OR ('${FAIL_ON_KPI_COLUMNS_ONE_SIDE}' = 'yes' AND only_old_kpi_columns + only_new_kpi_columns > 0)
      OR ('${FAIL_ON_NULL_ONE_SIDE}' = 'yes' AND values_null_old_only + values_null_new_only > 0)
      THEN 'DIFFERENT'
    ELSE 'IDENTICAL'
  END AS verdict,
  *
FROM totals;
