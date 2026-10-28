"""
Publish parser trigger messages to NATS for files already placed in the parser input queue.

Stand-in for gsb-find-raw-file when it is not running (e.g. dev). It does NOT copy files;
it only walks the existing block folders created by the file finder:

    {input_base_path}/{VENDOR}_PM/YYYYMMDD/HHMMSS          -> xml
    {input_base_path}/{VENDOR}_PM/YYYYMMDD/HHMMSS_ebsn     -> ebsn (ERS only)
    {input_base_path}/{VENDOR}_PM/YYYYMMDD/HHMMSS_ebsl     -> ebsl (ERS only)

For each 15-minute block it builds the same message as file_service.process_block and
publishes it to the vendor subject. Missing/empty blocks are skipped (same as the file finder).

Usage:
    python publish_parser_trigger.py config-dev.properties
    python publish_parser_trigger.py config-dev.properties --dry-run
"""
import argparse
import asyncio
import json
import logging
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from nats.aio.client import Client as NATS
from nats.js.api import RetentionPolicy, StreamConfig
from nats.js.errors import NotFoundError

logger = logging.getLogger("parser_trigger")

SYDNEY_TZ = ZoneInfo("Australia/Sydney")
VENDORS = ["ERS", "NSN", "HW"]
TIME_FMT = "%Y-%m-%d %H:%M:%S"


def load_properties(filepath):
    """Same key=value format as the file finder; supports {vendor} placeholders at use time."""
    props = {}
    with open(filepath, "r") as f:
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            k, v = stripped.split("=", 1)
            v = v.strip()
            if " #" in v:
                v = v.split(" #", 1)[0].rstrip()
            props[k.strip()] = v
    return props


def vendor_prop(props, vendor, key, default=None):
    """Read '<vendor>_<key>' (e.g. ers_start_time), with {vendor} placeholder substitution."""
    value = props.get(f"{vendor.lower()}_{key}", props.get(key, default))
    if isinstance(value, str):
        value = value.replace("{vendor}", vendor)
    return value


def count_files(folder):
    """Count the files the file finder would have copied (.xml.gz / .zip, non-empty)."""
    if not folder.is_dir():
        return 0
    count = 0
    for root, _, files in os.walk(folder):
        for fname in files:
            if fname.endswith(".xml.gz") or fname.endswith(".zip"):
                try:
                    if os.path.getsize(Path(root) / fname) > 0:
                        count += 1
                except OSError:
                    continue
    return count


def build_message(vendor, base, block_time):
    """Return the file finder message for this block, or None if the block has no files."""
    vendor_root = base / f"{vendor}_PM" / block_time.strftime("%Y%m%d")
    sub_folder = block_time.strftime("%H%M%S")
    folders = [("xml", vendor_root / sub_folder)]
    if vendor == "ERS":
        folders.append(("ebsn", vendor_root / f"{sub_folder}_ebsn"))
        folders.append(("ebsl", vendor_root / f"{sub_folder}_ebsl"))

    counters = []
    for counter_type, folder in folders:
        file_count = count_files(folder)
        if file_count > 0:
            counters.append({
                "type": counter_type,
                "file_count": file_count,
                "output_path": str(folder),
            })
    if not counters:
        return None

    return {
        "vendor": vendor,
        "upload_block_time": block_time.strftime(TIME_FMT),
        "created": datetime.now(SYDNEY_TZ).strftime(TIME_FMT),
        "counters": counters,
    }


def resolve_end_time(props, vendor, base):
    """Configured end time, else the last 15-min block of the latest date folder present."""
    end_str = vendor_prop(props, vendor, "end_time")
    if end_str:
        return datetime.strptime(end_str, TIME_FMT)
    vendor_dir = base / f"{vendor}_PM"
    dates = sorted(d.name for d in vendor_dir.iterdir() if d.is_dir() and d.name.isdigit() and len(d.name) == 8) \
        if vendor_dir.is_dir() else []
    if not dates:
        return None
    return datetime.strptime(dates[-1], "%Y%m%d") + timedelta(hours=23, minutes=45)


async def connect(servers):
    nc = NATS()
    logger.info(f"Connecting to NATS servers: {servers}")
    await nc.connect(
        servers=servers,
        allow_reconnect=True,
        max_reconnect_attempts=2,
        reconnect_time_wait=1,
        connect_timeout=5,
    )
    return nc


async def ensure_stream(js, stream_name, subject, retention_in_hours, num_replicas):
    """Create the stream if missing (the file finder normally does this). Existing streams are left as-is."""
    try:
        await js.stream_info(stream_name)
        logger.info(f"NATS stream '{stream_name}' exists.")
    except NotFoundError:
        logger.info(f"NATS stream '{stream_name}' does not exist. Creating it.")
        await js.add_stream(
            name=stream_name,
            config=StreamConfig(
                name=stream_name,
                subjects=[subject],
                storage="file",
                num_replicas=num_replicas,
                retention=RetentionPolicy.LIMITS,
                max_age=retention_in_hours * 60 * 60,
            ),
        )


async def process_vendor(props, vendor, dry_run):
    base = Path(props["input_base_path"])
    increment = int(props.get("upload_block_time_increment_in_minute", "15"))
    start_time = datetime.strptime(vendor_prop(props, vendor, "start_time"), TIME_FMT)
    end_time = resolve_end_time(props, vendor, base)
    subject = vendor_prop(props, vendor, "nats_stream_subject")
    stream_name = vendor_prop(props, vendor, "nats_stream_name")
    publish_interval = float(props.get("publish_interval_seconds", "0"))

    if end_time is None:
        logger.warning(f"[{vendor}] No date folders under {base / f'{vendor}_PM'}. Skipping vendor.")
        return
    logger.info(f"[{vendor}] Blocks {start_time} -> {end_time} (inclusive), subject={subject}, "
                f"publish_interval={publish_interval}s, dry_run={dry_run}")

    nc = None
    js = None
    if not dry_run:
        nc = await connect([s.strip() for s in props["nats_servers"].split(",") if s.strip()])
        js = nc.jetstream()
        await ensure_stream(js, stream_name, subject,
                            float(props.get("message_retention_in_hours", "168")),
                            int(props.get("nats_stream_num_replicas", "1")))

    sent = skipped = 0
    try:
        block_time = start_time
        while block_time <= end_time:
            msg = build_message(vendor, base, block_time)
            if msg is None:
                logger.debug(f"[{vendor}] {block_time} missing/empty, checking next block.")
                skipped += 1
            elif dry_run:
                logger.info(f"[{vendor}] DRY-RUN {json.dumps(msg)}")
                sent += 1
            else:
                ack = await js.publish(subject, json.dumps(msg).encode())
                logger.info(f"[{vendor}] Published {msg['upload_block_time']} to {subject}, "
                            f"stream {ack.stream}, seq {ack.seq}, counters={[(c['type'], c['file_count']) for c in msg['counters']]}")
                sent += 1
                if publish_interval > 0:
                    await asyncio.sleep(publish_interval)
            block_time += timedelta(minutes=increment)
    finally:
        if nc is not None:
            try:
                await nc.drain()
            except Exception:
                await nc.close()

    logger.info(f"[{vendor}] Done. Messages {'(dry-run) ' if dry_run else ''}sent: {sent}, empty/missing blocks skipped: {skipped}")


def main():
    parser = argparse.ArgumentParser(description="Publish parser trigger messages for pre-placed parser input files")
    parser.add_argument("config", help="Path to environment properties file (e.g. config-dev.properties)")
    parser.add_argument("--dry-run", action="store_true", help="Log the messages without publishing")
    args = parser.parse_args()

    props = load_properties(args.config)
    logging.basicConfig(
        level=props.get("log_level", "info").upper(),
        format="%(asctime)s,%(levelname)s,%(message)s",
        datefmt=TIME_FMT,
        stream=sys.stdout,
    )

    enabled = [v for v in VENDORS if vendor_prop(props, v, "enabled", "true").lower() == "true"]
    logger.info(f"Config: {args.config}, enabled vendors: {enabled}")

    for vendor in enabled:
        try:
            asyncio.run(process_vendor(props, vendor, args.dry_run))
        except Exception as e:
            logger.error(f"[{vendor}] Failed: {e}", exc_info=True)


if __name__ == "__main__":
    main()
