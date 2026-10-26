-- Auto mode: finds the families (one old pivot table each) from the KPI definitions, the same way the new engine names
-- its pivot tables: KPI_<APPLICATION>_<RESOLUTION>_<LEVEL>_<TECHNOLOGY>_<VENDOR>_P (see AUTO_OLD_TABLE_PATTERN).
-- Writes (read only on the sources):
--   ${BASE}/family_kpis.csv   table_name, kpi_id   which KPI ids belong to which family
--   ${BASE}/families.txt      family|old table found (empty if none)|application|number of KPIs
--   ${BASE}/families.csv      the same with headers
CREATE OR REPLACE TEMP TABLE def AS
SELECT CAST("${DEF_COL_KPI_ID}" AS BIGINT) AS kpi_id,
       trim(CAST("${DEF_COL_APPLICATION}" AS VARCHAR)) AS app,
       upper(trim(coalesce(CAST("${DEF_COL_RESOLUTION}" AS VARCHAR), ''))) AS ta,
       trim(coalesce(CAST("${DEF_COL_LEVEL}" AS VARCHAR), '')) AS lvl,
       trim(coalesce(CAST("${DEF_COL_TECHNOLOGY}" AS VARCHAR), '')) AS tech,
       trim(coalesce(CAST("${DEF_COL_VENDOR}" AS VARCHAR), '')) AS vendor
FROM ${DEF_REF}
${APP_WHERE};

-- a definition without the metadata to name a table cannot be placed in a family (the engine skips it too)
CREATE OR REPLACE TEMP TABLE def_ok AS
SELECT * FROM def
WHERE kpi_id IS NOT NULL AND app <> '' AND ta <> '' AND lvl <> '' AND tech <> '' AND vendor <> '';

CREATE OR REPLACE TEMP TABLE token_map AS
SELECT split_part(x, '=', 1) AS ta, split_part(x, '=', 2) AS token
FROM (SELECT unnest(string_split('${AUTO_RES_TOKENS}', ',')) AS x);

CREATE OR REPLACE TEMP TABLE fam_kpis AS
SELECT upper(regexp_replace(
         replace(replace(replace(replace(replace('${AUTO_OLD_TABLE_PATTERN}',
           '{APPLICATION}', d.app), '{RES}', coalesce(tm.token, d.ta)), '{LEVEL}', d.lvl), '{TECH}', d.tech), '{VENDOR}', d.vendor),
         '[^A-Za-z0-9_]', '_', 'g')) AS table_name,
       d.app, d.kpi_id
FROM def_ok d LEFT JOIN token_map tm ON tm.ta = d.ta;

CREATE OR REPLACE TEMP TABLE old_tables AS
SELECT table_name FROM duckdb_tables() WHERE database_name = '${OLD_ALIAS}' AND schema_name = '${OLD_SCHEMA_V}';

CREATE OR REPLACE TEMP TABLE families AS
SELECT f.table_name AS family, coalesce(any_value(o.table_name), '') AS old_table, any_value(f.app) AS application, count(DISTINCT f.kpi_id) AS kpis
FROM fam_kpis f LEFT JOIN old_tables o ON upper(o.table_name) = f.table_name
GROUP BY f.table_name;

COPY (SELECT DISTINCT table_name, kpi_id FROM fam_kpis ORDER BY 1, 2) TO '${BASE}/family_kpis.csv' (HEADER, DELIMITER ',');
COPY (SELECT * FROM families ORDER BY family) TO '${BASE}/families.csv' (HEADER, DELIMITER ',');
COPY (SELECT * FROM families ORDER BY family) TO '${BASE}/families.txt' (HEADER false, DELIMITER '|', QUOTE '', ESCAPE '');
