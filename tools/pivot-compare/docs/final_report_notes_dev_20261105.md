# Notes for the final report of the dev run 2026-11-05 (NS tables)

Only points that were checked and recorded in evidence.md (sections I and J) belong here. Used with
`FINAL_REPORT_NOTES_FILE`. Each point is one "- " bullet under a section the report builder knows.

## Conclusion
- The result is not a production sign-off. Next: analyse the differences, rerun when the NEW tables hold more periods, and ask the NEW calculator owner about the values that are empty in NEW.
- For IST, MPR and ROUTER the check is per site only (device text differs between OLD and NEW), which is a weaker check.

## Out of scope
- NODE_RIBTM: the NEW side has no such table.
- CM data comparison: not run. Both calculators read gsb_data_cm and take the newest INSERT_DT per cell (checked in the code of both).
- OLD periods that the NEW tables did not hold at the time of the run (OLD holds 13 periods, NEW held 4).
- Production data.

## Variations
- Cells are paired by CELL_NAME, not by SITE_ID and CELL_ID, because the ids differ between OLD and NEW for some cells (Rossmore SITE_ID 407415 in OLD, 1311245 in NEW; CELL_ID 66 is used for two LTE cells at one site in OLD). Id differences are reported in the info-column sheets and do not change the KPI result.
- NODE_GCUF, NODE_IST, NODE_MPR and NODE_ROUTER are paired by SITE_NAME only, because the device text differs between OLD and NEW (OLD GCUF device is the text null, NEW is 1).
- NODE_PIST: the NEW tunnel text was rewritten to the OLD form before pairing (Inner-PeerIpsecTunnel=...-PeerIpsecTunnel becomes Inner_PeerIpsecTunnel=...).

## Observations
- NEW has no NODE_RIBTM table.
- The OLD LTE table holds relation-level rows: 213,231 of the 213,369 OLD-only LTE objects.
- One cell (1000LaTrobeStIBC-O:M3884-OL07-A-1) was found in both OLD tables LTE and MIXED, but only in the NEW LTE table. One site (MarsdenPark2 ... 1311558) is in OLD and not in NEW. Both are single examples, not a rule.
- NEW rows can be written twice with identical values (seen at site 81717). The larger value is used and repeated rows are listed in duplicate_keys.csv.
- The NEW tables changed during testing (periods added, rows rewritten); the fingerprint sheet shows the state that was tested.

## Open items
- Cause of the different values in CELL_MIXED, NODE_FRU, CELL_5G, CELL_SG, CELL_LTE (3 cells, K_-18 and K_-19 at 13:30) and NODE_GCUF (K_-367, OLD about double NEW): not analysed or not proven.
- Values empty in NEW (8,709,550 in total, mostly NODE_EPNGU and CELL_5G) and values empty in OLD (CELL_LTE 374,624): not investigated; question for the NEW calculator owner.
- Objects found on one side only (OLD-only 676,913, NEW-only 140,685): explained for CELL_LTE relation rows only; the rest not analysed.
- Only 4 of the 13 OLD periods were compared.
- Same counters and KPI definitions on both sides: not proven by this test.
