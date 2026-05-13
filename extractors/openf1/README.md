# OpenF1 poller

1-minute self-gated Cloud Run Function. Polls the OpenF1 community API for live F1 laps during active sessions; returns 204 (cheap no-op) outside session windows. Writes one NDJSON file per invocation per active session to the GCS lake.

## Configuration

| Variable     | Required | Default                          | Notes                                       |
|--------------|----------|----------------------------------|---------------------------------------------|
| `GCS_BUCKET` | yes      | —                                | Lake bucket (e.g. `image-lab-f1-lake`).     |
| `BASE_URL`   | no       | `https://api.openf1.org/v1`      | Override only for testing.                  |

Query params:
- (none) — **default mode**: polls `/sessions`, self-gates on whether any are active, writes new laps since the high-water-mark.
- `?session_key=12345` — **backfill mode**: forces a fetch for that one session, ignoring HWM and the active-session gate. Used for smoke tests and historical loads.

## GCS path

```
gs://<bucket>/raw/source=openf1/endpoint=laps/session=<session_key>/<UTC ts>.ndjson
```

One record per line; each line is one lap from the OpenF1 `/laps` response.

## Stateless design (no HWM)

Each invocation re-fetches the full set of laps for every active session. Duplicates land in BigQuery; the dbt staging layer dedupes on natural keys. This trades a small amount of BQ storage and OpenF1 bandwidth (a few hundred extra rows per minute during a session) for the elimination of state-management complexity and additional bucket-read IAM permissions for the extractor SA.

## Local development

This function is awkward to run locally (it needs GCS write + an active F1 session for the default path). Easiest test loop is the deployed backfill mode (see "Smoke test" below).

If you do want to run it locally:

```bash
cd extractors/openf1
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export GCS_BUCKET=image-lab-f1-lake
functions-framework --target=poll --port=8081
# in another terminal:
curl 'http://localhost:8081?session_key=9999'   # backfill a known past session
```

## Deploy

```bash
bash deploy/deploy_extractor_openf1.sh
```

## Smoke test (deployed, backfill mode)

```bash
URL=$(gcloud functions describe openf1-poller --gen2 --region=us-central1 \
       --format='value(serviceConfig.uri)')

# Find a recent past session (any race):
curl -s 'https://api.openf1.org/v1/sessions?session_type=Race&year=2025' | jq '.[-1].session_key'

# Fire backfill for that session:
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
     "${URL}?session_key=<KEY>"

# Watch GCS, then BQ:
gsutil ls gs://image-lab-f1-lake/raw/source=openf1/endpoint=laps/session=<KEY>/
sleep 30
bq query --use_legacy_sql=false 'SELECT COUNT(*) FROM `image-lab-494712.f1_raw.openf1_laps`'
```

## Notes

- **No inline retries.** Cloud Scheduler retries the whole invocation if it fails.
- **`--max-instances=1`** at deploy time so concurrent HWM writes can't race.
- **OpenF1 is community-run.** Mid-session outages are possible; we lose those minutes' data, but Ergast recovers the canonical results history once the race is over.
