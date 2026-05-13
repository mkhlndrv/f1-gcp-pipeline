"""GCS → BigQuery loader.

Eventarc-triggered Cloud Run Function. Fires on every
`google.cloud.storage.object.v1.finalized` event in the lake bucket.

For files matching `raw/source=<src>/endpoint=<ep>/...`, the loader appends
the NDJSON into `<project>.<RAW_DATASET>.<src>_<lowercased ep>`. Anything else
(state files, quarantine, manual uploads) is ignored.

On a load failure (bad JSON, schema mismatch) the offending object is copied
to `raw_quarantine/<original key>`, the original deleted, and the function
returns 200 — so Eventarc does NOT retry. A `severity=ERROR` log line is
emitted so Cloud Monitoring (Phase 11) can alert.
"""
import json
import logging
import os
import re

import functions_framework
from cloudevents.http import CloudEvent
from google.api_core.exceptions import GoogleAPIError
from google.cloud import bigquery, storage

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger(__name__)

PROJECT = os.environ["PROJECT_ID"]
RAW_DATASET = os.environ.get("RAW_DATASET", "f1_raw")
SCHEMA_DIR = os.path.join(os.path.dirname(__file__), "schemas")
QUARANTINE_PREFIX = "raw_quarantine/"

PATH_RE = re.compile(r"^raw/source=(?P<src>[^/]+)/endpoint=(?P<ep>[^/]+)/")

bq = bigquery.Client(project=PROJECT)
gcs = storage.Client(project=PROJECT)


def _load_schema(src: str, ep_lc: str):
    """Return a BQ schema list if a committed file exists, else None."""
    path = os.path.join(SCHEMA_DIR, f"{src}_{ep_lc}.json")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return [bigquery.SchemaField.from_api_repr(field) for field in json.load(f)]


def _quarantine(bucket_name: str, object_name: str, reason: str) -> None:
    """Move a bad object to raw_quarantine/ and log a structured ERROR.

    The "severity" key is a Cloud Logging convention — when emitted in a JSON
    log line, Cloud Logging tags the entry with that severity. Without it,
    Python's logging.error() routes through stdout but Cloud Logging shows the
    entry with no severity, so log-based alerts won't fire.
    """
    bucket = gcs.bucket(bucket_name)
    src_blob = bucket.blob(object_name)
    if not src_blob.exists():
        log.error(json.dumps({
            "severity": "ERROR",
            "event": "quarantine_miss",
            "object": object_name,
            "reason": reason,
        }))
        return
    dest = f"{QUARANTINE_PREFIX}{object_name}"
    bucket.copy_blob(src_blob, bucket, new_name=dest)
    src_blob.delete()
    log.error(json.dumps({
        "severity": "ERROR",
        "event": "quarantined",
        "from": f"gs://{bucket_name}/{object_name}",
        "to": f"gs://{bucket_name}/{dest}",
        "reason": reason,
    }))


@functions_framework.cloud_event
def load(cloud_event: CloudEvent):
    data = cloud_event.data
    bucket_name = data["bucket"]
    object_name = data["name"]

    if object_name.startswith(QUARANTINE_PREFIX):
        log.info(json.dumps({"event": "skipped", "reason": "quarantine_prefix", "object": object_name}))
        return ("", 200)

    m = PATH_RE.search(object_name)
    if not m:
        log.info(json.dumps({"event": "skipped", "reason": "path_unrecognized", "object": object_name}))
        return ("", 200)

    src = m["src"]
    ep_lc = m["ep"].lower()
    table_id = f"{PROJECT}.{RAW_DATASET}.{src}_{ep_lc}"
    uri = f"gs://{bucket_name}/{object_name}"

    schema = _load_schema(src, ep_lc)
    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
        schema=schema,
        autodetect=schema is None,
        ignore_unknown_values=True,
    )

    try:
        job = bq.load_table_from_uri(uri, table_id, job_config=job_config)
        job.result()
    except (GoogleAPIError, ValueError) as e:
        _quarantine(bucket_name, object_name, reason=str(e))
        return ("", 200)

    log.info(
        json.dumps(
            {
                "event": "loaded",
                "uri": uri,
                "table": table_id,
                "output_rows": job.output_rows,
                "schema_source": "file" if schema else "autodetect",
            }
        )
    )
    return ("", 200)
