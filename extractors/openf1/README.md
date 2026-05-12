# OpenF1 poller

1-minute self-gated Cloud Run Function. Polls OpenF1 for active sessions; when one is live, pulls new laps since the last high-water-mark and writes NDJSON to `gs://image-lab-f1-lake/raw/source=openf1/endpoint=*/session=*/`. Returns 204 immediately when no session is active, so off-weekend the cost is near-zero.

_Implementation lands in Phase 9._
