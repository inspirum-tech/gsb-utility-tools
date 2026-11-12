# Notes for the final report of the dev run (NS tables), updated for run 4

DEV ONLY: used with `FINAL_REPORT_NOTES_FILE` in `config_ns_all_dev.env`; the shipped `config_ns_all.env` leaves it empty.
Only points that were checked belong here. Each point is one "- " bullet under a section the report builder knows.
The facts below were checked on the files of run 4 (NEW tables written 2026-11-12 00:46, schema gsb_data_kpi_pivot_dev_V2).
Later data or a change in the NEW calculator can change them. Counts that the report computes itself are not repeated here.

## Conclusion
- This is a comparison report, not a production sign-off. The differences were checked table by table; the causes that are confirmed are listed in the Observations, the others are marked "not yet confirmed" in the open items.
- The NEW tables held 4 of the 13 periods that the OLD tables hold. When the NEW tables hold the full period, run the comparison again for the final verification.
- For GCUF, IST, MPR and ROUTER the check is per site only (device text differs between OLD and NEW), which is a weaker check.

## Out of scope
- NODE_RIBTM: the NEW side has no such table.
- CM data comparison: not needed. Both calculators read gsb_data_cm and take the newest INSERT_DT per cell (checked in the code of both).
- OLD periods that the NEW tables did not hold at the time of the run (OLD holds 13 periods, NEW held 4).
- Input counters and KPI definitions: this test compares the output values of the two calculators only.
- Production data.

## Variations
- Cells are paired by CELL_NAME, not by SITE_ID and CELL_ID, because the ids differ between OLD and NEW for some cells (Rossmore SITE_ID 407415 in OLD, 1311245 in NEW; CELL_ID 66 is used for two LTE cells at one site in OLD). Id differences are reported in the info-column sheets and do not change the KPI result.
- NODE_GCUF, NODE_IST, NODE_MPR and NODE_ROUTER are paired by SITE_NAME only, because the device text differs between OLD and NEW (OLD GCUF device is the text null, NEW is 1).
- NODE_PIST: the NEW tunnel text was rewritten to the OLD form before pairing (Inner-PeerIpsecTunnel=...-PeerIpsecTunnel becomes Inner_PeerIpsecTunnel=...).

## Observations
- Where NEW is empty, OLD holds 0. In the tables whose differences file lists every empty value (CELL_5G, NODE_EP, NODE_GCUF, NODE_FRU, NODE_PIST, NODE_CEM), 1,046,391 of 1,046,425 empty values have OLD = 0; the other 34 are in CELL_5G. For NODE_EPNGU the file lists the first 1,000,000 of its empty values, all with OLD = 0 (run 4).
- CELL_MIXED: of the 14,817 different values, 6,754 have NEW = 0 where OLD has a value, 1,045 have OLD = 0 where NEW has a value, and 7,018 are other differences. They are spread over the 4 periods (3,576 / 3,547 / 3,886 / 3,808) (run 4).
- NODE_FRU: all 585 different values are in one period (13:30 UTC). NODE_GCUF: the 1 different value is in the 13:15 UTC period. CELL_SG: the different values are spread over the 4 periods (22 / 6 / 16 / 8) (run 4).
- Repeated rows with conflicting values (section 3.3.3), by side (run 4): NODE_ROUTER on both sides (OLD 164,168, NEW 163,973), NODE_IST on both sides (OLD 20, NEW 16), NODE_EP only in OLD (185,168; none in NEW). NODE_ROUTER and NODE_IST are compared per site only, so rows of several devices of one site would share one key; this is the probable reason and is not yet confirmed.
- Sample values read by the tool were checked directly in the databases (the OLD value of a sample cell in Postgres, the NEW values of the Blaxland cells in the NEW table) and match what the tool reports (checked 2026-11-06, before the NEW tables were written again).
- The OLD LTE table holds relation-level rows: 213,231 of the 213,369 OLD-only LTE objects.
- One cell (1000LaTrobeStIBC-O:M3884-OL07-A-1) was found in both OLD tables LTE and MIXED, but only in the NEW LTE table. One site (MarsdenPark2 ... 1311558) is in OLD and not in NEW. Both are single examples, not a rule.
- The NEW tables were written again on 2026-11-12 with the same row counts in the tested window; a few values changed (CELL_5G, CELL_MIXED and CELL_SG differ from the run on the earlier data, the other tables are identical). The fingerprint sheet shows the state that was tested.

## Open items
- Not yet confirmed: the cause of the different values in CELL_MIXED, NODE_FRU, CELL_5G, CELL_SG, CELL_LTE (3 cells, K_-18 and K_-19 at 13:30) and NODE_GCUF (K_-367, OLD about double NEW).
- Not yet confirmed: why NEW leaves values empty where OLD holds 0, and why values are empty in OLD (CELL_LTE). Reading of the NEW code: a KPI row is written for a cell only if at least one of the KPI's own counters is present; this is not yet confirmed on data.
- Not yet confirmed: the reason for the repeated rows with conflicting values (section 3.3.3), in particular why NODE_EP has them only in OLD.
- Objects found on one side only: explained for the CELL_LTE relation rows only; for the other tables the reason is not yet confirmed.
- Only 4 of the 13 OLD periods were compared; the comparison is run again when the NEW tables hold the full period.
