# CLAUDE.md

Guidance for AI coding agents (Claude Code, Cursor, etc.) working in this repo.
Humans can read it too — it's also a quick orientation doc.

---

## Project summary

End-to-end F1 race-weekend analytics pipeline on GCP.

- **Sources:** Jolpica/Ergast (batch) + OpenF1 (streaming).
- **Pipeline type:** Hybrid — daily batch for Ergast, 1-minute polling for OpenF1 (self-gates outside session windows).
- **Flow:** Cloud Scheduler → Cloud Run Functions (extractors) → GCS lake → Cloud Run Function (loader) → BigQuery `f1_raw` → dbt (Cloud Run Job) → `f1_staging` → `f1_marts` → Looker Studio.
- **Headline metric:** `fct_clean_air_pace` — fuel- and traffic-corrected per-driver per-compound lap time vs. field median.

---

## Repo layout

```
f1-pipeline/
├── extractors/
│   ├── ergast/           # daily batch extractor (HTTP-triggered)
│   └── openf1/           # 1-min poller, self-gates on active session
├── loaders/
│   └── gcs_to_bq/        # GCS finalize → BigQuery load (event-triggered)
├── dbt/
│   ├── models/staging/   # views; one per source endpoint
│   ├── models/marts/     # incremental tables; dims + facts
│   └── macros/
├── dbt_runner/           # Cloud Run Job that runs `dbt build` daily
├── infra/                # API enablement, IAM, alert policies
├── deploy/               # gcloud deploy scripts for each component
├── .github/workflows/    # CI: lint + dbt build on sample
└── README.md
```

Each Python component owns its own `main.py`, `requirements.txt`, and a short `README.md`.

---

## GCP constants (single source of truth)

| Setting              | Value                              |
|----------------------|------------------------------------|
| Project ID           | `image-lab-494712`                 |
| Region               | `us-central1`                      |
| GCS lake bucket      | `image-lab-f1-lake`                |
| BQ datasets          | `f1_raw`, `f1_staging`, `f1_marts` |
| BQ location          | `US`                               |
| Daily batch schedule | `0 6 * * *` Europe/Madrid          |
| OpenF1 poll schedule | `*/1 * * * *` UTC                  |

Service accounts (least privilege):

- `f1-extractor-sa` — GCS write only on `image-lab-f1-lake/raw/*`.
- `f1-loader-sa` — GCS read on lake; BQ load into `f1_raw`.
- `f1-dbt-sa` — BQ read raw; write `f1_staging` and `f1_marts`.

---

## Conventions

### Python (extractors, loader)
- Python 3.11, `functions-framework` for Cloud Run Functions.
- All config via env vars; no hardcoded project/bucket/dataset names.
- Logging via `logging` module, INFO level, structured to stdout (Cloud Logging picks it up).
- Idempotent writes: filenames include UTC timestamp; never overwrite.
- Requests: `requests` with `timeout=30` and `raise_for_status()`. No retries inline — Scheduler retries the whole invocation.
- No secrets in code. If a secret is ever needed, use Secret Manager and document it in the component README.

### GCS lake layout
```
raw/source=ergast/endpoint=<name>/dt=YYYY-MM-DD/<file>.ndjson
raw/source=openf1/endpoint=<name>/session=<key>/<file>.ndjson
```
Always NDJSON (newline-delimited JSON). One record per line. UTF-8.

### BigQuery
- `f1_raw.*` — append-only, partitioned by `_ingested_date` (DATE), clustered by natural key (`session_key` for OpenF1, `(season, round)` for Ergast).
- `f1_staging.*` — views only.
- `f1_marts.*` — incremental tables, `partition_by` on race date, `cluster_by=['driver_id','race_id']`.
- Schema autodetect on initial load is fine; once a table exists, do not let autodetect change types.

### dbt
- One model = one file. File name == table/view name.
- `materialized='view'` for staging, `materialized='incremental'` for facts, `materialized='table'` for small dims.
- Every model has an entry in the relevant `schema.yml` with at least: description, columns, and `unique`+`not_null` tests on natural keys.
- Use `{{ ref(...) }}` everywhere; never reference raw tables by literal name.
- Macros go in `dbt/macros/`. Don't introduce a new macro for something used in only one model.

---

## Local dev workflow

1. `gcloud auth application-default login` once.
2. Install component deps: `pip install -r extractors/ergast/requirements.txt` (etc.).
3. Run an extractor locally with `functions-framework --target=<entry_point>`.
4. dbt: `cd dbt && dbt deps && dbt build --select <model>`.

CI (`.github/workflows/ci.yml`) runs ruff + `dbt build --target ci` against a small sample on every PR to `main`.

---

## Deployment

All deploys are gcloud scripts under `deploy/`. Run them from repo root:

- `bash deploy/deploy_extractor_ergast.sh`
- `bash deploy/deploy_extractor_openf1.sh`
- `bash deploy/deploy_loader.sh`
- `bash deploy/deploy_dbt_runner.sh`
- `bash deploy/create_schedulers.sh`

Each script is idempotent — re-running updates the existing resource in place.

---

## Guardrails for AI agents

**Do**
- Stay within the repo layout above. New components go in their own top-level folder with their own README.
- Keep extractors, loader, and dbt physically decoupled. They communicate only via GCS and BigQuery.
- Add a dbt test whenever you add a column that's used as a key or join.
- Update the relevant component `README.md` when changing behaviour or env vars.

**Don't**
- Don't run `gcloud auth login`, `gcloud config set`, or any deploy script yourself. Print the command and stop.
- Don't invite GitHub collaborators, change repo visibility, or modify branch protection.
- Don't commit credentials, service-account keys, OAuth tokens, or `.env` files. `.gitignore` already excludes them.
- Don't bump runtime versions or dependency pins unless explicitly asked.
- Don't introduce new GCP services (Dataflow, Composer, etc.) without first proposing the change in the chat.
- Don't bypass dbt for transformations. New analytical logic goes in `dbt/models/`, not in the extractors or loader.
- Don't query the OpenF1 API outside the self-gated extractor — ad-hoc calls in other components break the rate-limit and reliability story.

---

## Known limitations (documented in README)

- OpenF1 is community-run; mid-session outages possible. Historical state recovers from Ergast.
- Fuel correction in clean-air pace is a linear approximation (~30 ms/lap/lap-remaining), not real telemetry.
- Off-season: live dashboard page replays a past GP at session-realistic speed.
