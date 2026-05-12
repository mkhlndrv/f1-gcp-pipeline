# GCS → BigQuery loader

Eventarc-triggered Cloud Run Function. Fires on `google.cloud.storage.object.v1.finalized` for `image-lab-f1-lake`. Parses the object path to derive the target `f1_raw.{source}_{endpoint}` table, then `WRITE_APPEND`s the NDJSON. Uses explicit schemas from `schemas/{source}_{endpoint}.json` when present; falls back to autodetect on the first load only.

Malformed files are moved to `gs://image-lab-f1-lake/raw_quarantine/...` and the function fails loudly so monitoring catches it.

_Implementation lands in Phase 3._
