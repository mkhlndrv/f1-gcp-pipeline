# Ergast extractor

HTTP-triggered Cloud Run Function. Pulls F1 race-weekend data from the Jolpica/Ergast API and writes one NDJSON file per page to the GCS lake.

Each NDJSON file contains a **single line**: the entire `MRData` payload from one paginated response. dbt staging models unpack it via `json_value` / `json_query`. This keeps the extractor dumb and the contract stable.

## Configuration

All config is via env vars; nothing is hard-coded. Query-string params override env defaults.

| Variable     | Required | Default                                                        | Notes                                    |
|--------------|----------|----------------------------------------------------------------|------------------------------------------|
| `GCS_BUCKET` | yes      | —                                                              | Lake bucket (e.g. `image-lab-f1-lake`).  |
| `ENDPOINTS`  | no       | `seasons,drivers,results,qualifying,driverStandings`           | Comma-separated Ergast endpoints.        |
| `SEASON`     | no       | current UTC year                                               | Year to fetch.                           |
| `BASE_URL`   | no       | `https://api.jolpi.ca/ergast/f1`                               | Override only for testing.               |

Query-string overrides:
- `?season=2024` — fetch a specific season.
- `?endpoints=results,qualifying` — fetch a subset.

## GCS path layout

```
gs://<bucket>/raw/source=ergast/endpoint=<ep>/dt=<UTC YYYY-MM-DD>/season=<year>-page<N>-<UTC timestamp>.ndjson
```

Filenames include the offset and a UTC timestamp, so re-invocations never overwrite — they accumulate.

## Local development

```bash
cd extractors/ergast
python3.11 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export GCS_BUCKET=image-lab-f1-lake
functions-framework --target=extract --port=8080
# in another terminal:
curl 'http://localhost:8080?season=2024&endpoints=results'

gsutil ls gs://image-lab-f1-lake/raw/source=ergast/endpoint=results/
```

You need `gcloud auth application-default login` for the local client to write to GCS.

## Deploy

```bash
bash deploy/deploy_extractor_ergast.sh
```

After deploy, invoke it once manually:

```bash
gcloud functions call ergast-extractor --gen2 --region=us-central1 --data='{}'
```

Or with curl (auth-only endpoint):

```bash
URL=$(gcloud functions describe ergast-extractor --gen2 --region=us-central1 \
       --format='value(serviceConfig.uri)')
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
     "${URL}?season=2024"
```

## Notes

- **No inline retries.** If a request fails, the function fails; Cloud Scheduler retries the whole invocation. Keeps the code simple and idempotent.
- **Rate-limited.** The extractor sleeps 0.3 s between pages — well under Jolpica's 4 req/s burst limit even with several endpoints in one invocation.
- **Idempotent.** Filenames embed a UTC timestamp, so the same data fetched twice lands in two different files. The downstream loader appends — duplicates are deduped in dbt staging on natural keys.
