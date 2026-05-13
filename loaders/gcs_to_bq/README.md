# GCS → BigQuery loader

Eventarc-triggered Cloud Run Function. Fires on every
`google.cloud.storage.object.v1.finalized` event in `image-lab-f1-lake`.

For files matching the lake convention, the loader appends the NDJSON into the
matching `f1_raw` table. Everything else (state files, manual uploads, quarantine churn) is ignored.

## Configuration

| Variable      | Required | Default  | Notes                              |
|---------------|----------|----------|------------------------------------|
| `PROJECT_ID`  | yes      | —        | GCP project (e.g. `image-lab-494712`). |
| `RAW_DATASET` | no       | `f1_raw` | Target BigQuery dataset.           |

## Path → table mapping

```
raw/source=<src>/endpoint=<ep>/...      →   f1_raw.<src>_<ep_lc>
raw_quarantine/...                       →   skipped
anything else                            →   skipped
```

`<ep_lc>` is the endpoint name lowercased. Ergast uses camelCase for some endpoints, so:

| Object path fragment              | BQ table                       |
|-----------------------------------|--------------------------------|
| `endpoint=results/`               | `f1_raw.ergast_results`        |
| `endpoint=qualifying/`            | `f1_raw.ergast_qualifying`     |
| `endpoint=drivers/`               | `f1_raw.ergast_drivers`        |
| `endpoint=seasons/`               | `f1_raw.ergast_seasons`        |
| `endpoint=driverStandings/`       | `f1_raw.ergast_driverstandings` |
| `endpoint=laps/` (openf1)         | `f1_raw.openf1_laps`           |

dbt staging models in Phase 5 must reference the lowercase table names.

## Schemas

`schemas/<src>_<ep_lc>.json` files are the contract for each table. The loader
loads them at startup; if a file is absent, the loader falls back to BigQuery
autodetect (first-load only).

**Snapshot workflow.** After a clean first load, dump the autodetected schema:

```bash
for ep in seasons drivers results qualifying driverstandings; do
  bq show --schema --format=prettyjson "f1_raw.ergast_${ep}" \
    > "loaders/gcs_to_bq/schemas/ergast_${ep}.json"
done
```

Commit the JSON files. From that point on, the contract is explicit — schema
drift is intentional. To allow a new column through, edit the schema file and
redeploy.

`ignore_unknown_values=True` is set on every load, so future API additions
will not break the loader; new fields just won't show up in BQ until the
schema file is updated.

## Quarantine behaviour

If a load fails (bad JSON, schema mismatch), the loader:

1. Copies the offending object to `gs://<bucket>/raw_quarantine/<original key>`.
2. Deletes the original.
3. Emits `severity=ERROR` (Phase 11 alert policy fires on this).
4. Returns `200` to Eventarc — no infinite retry loops on a poison file.

The `raw_quarantine/` prefix is on a 30-day lifecycle policy (set in Phase 0).

## Deploy

```bash
bash deploy/deploy_loader.sh
```

The script is idempotent. Re-running updates the function and trigger in place.

## Local testing

The loader is event-driven and awkward to run locally. Easiest test loops are:

- **Happy path:** re-invoke the Ergast extractor (`gcloud functions call ergast-extractor ...`) and tail `gcloud functions logs read gcs-to-bq-loader --gen2 --region=us-central1 --limit=20`.
- **Quarantine:** drop a malformed file into the lake under a recognized path and watch it land in `raw_quarantine/`.

```bash
echo 'not json' | gsutil cp - gs://image-lab-f1-lake/raw/source=ergast/endpoint=results/dt=2026-05-12/_bad.ndjson
gsutil ls gs://image-lab-f1-lake/raw_quarantine/
```
