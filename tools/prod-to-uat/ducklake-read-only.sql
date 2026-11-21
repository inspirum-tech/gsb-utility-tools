-- Prod exporter sample. Set DUCKLAKE_INIT to the absolute path of your copy.
-- Replace CHANGE_ME_HOST and CHANGE_ME_READER with the catalog host and read-only role.
-- Authenticate via ~/.pgpass (mode 0600) owned by the SSH export account; no password here.
SET extension_directory = '/apps/moosefs/mount/software/duckdb/extension';
LOAD postgres_scanner;
LOAD ducklake;

ATTACH 'ducklake:postgres:host=CHANGE_ME_HOST port=5432 dbname=ducklake user=CHANGE_ME_READER'
AS gsb (
    DATA_PATH '/apps/moosefs/mount/gsb_data/gsb_kpi_api',
    METADATA_SCHEMA 'metadata',
    READ_ONLY
);
