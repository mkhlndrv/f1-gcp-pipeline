"""OpenF1 → GCS micro-batch poller.

HTTP-triggered Cloud Run Function, run every minute by Cloud Scheduler.

Default mode (no query params):
- Asks OpenF1 /sessions whether any session is currently active.
- If none → returns 204 (cheap no-op; almost all invocations during off-hours).
- If one or more → for each active session, fetch /laps for that session and
  write the full result as NDJSON to the lake.

Backfill mode (?session_key=12345):
- Forces a fetch for that specific session, ignoring the active-session gate.
  Used for smoke-testing and ad-hoc historical loads.

Stateless: each invocation re-fetches the full session laps. Duplicates land in
BQ but the dbt staging layer dedupes on natural keys. This trades a small
amount of BQ storage / OpenF1 calls for total elimination of state-management
complexity and IAM read permissions.

Conventions match Ergast: env-var config, structured stdout JSON logging,
requests with timeout=30 + raise_for_status(), no inline retries.
"""
import datetime as dt
import json
import logging
import os

import requests
from google.cloud import storage

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger(__name__)

BUCKET = os.environ["GCS_BUCKET"]
BASE = os.environ.get("BASE_URL", "https://api.openf1.org/v1").rstrip("/")
HTTP_TIMEOUT_S = 30
SESSION_LOOKBACK_HOURS = 2


def _ts() -> str:
    return dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")


def _active_sessions() -> list:
    """A session is 'active' iff it has already started AND has not yet ended."""
    now = dt.datetime.utcnow()
    since = (now - dt.timedelta(hours=SESSION_LOOKBACK_HOURS)).strftime("%Y-%m-%dT%H:%M:%S")
    r = requests.get(f"{BASE}/sessions", params={"date_start>": since}, timeout=HTTP_TIMEOUT_S)
    r.raise_for_status()
    sessions = r.json() or []
    # OpenF1 returns ISO with timezone (...+00:00); strip it to compare as naive UTC.
    def _trunc(s: str) -> str:
        return s[:19] if s else s
    now_iso = now.strftime("%Y-%m-%dT%H:%M:%S")
    return [
        s for s in sessions
        if _trunc(s.get("date_start", "")) <= now_iso
        and (not s.get("date_end") or _trunc(s["date_end"]) >= now_iso)
    ]


# segments_sector_* are arrays of mini-sector status codes; OpenF1 returns
# null at the field level (sector not completed) AND null *elements* inside
# the array (mini-sector lacks data). Both forms break BQ's REPEATED INTEGER
# (REPEATED can be empty but not null; elements must be non-null integers).
# We don't need these fields for Tier 2 pace analytics, so drop them entirely.
_DROP_FIELDS = ("segments_sector_1", "segments_sector_2", "segments_sector_3")


def _sanitize(rows: list) -> list:
    for r in rows:
        for k in _DROP_FIELDS:
            r.pop(k, None)
    return rows


def _fetch_laps(session_key: str) -> list:
    """Return [] for 404 (session has no laps yet); raise on other HTTP errors."""
    r = requests.get(
        f"{BASE}/laps",
        params={"session_key": session_key},
        timeout=HTTP_TIMEOUT_S,
    )
    if r.status_code == 404:
        return []
    r.raise_for_status()
    return _sanitize(r.json() or [])


def poll(request):
    sk_override = (request.args.get("session_key") if request and request.args else None)
    bucket = storage.Client().bucket(BUCKET)

    if sk_override:
        sessions = [{"session_key": int(sk_override)}]
    else:
        sessions = _active_sessions()
        if not sessions:
            log.info(json.dumps({"event": "no_active_session"}))
            return ("", 204)

    total_rows = 0
    files_written = 0
    for s in sessions:
        sk = str(s["session_key"])
        laps = _fetch_laps(sk)
        if not laps:
            log.info(json.dumps({"event": "no_laps", "session_key": sk}))
            continue
        path = f"raw/source=openf1/endpoint=laps/session={sk}/{_ts()}.ndjson"
        body = "\n".join(json.dumps(r, separators=(",", ":")) for r in laps) + "\n"
        bucket.blob(path).upload_from_string(body, content_type="application/x-ndjson")
        files_written += 1
        total_rows += len(laps)
        log.info(json.dumps({"event": "wrote", "path": path, "rows": len(laps), "session_key": sk}))

    return ({"sessions": len(sessions), "files_written": files_written, "rows_written": total_rows}, 200)
