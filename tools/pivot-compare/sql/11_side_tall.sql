-- Side ${SIDE}: the source is a TALL table (one row per object, period and KPI), for example KPI_CALCULATED.
-- It is turned into the same three result tables as a wide side (see 10_side_wide.sql), so no pivot table
-- has to be built first. A repeated (object, period, KPI) is reduced with max(), as the pivot model does.
CREATE OR REPLACE TEMP TABLE ${SIDE}_src AS
SELECT ${P_EXPR} AS __p, ${K_EXPR} AS __k,
       '${SIDE_PREFIX}' || CAST(${KPI_COL_Q} AS VARCHAR) AS __kpi,
       CAST(${VALUE_COL_Q} AS DOUBLE) AS __v
FROM ${REF}
WHERE ${PER_COL} >= ${FROM_NATIVE} AND ${PER_COL} < ${TO_NATIVE}${FILTER_SQL};

CREATE OR REPLACE TEMP TABLE ${SIDE}_keys AS
SELECT __p AS p_utc, __k AS k, count(*) AS n_rows FROM ${SIDE}_src GROUP BY 1, 2;

CREATE OR REPLACE TEMP TABLE ${SIDE}_cols AS
SELECT DISTINCT __kpi AS kpi FROM ${SIDE}_src WHERE regexp_matches(__kpi, '${SIDE_KPI_REGEX}');

CREATE OR REPLACE TEMP TABLE ${SIDE}_long AS
SELECT __p AS p_utc, __k AS k, __kpi AS kpi, max(__v) AS val, count(*) AS n
FROM ${SIDE}_src
WHERE __v IS NOT NULL AND regexp_matches(__kpi, '${SIDE_KPI_REGEX}')
GROUP BY 1, 2, 3;

DROP TABLE ${SIDE}_src;
