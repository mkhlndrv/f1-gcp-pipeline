"""Ergast (Jolpica) → GCS extractor.

HTTP-triggered Cloud Run Function. On each invocation, fetches a configurable
list of Ergast endpoints for a season and writes one NDJSON file per page to
GCS. Each NDJSON line is the full `MRData` payload; the dbt staging layer
unpacks it via `json_value` / `json_query`.

Config (env vars):
    GCS_BUCKET  required          lake bucket
    ENDPOINTS   comma-separated   default: seasons,drivers,results,qualifying,driverStandings
    SEASON      year string       default: current UTC year
    BASE_URL    Ergast root       default: https://api.jolpi.ca/ergast/f1

Query-string overrides (?season=, ?endpoints=) take precedence over env vars.
"""
import datetime as dt
import json
import logging
import os
import time

import requests
from google.cloud import storage

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger(__name__)

BUCKET = os.environ["GCS_BUCKET"]
DEFAULT_ENDPOINTS = os.environ.get(
    "ENDPOINTS",
    "seasons,drivers,results,qualifying,driverStandings",
).split(",")
DEFAULT_SEASON = os.environ.get("SEASON") or str(dt.datetime.utcnow().year)
BASE = os.environ.get("BASE_URL", "https://api.jolpi.ca/ergast/f1").rstrip("/")

PAGE_LIMIT = 100
SLEEP_BETWEEN_PAGES_S = 0.3
HTTP_TIMEOUT_S = 30

# `seasons` is the only endpoint that lives at the root (no /{season}/ prefix).
ROOT_ENDPOINTS = {"seasons"}


def _url(season: str, endpoint: str, offset: int) -> str:
    if endpoint in ROOT_ENDPOINTS:
        return f"{BASE}/{endpoint}.json?limit={PAGE_LIMIT}&offset={offset}"
    return f"{BASE}/{season}/{endpoint}.json?limit={PAGE_LIMIT}&offset={offset}"


def _fetch_pages(season: str, endpoint: str):
    """Yield (offset, MRData_dict) for each page until total is exhausted."""
    offset = 0
    while True:
        url = _url(season, endpoint, offset)
        r = requests.get(url, timeout=HTTP_TIMEOUT_S)
        r.raise_for_status()
        body = r.json().get("MRData") or {}
        yield offset, body
        try:
            total = int(body.get("total", 0))
        except (TypeError, ValueError):
            total = 0
        offset += PAGE_LIMIT
        if offset >= total:
            return
        time.sleep(SLEEP_BETWEEN_PAGES_S)


def extract(request):
    """HTTP entry point. Returns ({season, endpoints, files_written}, 200)."""
    season = (request.args.get("season") if request and request.args else None) or DEFAULT_SEASON
    eps_q = request.args.get("endpoints") if request and request.args else None
    endpoints = [e.strip() for e in (eps_q.split(",") if eps_q else DEFAULT_ENDPOINTS) if e.strip()]

    today = dt.datetime.utcnow().strftime("%Y-%m-%d")
    ts = dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")

    client = storage.Client()
    bucket = client.bucket(BUCKET)

    files_written = 0
    for ep in endpoints:
        for offset, body in _fetch_pages(season, ep):
            path = (
                f"raw/source=ergast/endpoint={ep}/dt={today}/"
                f"season={season}-page{offset}-{ts}.ndjson"
            )
            line = json.dumps(body, separators=(",", ":")) + "\n"
            bucket.blob(path).upload_from_string(line, content_type="application/x-ndjson")
            files_written += 1
            log.info(
                json.dumps(
                    {
                        "event": "wrote",
                        "endpoint": ep,
                        "season": season,
                        "offset": offset,
                        "path": path,
                    }
                )
            )

    return ({"season": season, "endpoints": endpoints, "files_written": files_written}, 200)
