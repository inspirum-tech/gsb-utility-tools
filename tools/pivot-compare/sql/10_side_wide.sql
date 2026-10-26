-- Side ${SIDE}: the source is a WIDE pivot table (one column per KPI).
-- Result tables (same shape for a wide and a tall side):
--   ${SIDE}_keys (p_utc, k, n_rows)        one row per object and period
--   ${SIDE}_cols (kpi)                     the KPI column names
--   ${SIDE}_long (p_utc, k, kpi, val, n)   one row per object, period and KPI with a value (NULLs are not stored)
-- p_utc is the period as timestamptz, k is the object key as text (key columns joined with |, NULL shown as <NULL>).
CREATE OR REPLACE TEMP TABLE ${SIDE}_src AS
SELECT ${P_EXPR} AS __p, ${K_EXPR} AS __k, *
FROM ${REF}
WHERE ${PER_COL} >= ${FROM_NATIVE} AND ${PER_COL} < ${TO_NATIVE}${FILTER_SQL};

CREATE OR REPLACE TEMP TABLE ${SIDE}_keys AS
SELECT __p AS p_utc, __k AS k, count(*) AS n_rows FROM ${SIDE}_src GROUP BY 1, 2;

CREATE OR REPLACE TEMP TABLE ${SIDE}_cols AS
SELECT column_name AS kpi FROM duckdb_columns()
WHERE table_name = '${SIDE}_src' AND database_name = 'temp'
  AND column_name NOT IN ('__p', '__k')
  AND regexp_matches(column_name, '${SIDE_KPI_REGEX}');

CREATE OR REPLACE TEMP TABLE ${SIDE}_long AS
SELECT p_utc, k, kpi, max(v) AS val, count(*) AS n
FROM (
  SELECT __p AS p_utc, __k AS k, kpi, CAST(val AS DOUBLE) AS v
  FROM (UNPIVOT ${SIDE}_src ON COLUMNS('${SIDE_KPI_REGEX}') INTO NAME kpi VALUE val)
)
GROUP BY 1, 2, 3;

DROP TABLE ${SIDE}_src;
