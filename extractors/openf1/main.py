"""OpenF1 → GCS micro-batch poller.

HTTP-triggered Cloud Run Function, run every minute by Cloud Scheduler.

Default mode (no query params):
- Asks OpenF1 /sessions whether any session is currently active.
- If none → returns 204 (cheap no-op; almost all invocations during off-hours).
- If one or more → for each active session, fetch each configured endpoint
  (laps, stints, …) and write the full result as NDJSON to the lake.

Backfill mode (?session_key=12345 [&endpoints=stints,laps]):
- Forces a fetch for that specific session, ignoring the active-session gate.
- Optional `endpoints` query param overrides the configured ENDPOINTS env var.

Stateless: each invocation re-fetches the full session data per endpoint.
Duplicates land in BQ but the dbt staging layer dedupes on natural keys.

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
DEFAULT_ENDPOINTS = os.environ.get("ENDPOINTS", "laps,stints").split(",")
HTTP_TIMEOUT_S = 30
SESSION_LOOKBACK_HOURS = 2

# Per-endpoint sanitization. Some OpenF1 fields contain NULL elements inside
# REPEATED INTEGER arrays, which BigQuery rejects. Drop those fields.
_DROP_FIELDS = {
    "laps": ("segments_sector_1", "segments_sector_2", "segments_sector_3"),
    # stints: no known issues
}


def _ts() -> str:
    return dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")


def _sanitize(rows: list, endpoint: str) -> list:
    drop = _DROP_FIELDS.get(endpoint, ())
    if not drop:
        return rows
    for r in rows:
        for k in drop:
            r.pop(k, None)
    return rows


def _active_sessions() -> list:
    """A session is 'active' iff it has already started AND has not yet ended."""
    now = dt.datetime.utcnow()
    since = (now - dt.timedelta(hours=SESSION_LOOKBACK_HOURS)).strftime("%Y-%m-%dT%H:%M:%S")
    r = requests.get(f"{BASE}/sessions", params={"date_start>": since}, timeout=HTTP_TIMEOUT_S)
    r.raise_for_status()
    sessions = r.json() or []

    def _trunc(s: str) -> str:
        return s[:19] if s else s
    now_iso = now.strftime("%Y-%m-%dT%H:%M:%S")
    return [
        s for s in sessions
        if _trunc(s.get("date_start", "")) <= now_iso
        and (not s.get("date_end") or _trunc(s["date_end"]) >= now_iso)
    ]


def _fetch(session_key: str, endpoint: str) -> list:
    """Return [] for 404 (endpoint has no data for this session); raise on other HTTP errors."""
    r = requests.get(
        f"{BASE}/{endpoint}",
        params={"session_key": session_key},
        timeout=HTTP_TIMEOUT_S,
    )
    if r.status_code == 404:
        return []
    r.raise_for_status()
    return _sanitize(r.json() or [], endpoint)


def poll(request):
    args = request.args if request and request.args else {}
    sk_override = args.get("session_key") if args else None
    endpoints_override = args.get("endpoints") if args else None
    endpoints = (
        [e.strip() for e in endpoints_override.split(",") if e.strip()]
        if endpoints_override
        else DEFAULT_ENDPOINTS
    )

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
        for ep in endpoints:
            rows = _fetch(sk, ep)
            if not rows:
                log.info(json.dumps({"event": "no_rows", "session_key": sk, "endpoint": ep}))
                continue
            path = f"raw/source=openf1/endpoint={ep}/session={sk}/{_ts()}.ndjson"
            body = "\n".join(json.dumps(r, separators=(",", ":")) for r in rows) + "\n"
            bucket.blob(path).upload_from_string(body, content_type="application/x-ndjson")
            files_written += 1
            total_rows += len(rows)
            log.info(json.dumps({
                "event": "wrote",
                "path": path,
                "rows": len(rows),
                "session_key": sk,
                "endpoint": ep,
            }))

    return (
        {
            "sessions": len(sessions),
            "endpoints": endpoints,
            "files_written": files_written,
            "rows_written": total_rows,
        },
        200,
    )
