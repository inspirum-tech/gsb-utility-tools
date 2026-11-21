# prod-to-uat

One command on UAT that exports pivot tables on the prod server (over SSH), copies the zip to UAT, loads it into the
UAT DuckLake with [db-import](../db-import/README.md), and compares with [pivot-compare](../pivot-compare/README.md).

| File | What |
|---|---|
| `export-on-prod.sh` | runs **on prod**: PostgreSQL and/or DuckLake tables -> hourly `<TABLE>_<from>__to__<to>.csv.gz` + `_manifest.csv` -> one zip + `.sha256`. Read only; password from `~/.pgpass` or an environment variable |
| `run-all.sh` | runs **on UAT**: export (ssh) -> copy (scp + checksum) -> load (db-import) -> compare (pivot-compare); `--check`, `--dry-run`, `--steps`, `--name`, `--resume` |
| `config.example.env` | the UAT config: SSH, tables, period, paths |
| `export.example.env` | the prod config: database connection |
| `PROD_TO_UAT_FULL_FLOW_RUNBOOK.md` | **the one runbook for the whole flow**: setup on prod and UAT (including db-import and pivot-compare), every config setting, run, check the result, change the job, failures, undo |
| `PLAN.md` | why it is built this way; findings from the team's `export_pivot_*.sh` scripts |
| `PLAN-EVIDENCE.md` | what was tested on dev, with commands and real output |
| `tests/` | `bash tests/test_export.sh`, `bash tests/test_run_all.sh` (fake psql, no database or SSH needed) |

Start with [PROD_TO_UAT_FULL_FLOW_RUNBOOK.md](PROD_TO_UAT_FULL_FLOW_RUNBOOK.md).
