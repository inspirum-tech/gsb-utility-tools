# Parser trigger publisher

Publishes the same NATS message as gsb-find-raw-file for files that are already under
`/mnt/mfs/gsb_data/parser-input-queue/{VENDOR}_PM/YYYYMMDD/HHMMSS[_ebsn|_ebsl]`.
It does not copy files. Missing or empty blocks are skipped and it moves on to the next 15-minute block.

## Run

Install once (add `tzdata` if the host has no system zoneinfo):

    pip install nats-py==2.10.0

Dry run (prints the messages, publishes nothing):

    python publish_parser_trigger.py config-dev.properties --dry-run

Publish in the foreground:

    python publish_parser_trigger.py config-dev.properties

Publish in the background with a log file:

    nohup python publish_parser_trigger.py config-dev.properties > parser_trigger.log 2>&1 &
    tail -f parser_trigger.log

## End

The script exits on its own once every enabled vendor reaches its end time (the last line per vendor is `[VENDOR] Done.`).

To stop it early in the foreground, press `Ctrl+C`.

To stop it early in the background:

    pkill -f publish_parser_trigger.py

Messages already published stay in the stream. Stopping the script does not remove them.

## Config

- `ers_enabled` / `nsn_enabled` / `hw_enabled`: turn each vendor on or off (all `true` by default)
- `<vendor>_start_time`: first block to publish
- `publish_interval_seconds`: how long to wait after each published message (120 = 2 minutes; 0 = no wait)
- `<vendor>_end_time` (optional): last block to publish. When not set, it runs to 23:45 of the latest date folder
- Subject `parser.raw.input.{VENDOR}` and stream `parser_raw_input_{VENDOR}` are the ones the parser listens to

Each run publishes everything from the start time again. Change the start time (or set an end time) if you need a partial run.
