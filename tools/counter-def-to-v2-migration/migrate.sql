-- COUNTER_DEF -> COUNTER_DEF_V2, one-time migration. Run it through
-- migrate.sh, which sets every :variable from migrate.conf.
--
-- Four destination fields are derived; every other column in COPY_COLUMNS
-- is copied unchanged (FIRST_SEEN_DATE NULLs get the run time):
--   COUNTER_NAME     the raw XML name: Java's ERS name "<MEASUREMENT_NAME>_<raw>"
--                    (PMNbi3gppSaxContentHandlerWithERSAdaptations:271) loses its
--                    prefix; an array bin "<parent><sep><n>" (lines 354/399/479)
--                    becomes its parent's name, as the parser registers bins
--                    (refdata.rs register: bin rows share the parent's name).
--   ATTRIBUTES       '{}' (or the source attributes), plus {"array_bin": n} on a bin.
--   SUB_COUNTER      'Y' exactly when ATTRIBUTES has array_bin, else 'N'.
--   TIME_RESOLUTION  Java's letters mapped to the parser's tokens (TIME_RESOLUTION_MAP).
-- Rows whose derived identity repeats keep one row (one with a MOCN_NAME
-- first, then ENABLED='Y', then a Java-named row, then the lowest
-- COUNTER_ID); the rest are reported.
--
-- Source tables (COUNTER_DEF, MEASUREMENT_DEF, ERS_COUNTER_DEF) are only read:
-- every write below names COUNTER_DEF_V2, its sequence or index, or a temp
-- table. Section 0 refuses to start if COUNTER_DEF_V2, its sequence or its
-- index is (or belongs to) a source table, and the checks compare a checksum
-- of every source table taken before and after. Everything runs in one
-- transaction.

\set ON_ERROR_STOP on

BEGIN ISOLATION LEVEL REPEATABLE READ;
SET LOCAL client_min_messages = warning;

-- 0. Guards, before anything is written.
CREATE TEMP TABLE m_obj ON COMMIT DROP AS
SELECT v.role, v.name, to_regclass(v.name) AS oid, v.is_source
FROM (VALUES
    ('COUNTER_DEF',              format('%I.%I', :'src_schema', :'src_table'),     true),
    ('MEASUREMENT_DEF',          format('%I.%I', :'meas_schema', :'meas_table'),   true),
    ('ERS_COUNTER_DEF',          format('%I.%I', :'array_schema', :'array_table'), true),
    ('COUNTER_DEF_V2',           format('%I.%I', :'dst_schema', :'dst_table'),     false),
    ('COUNTER_DEF_V2_SEQUENCE',  format('%I.%I', :'dst_schema', :'dst_sequence'),  false),
    ('COUNTER_DEF_V2_INDEX',     format('%I.%I', :'dst_schema', :'dst_index'),     false)
) AS v(role, name, is_source);
CREATE TEMP TABLE m_opt ON COMMIT DROP AS SELECT :'drop_existing'::boolean AS drop_existing;

DO $$
DECLARE
    r record;
    v2 oid := (SELECT oid FROM m_obj WHERE role = 'COUNTER_DEF_V2');
    seq oid := (SELECT oid FROM m_obj WHERE role = 'COUNTER_DEF_V2_SEQUENCE');
    idx oid := (SELECT oid FROM m_obj WHERE role = 'COUNTER_DEF_V2_INDEX');
    sources oid[] := (SELECT array_agg(oid) FROM m_obj WHERE is_source);
BEGIN
    FOR r IN SELECT * FROM m_obj WHERE is_source AND oid IS NULL LOOP
        RAISE EXCEPTION 'source table % (%) not found', r.name, r.role;
    END LOOP;
    IF v2 = ANY (sources) THEN
        RAISE EXCEPTION 'COUNTER_DEF_V2 (%) is a source table: refusing to write to it',
            (SELECT name FROM m_obj WHERE role = 'COUNTER_DEF_V2');
    END IF;
    IF v2 IS NOT NULL AND (SELECT relkind FROM pg_class WHERE oid = v2) NOT IN ('r', 'p') THEN
        RAISE EXCEPTION 'COUNTER_DEF_V2 (%) exists but is not a table', (SELECT name FROM m_obj WHERE role = 'COUNTER_DEF_V2');
    END IF;
    -- The sequence must not be a source table's (owned by one, or in one's column default).
    IF seq IS NOT NULL AND (
           (SELECT relkind FROM pg_class WHERE oid = seq) <> 'S'
        OR EXISTS (SELECT 1 FROM pg_depend d
                   WHERE d.classid = 'pg_class'::regclass AND d.objid = seq AND d.refobjid = ANY (sources))
        OR EXISTS (SELECT 1 FROM pg_depend d JOIN pg_attrdef ad ON d.classid = 'pg_attrdef'::regclass AND d.objid = ad.oid
                   WHERE d.refobjid = seq AND ad.adrelid = ANY (sources))) THEN
        RAISE EXCEPTION 'COUNTER_DEF_V2_SEQUENCE (%) is not a free sequence: it is not a sequence, or a source table uses it',
            (SELECT name FROM m_obj WHERE role = 'COUNTER_DEF_V2_SEQUENCE');
    END IF;
    -- An existing index of that name must be COUNTER_DEF_V2's own.
    IF idx IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indexrelid = idx AND i.indrelid = v2) THEN
        RAISE EXCEPTION 'COUNTER_DEF_V2_INDEX (%) already exists on another table',
            (SELECT name FROM m_obj WHERE role = 'COUNTER_DEF_V2_INDEX');
    END IF;
    -- Only a table shaped like COUNTER_DEF_V2 may be dropped.
    IF v2 IS NOT NULL AND (SELECT drop_existing FROM m_opt) AND (
           (SELECT count(*) FROM pg_attribute a
            WHERE a.attrelid = v2 AND a.attnum > 0 AND NOT a.attisdropped
              AND a.attname IN ('COUNTER_ID', 'VENDOR', 'MEASUREMENT_ID', 'COUNTER_NAME', 'SUB_COUNTER')) <> 5
        OR NOT EXISTS (SELECT 1 FROM pg_attribute a
                       WHERE a.attrelid = v2 AND a.attname = 'ATTRIBUTES' AND a.atttypid = 'jsonb'::regtype AND NOT a.attisdropped)) THEN
        RAISE EXCEPTION 'COUNTER_DEF_V2 (%) does not look like COUNTER_DEF_V2 (COUNTER_ID, VENDOR, MEASUREMENT_ID, COUNTER_NAME, ATTRIBUTES jsonb, SUB_COUNTER): refusing to drop it',
            (SELECT name FROM m_obj WHERE role = 'COUNTER_DEF_V2');
    END IF;
END $$;

-- Row count and checksum of every source table, now and at the end (checks).
CREATE TEMP VIEW m_source_fingerprint AS
SELECT 'COUNTER_DEF' AS role, count(*) AS row_count, md5(string_agg(t::text, E'\n' ORDER BY t::text)) AS checksum
  FROM :"src_schema".:"src_table" t
UNION ALL
SELECT 'MEASUREMENT_DEF', count(*), md5(string_agg(t::text, E'\n' ORDER BY t::text))
  FROM :"meas_schema".:"meas_table" t
UNION ALL
SELECT 'ERS_COUNTER_DEF', count(*), md5(string_agg(t::text, E'\n' ORDER BY t::text))
  FROM :"array_schema".:"array_table" t;
CREATE TEMP TABLE m_source_before ON COMMIT DROP AS SELECT * FROM m_source_fingerprint;

-- 1. Destination, exactly as the parser provisions it (RefData::provision).
--    DROP_EXISTING_COUNTER_DEF_V2: drop the table (with its index; never CASCADE,
--    so anything depending on it fails the run). The sequence is kept: it only
--    moves forward, so no COUNTER_ID the parser already used is handed out again.
\if :drop_existing
  \echo 'DROP_EXISTING_COUNTER_DEF_V2=true: dropping COUNTER_DEF_V2 (if it exists) and recreating it.'
  DROP TABLE IF EXISTS :"dst_schema".:"dst_table";
\endif
CREATE SCHEMA IF NOT EXISTS :"dst_schema";
CREATE SEQUENCE IF NOT EXISTS :"dst_schema".:"dst_sequence";
CREATE TABLE IF NOT EXISTS :"dst_schema".:"dst_table" (
    "COUNTER_ID"        INTEGER     PRIMARY KEY,
    "VERSION"           INTEGER     NOT NULL DEFAULT 1,
    "VENDOR"            VARCHAR     NOT NULL,
    "MEASUREMENT_ID"    INTEGER     NOT NULL,
    "COUNTER_NAME"      VARCHAR     NOT NULL,
    "ATTRIBUTES"        JSONB       NOT NULL DEFAULT '{}'::jsonb,
    "FRIENDLY_NAME"     VARCHAR     NOT NULL,
    "VALUE_TYPE"        CHAR(1)     NOT NULL DEFAULT 'N',
    "TECHNOLOGY"        VARCHAR     NOT NULL,
    "OBJ_LEVEL"         VARCHAR,
    "TIME_RESOLUTION"   VARCHAR     NOT NULL,
    "SUB_COUNTER"       CHAR(1)     NOT NULL DEFAULT 'N',
    "ENABLED"           CHAR(1)     NOT NULL DEFAULT 'N',
    "AGG_OP"            VARCHAR     NOT NULL DEFAULT 'SUM',
    "DESC_COUNTER_NAME" VARCHAR,
    "MOCN_NAME"         VARCHAR,
    "APPLICATION"       VARCHAR,
    "FIRST_SEEN_DATE"   TIMESTAMPTZ NOT NULL,
    "LAST_UPDATED_DATE" TIMESTAMPTZ,
    "LAST_UPDATED_BY"   VARCHAR
);
CREATE UNIQUE INDEX IF NOT EXISTS :"dst_index" ON :"dst_schema".:"dst_table"
    ("VENDOR", "MEASUREMENT_ID", "COUNTER_NAME", "ATTRIBUTES");
-- Readers continue; a running parser waits until this transaction ends.
LOCK TABLE :"dst_schema".:"dst_table" IN EXCLUSIVE MODE;

-- 2. Without DROP_EXISTING_COUNTER_DEF_V2, never mix with existing rows.
SELECT EXISTS (SELECT 1 FROM :"dst_schema".:"dst_table") AS dst_has_rows \gset
\if :dst_has_rows
  DO $$ BEGIN RAISE EXCEPTION 'COUNTER_DEF_V2 already has rows; set DROP_EXISTING_COUNTER_DEF_V2=true to drop and recreate it'; END $$;
\endif

-- 3. Selected source rows with the measurement name Java prefixed.
CREATE TEMP TABLE m_src ON COMMIT DROP AS
SELECT CAST(c.:"src_id" AS integer)        AS id,
       trim(c.:"src_vendor"::text)         AS vendor,
       CAST(c.:"src_meas" AS integer)      AS meas_id,
       c.:"src_name"::text                 AS old_name,
       :enabled_expr                       AS enabled,
       :mocn_expr                          AS mocn_name,
       :attrs_expr                         AS base_attrs,
       trim(md."MEASUREMENT_NAME"::text)   AS meas_name
FROM :"src_schema".:"src_table" c
LEFT JOIN :"meas_schema".:"meas_table" md
       ON md."MEASUREMENT_ID" = CAST(c.:"src_meas" AS integer)
      AND trim(md."VENDOR"::text) = trim(c.:"src_vendor"::text)
WHERE (:'vendors' = '' OR trim(c.:"src_vendor"::text) = ANY (string_to_array(:'vendors', ',')));

-- 4. Undo Java's "<MEASUREMENT_NAME>_" prefix.
CREATE TEMP TABLE m_named ON COMMIT DROP AS
SELECT s.*, CASE WHEN s.stripped THEN substr(s.old_name, length(s.meas_name) + 2) ELSE s.old_name END AS raw_name
FROM (
    SELECT m.*,
           (m.vendor = ANY (string_to_array(:'prefix_vendors', ','))
            AND m.meas_name IS NOT NULL
            AND length(m.old_name) > length(m.meas_name) + 1
            AND left(m.old_name, length(m.meas_name) + 1) = m.meas_name || '_') AS stripped
    FROM m_src m
) s;

-- 5. Array bins: "<parent><sep><n>" where ERS_COUNTER_DEF gives the parent a
--    size of 2 or more and n is in 0 .. size-1 (parser: array_size, bins_for).
CREATE TEMP TABLE m_arr ON COMMIT DROP AS
SELECT trim(a."MEASUREMENT_NAME"::text)                      AS meas_name,
       trim(a."COUNTER_NAME"::text)                          AS counter_name,
       split_part(trim(a."COUNTER_SIZE"::text), '.', 1)::int AS size,
       COALESCE(a."ARRAY_COUNTER_SEPERATOR"::text, '')       AS sep
FROM :"array_schema".:"array_table" a
WHERE a."MEASUREMENT_NAME" IS NOT NULL AND a."COUNTER_NAME" IS NOT NULL
  AND trim(a."COUNTER_SIZE"::text) ~ '^[0-9]{1,9}(\.0+)?$';

CREATE TEMP TABLE m_bin ON COMMIT DROP AS
SELECT n.id, a.counter_name AS parent, a.sep, a.size,
       substr(n.raw_name, length(a.counter_name) + length(a.sep) + 1) AS tail
FROM m_named n
JOIN m_arr a
  ON a.meas_name = n.meas_name
 AND a.size > 1
 AND length(n.raw_name) > length(a.counter_name) + length(a.sep)
 AND left(n.raw_name, length(a.counter_name) + length(a.sep)) = a.counter_name || a.sep
WHERE n.vendor = ANY (string_to_array(:'array_vendors', ','))
  -- a name ERS_COUNTER_DEF lists as a counter of its own is not a bin
  AND NOT EXISTS (SELECT 1 FROM m_arr x WHERE x.meas_name = n.meas_name AND x.counter_name = n.raw_name);
DELETE FROM m_bin WHERE CASE WHEN tail ~ '^(0|[1-9][0-9]{0,8})$' THEN tail::int >= size ELSE true END;

-- 6. Derived fields per row, then one row per identity.
CREATE TEMP TABLE m_rows ON COMMIT DROP AS
SELECT r.*, CASE WHEN r.attrs ? 'array_bin' THEN 'Y' ELSE 'N' END AS sub
FROM (
    SELECT n.id, n.vendor, n.meas_id, n.old_name, n.meas_name, n.stripped, n.enabled, n.mocn_name,
           COALESCE(b.parent, n.raw_name) AS new_name,
           CASE WHEN b.id IS NULL THEN n.base_attrs
                ELSE n.base_attrs || jsonb_build_object('array_bin', b.tail::int) END AS attrs,
           b.sep AS bin_sep,
           COALESCE(b.candidates, 0) AS bin_candidates
    FROM m_named n
    LEFT JOIN (SELECT id, min(parent) AS parent, min(sep) AS sep, min(tail) AS tail, count(*) AS candidates
               FROM m_bin GROUP BY id) b ON b.id = n.id
) r;

CREATE TEMP TABLE m_ranked ON COMMIT DROP AS
SELECT r.*,
       row_number()  OVER w AS rnk,
       first_value(r.id) OVER w AS kept_id
FROM m_rows r
WINDOW w AS (PARTITION BY r.vendor, r.meas_id, r.new_name, r.attrs
             ORDER BY (r.mocn_name IS NOT NULL) DESC, (r.enabled = 'Y') DESC NULLS LAST, r.stripped DESC, r.id);

-- 7. TIME_RESOLUTION: each comma-separated source value through
--    TIME_RESOLUTION_MAP, in the map's order (shortest period first, as the
--    parser's merge_time_resolution keeps it). A value not in the map stops
--    the run before anything is inserted. Empty map: copied unchanged.
CREATE TEMP TABLE m_trmap ON COMMIT DROP AS
SELECT trim(split_part(u.p, '=', 1)) AS src_value, trim(split_part(u.p, '=', 2)) AS dst_value, u.ord
FROM unnest(string_to_array(:'tres_map', ',')) WITH ORDINALITY AS u(p, ord)
WHERE u.p <> '';
\if :tres_map_on
CREATE TEMP TABLE m_tres ON COMMIT DROP AS
SELECT s.id, s.src_value,
       (SELECT string_agg(m.dst_value, ',' ORDER BY m.ord)
          FROM m_trmap m WHERE m.src_value = ANY (SELECT trim(e) FROM unnest(string_to_array(s.src_value, ',')) e)) AS mapped,
       (s.src_value IS NULL OR s.src_value = ''
        OR EXISTS (SELECT 1 FROM unnest(string_to_array(s.src_value, ',')) e
                   WHERE NOT EXISTS (SELECT 1 FROM m_trmap m WHERE m.src_value = trim(e)))) AS unmapped
FROM (SELECT CAST(c.:"src_id" AS integer) AS id, trim(c.:"src_tres"::text) AS src_value
      FROM :"src_schema".:"src_table" c
      WHERE (:'vendors' = '' OR trim(c.:"src_vendor"::text) = ANY (string_to_array(:'vendors', ',')))) s;

DO $$
DECLARE bad text;
BEGIN
    SELECT string_agg(DISTINCT COALESCE(src_value, 'NULL'), ', ') INTO bad FROM m_tres WHERE unmapped;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'TIME_RESOLUTION value(s) not in TIME_RESOLUTION_MAP: % (add them to the map)', bad;
    END IF;
END $$;
\set tres_join 'JOIN m_tres t ON t.id = r.id'
\else
\set tres_join ''
\endif

-- 8. Column mapping with source and destination types.
CREATE TEMP TABLE m_map ON COMMIT DROP AS
SELECT u.ord,
       split_part(u.p, '=', 1)                                    AS dst_col,
       COALESCE(NULLIF(split_part(u.p, '=', 2), ''), split_part(u.p, '=', 1)) AS src_col,
       split_part(u.p, '=', 1) = ANY (string_to_array(:'fill_null_columns', ',')) AS fill,
       (split_part(u.p, '=', 1) = 'TIME_RESOLUTION' AND :'tres_map_on' = 'true') AS mapped
FROM unnest(string_to_array(:'copy_columns', ',')) WITH ORDINALITY AS u(p, ord)
WHERE u.p <> '';

ALTER TABLE m_map ADD COLUMN dst_type text, ADD COLUMN src_type text;
UPDATE m_map m SET
    dst_type = (SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a
                WHERE a.attrelid = format('%I.%I', :'dst_schema', :'dst_table')::regclass
                  AND a.attname = m.dst_col AND a.attnum > 0 AND NOT a.attisdropped),
    src_type = (SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a
                WHERE a.attrelid = format('%I.%I', :'src_schema', :'src_table')::regclass
                  AND a.attname = m.src_col AND a.attnum > 0 AND NOT a.attisdropped);

DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT * FROM m_map WHERE dst_type IS NULL OR src_type IS NULL ORDER BY ord LOOP
        RAISE EXCEPTION 'COPY_COLUMNS entry %=%: column not found (destination type %, source type %)',
            r.dst_col, r.src_col, COALESCE(r.dst_type, 'missing'), COALESCE(r.src_type, 'missing');
    END LOOP;
END $$;

-- 9. Insert: copied columns cast to the destination type, TIME_RESOLUTION
--    mapped, plus the derived name fields. A value that does not fit fails
--    the whole run.
SELECT format(
    'INSERT INTO %I.%I (%s, "COUNTER_NAME", "ATTRIBUTES", "SUB_COUNTER") '
    'SELECT %s, r.new_name, r.attrs, r.sub FROM %I.%I c JOIN m_ranked r ON r.id = CAST(c.%I AS integer) AND r.rnk = 1 %s',
    :'dst_schema', :'dst_table',
    string_agg(format('%I', dst_col), ', ' ORDER BY ord),
    string_agg(CASE WHEN mapped
                    THEN format('CAST(t.mapped AS %s)', dst_type)
                    WHEN fill
                    THEN format('COALESCE(CAST(c.%I AS %s), CAST(transaction_timestamp() AS %s))', src_col, dst_type, dst_type)
                    ELSE format('CAST(c.%I AS %s)', src_col, dst_type) END, ', ' ORDER BY ord),
    :'src_schema', :'src_table', :'src_id', :'tres_join')
FROM m_map \gexec

-- 10. Checks. must_be_zero rows fail the run when n > 0; the rest are counts.
CREATE TEMP TABLE m_check (ord int, item text, n bigint, must_be_zero boolean) ON COMMIT DROP;

INSERT INTO m_check
SELECT 1, 'source rows, all vendors', count(*), false FROM :"src_schema".:"src_table"
UNION ALL
SELECT 2, 'source rows selected (VENDORS)', count(*), false FROM :"src_schema".:"src_table" c
 WHERE (:'vendors' = '' OR trim(c.:"src_vendor"::text) = ANY (string_to_array(:'vendors', ',')))
UNION ALL
SELECT 3, 'names with Java prefix removed', count(*), false FROM m_rows WHERE stripped
UNION ALL
SELECT 4, 'names kept as-is (no Java prefix found, MEASUREMENT_PREFIX_VENDORS only)', count(*), false
  FROM m_named WHERE vendor = ANY (string_to_array(:'prefix_vendors', ',')) AND NOT stripped
UNION ALL
SELECT 5, 'array bins (ATTRIBUTES.array_bin, SUB_COUNTER=Y)', count(*), false FROM m_rows WHERE sub = 'Y'
UNION ALL
SELECT 6, 'duplicate identities skipped (skipped_duplicates.csv)', count(*), false FROM m_ranked WHERE rnk > 1
UNION ALL
SELECT 7, 'rows inserted', count(*), false FROM :"dst_schema".:"dst_table"
UNION ALL
SELECT 8, 'bins whose parent row is not in the destination', count(*), false
  FROM :"dst_schema".:"dst_table" d
 WHERE d."ATTRIBUTES" ? 'array_bin'
   AND NOT EXISTS (SELECT 1 FROM :"dst_schema".:"dst_table" p
                    WHERE p."VENDOR" = d."VENDOR" AND p."MEASUREMENT_ID" = d."MEASUREMENT_ID"
                      AND p."COUNTER_NAME" = d."COUNTER_NAME" AND p."ATTRIBUTES" = d."ATTRIBUTES" - 'array_bin');

INSERT INTO m_check
SELECT 9, 'NULL ' || dst_col || ' filled with run time', 0, false FROM m_map WHERE fill;
SELECT format('UPDATE m_check SET n = (SELECT count(*) FROM %I.%I c WHERE (%L = '''' OR trim(c.%I::text) = ANY (string_to_array(%L, '',''))) AND c.%I IS NULL) WHERE item = %L',
              :'src_schema', :'src_table', :'vendors', :'src_vendor', :'vendors', src_col, 'NULL ' || dst_col || ' filled with run time')
FROM m_map WHERE fill \gexec

\if :tres_map_on
INSERT INTO m_check
SELECT 10, 'TIME_RESOLUTION ' || t.src_value || ' -> ' || t.mapped, count(*), false
  FROM m_tres t JOIN m_ranked r ON r.id = t.id AND r.rnk = 1
 GROUP BY t.src_value, t.mapped;
INSERT INTO m_check
SELECT 31, 'TIME_RESOLUTION differs from TIME_RESOLUTION_MAP', count(*), true
  FROM :"dst_schema".:"dst_table" d JOIN m_tres t ON t.id = d."COUNTER_ID"
 WHERE d."TIME_RESOLUTION" IS DISTINCT FROM t.mapped;
\endif

INSERT INTO m_check
SELECT 20, 'row count: selected source rows = prepared rows', abs((SELECT n FROM m_check WHERE ord = 2) - count(*)), true FROM m_src
UNION ALL
SELECT 21, 'COUNTER_ID repeated in selected source rows', count(*) - count(DISTINCT id), true FROM m_src
UNION ALL
SELECT 22, 'row count: inserted = prepared - skipped', abs((SELECT count(*) FROM :"dst_schema".:"dst_table") - (SELECT count(*) FROM m_ranked WHERE rnk = 1)), true
UNION ALL
SELECT 23, 'kept COUNTER_ID missing from destination', count(*), true
  FROM m_ranked r WHERE r.rnk = 1 AND NOT EXISTS (SELECT 1 FROM :"dst_schema".:"dst_table" d WHERE d."COUNTER_ID" = r.id)
UNION ALL
SELECT 24, 'destination COUNTER_ID not from source', count(*), true
  FROM :"dst_schema".:"dst_table" d WHERE NOT EXISTS (SELECT 1 FROM m_ranked r WHERE r.rnk = 1 AND r.id = d."COUNTER_ID")
UNION ALL
SELECT 25, 'array bin matches more than one parent (ambiguous)', count(*), true FROM m_rows WHERE bin_candidates > 1
UNION ALL
SELECT 26, 'COUNTER_NAME / ATTRIBUTES / SUB_COUNTER differ from derived values', count(*), true
  FROM :"dst_schema".:"dst_table" d JOIN m_ranked r ON r.id = d."COUNTER_ID"
 WHERE d."COUNTER_NAME" IS DISTINCT FROM r.new_name OR d."ATTRIBUTES" IS DISTINCT FROM r.attrs
    OR d."SUB_COUNTER" IS DISTINCT FROM r.sub
UNION ALL
SELECT 27, 'COUNTER_NAME does not rebuild the source name (Java form)', count(*), true
  FROM :"dst_schema".:"dst_table" d JOIN m_ranked r ON r.id = d."COUNTER_ID"
 WHERE (CASE WHEN r.stripped THEN r.meas_name || '_' ELSE '' END
        || d."COUNTER_NAME"
        || CASE WHEN d."ATTRIBUTES" ? 'array_bin' THEN COALESCE(r.bin_sep, '') || (d."ATTRIBUTES" ->> 'array_bin') ELSE '' END)
       IS DISTINCT FROM r.old_name
UNION ALL
SELECT 28, 'ATTRIBUTES is not a JSON object', count(*), true
  FROM :"dst_schema".:"dst_table" d WHERE jsonb_typeof(d."ATTRIBUTES") <> 'object'
UNION ALL
SELECT 29, 'array_bin is not a whole number >= 0', count(*), true
  FROM :"dst_schema".:"dst_table" d
 WHERE d."ATTRIBUTES" ? 'array_bin'
   AND NOT (jsonb_typeof(d."ATTRIBUTES" -> 'array_bin') = 'number' AND (d."ATTRIBUTES" ->> 'array_bin') ~ '^[0-9]+$')
UNION ALL
SELECT 30, 'bin rule: SUB_COUNTER=Y exactly when array_bin is set', count(*), true
  FROM :"dst_schema".:"dst_table" d WHERE (d."ATTRIBUTES" ? 'array_bin') <> (d."SUB_COUNTER" = 'Y')
UNION ALL
SELECT 32, 'identity index ' || :'dst_index' || ' missing on COUNTER_DEF_V2', 1 - count(*), true
  FROM pg_index i
 WHERE i.indexrelid = to_regclass(format('%I.%I', :'dst_schema', :'dst_index'))
   AND i.indrelid = format('%I.%I', :'dst_schema', :'dst_table')::regclass AND i.indisunique;

-- One check per copied column: the stored value, cast back to the source
-- type, equals the source value (filled NULLs excepted; TIME_RESOLUTION is
-- checked against the map above).
SELECT 'INSERT INTO m_check ' || string_agg(format(
    'SELECT %s, %L, count(*), true FROM %I.%I d JOIN %I.%I c ON CAST(c.%I AS integer) = d."COUNTER_ID" '
    'WHERE %s NOT (CAST(d.%I AS %s) IS NOT DISTINCT FROM c.%I)',
    100 + ord, 'value changed: ' || dst_col, :'dst_schema', :'dst_table', :'src_schema', :'src_table', :'src_id',
    CASE WHEN fill THEN format('c.%I IS NOT NULL AND', src_col) ELSE '' END,
    dst_col, src_type, src_col), ' UNION ALL ' ORDER BY ord)
FROM m_map WHERE NOT mapped \gexec

-- The source tables are exactly as they were at the start.
INSERT INTO m_check
SELECT 200, 'source table changed: ' || b.role, (b.row_count IS DISTINCT FROM a.row_count OR b.checksum IS DISTINCT FROM a.checksum)::int, true
  FROM m_source_before b LEFT JOIN m_source_fingerprint a USING (role);

-- 11. Reports, written before the verdict so a failed run can be inspected.
\o checks.csv
COPY (SELECT item, n, CASE WHEN NOT must_be_zero THEN 'INFO' WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END AS status
      FROM m_check ORDER BY ord, item) TO STDOUT WITH (FORMAT csv, HEADER);
\o skipped_duplicates.csv
COPY (SELECT r.id AS skipped_counter_id, r.kept_id AS kept_counter_id, r.vendor, r.meas_id AS measurement_id,
             r.old_name AS source_counter_name, k.old_name AS kept_source_counter_name,
             r.new_name AS counter_name, r.attrs AS attributes, r.enabled AS skipped_enabled, k.enabled AS kept_enabled,
             r.mocn_name AS skipped_mocn_name, k.mocn_name AS kept_mocn_name
      FROM m_ranked r JOIN m_ranked k ON k.id = r.kept_id
      WHERE r.rnk > 1 ORDER BY r.vendor, r.meas_id, r.new_name, r.id) TO STDOUT WITH (FORMAT csv, HEADER);
\o name_changes.csv
COPY (SELECT r.id AS counter_id, r.vendor, r.meas_id AS measurement_id, r.old_name AS source_counter_name,
             r.new_name AS counter_name, r.attrs AS attributes, r.sub AS sub_counter,
             CASE WHEN r.rnk = 1 THEN 'migrated' ELSE 'skipped' END AS outcome
      FROM m_ranked r WHERE r.old_name IS DISTINCT FROM r.new_name OR r.attrs <> '{}'::jsonb
      ORDER BY r.id) TO STDOUT WITH (FORMAT csv, HEADER);
\o

\echo
\echo 'Checks (also in checks.csv):'
SELECT item AS check, n AS count,
       CASE WHEN NOT must_be_zero THEN 'INFO' WHEN n = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM m_check ORDER BY ord, item;

DO $$
DECLARE failed text;
BEGIN
    SELECT string_agg(item || ' = ' || n, '; ' ORDER BY ord) INTO failed FROM m_check WHERE must_be_zero AND n <> 0;
    IF failed IS NOT NULL THEN
        RAISE EXCEPTION 'validation failed, rolling back: %', failed;
    END IF;
END $$;

-- 12. Finish: a dry run rolls back; a live run moves the COUNTER_ID
--     sequence past the highest migrated ID and anything already handed
--     out (setval is not transactional, so it runs only here) and commits.
\if :dry_run
  ROLLBACK;
  \echo 'Dry run: all checks passed, rolled back.'
\else
  SELECT setval(format('%I.%I', :'dst_schema', :'dst_sequence')::regclass,
                GREATEST((SELECT COALESCE(max("COUNTER_ID"), 1) FROM :"dst_schema".:"dst_table"),
                         (SELECT last_value FROM :"dst_schema".:"dst_sequence"))) AS sequence_now \gset
  \echo 'COUNTER_ID sequence set to' :sequence_now
  COMMIT;
  \echo 'Committed.'
\endif
