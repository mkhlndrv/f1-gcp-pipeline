# CLAUDE.md

Guidance for AI coding agents (Claude Code, Cursor, etc.) working in this repo.
Humans can read it too — it's also a quick orientation doc.

---

## Project summary

End-to-end F1 race-weekend analytics pipeline on GCP.

- **Sources:** Jolpica/Ergast (daily batch) + OpenF1 (1-minute micro-batch poller, self-gated outside session windows).
- **Pipeline type:** Hybrid — daily batch for canonical results, 1-minute micro-batch for live telemetry.
- **Flow:** Cloud Scheduler → Cloud Run Functions (extractors) → GCS lake → Cloud Run Function (loader) → BigQuery `f1_raw` → dbt (Cloud Run Job) → `f1_staging` → `f1_marts` → Looker Studio.
- **Tier 1 headline (live):** championship leader from `f1_marts.vw_dashboard_overview`, surfaced in the Looker Studio dashboard.
- **Tier 3 stretch headline (planned):** `fct_clean_air_pace` — fuel- and traffic-corrected per-driver per-compound lap time vs. field median.

---

## Current state

| Tier | Phases | Status | Notes |
|---|---|---|---|
| **Tier 1 — must-ship (rubric-complete)** | 0–8 | ✅ shipped | Ergast extractor, GCS→BQ loader, dbt warehouse + dashboard view, dbt-runner Cloud Run Job, daily schedules, Looker Studio dashboard, CI |
| **Tier 2 — strong submission** | 9 (✅ shipped), 10–12 (pending) | 🟡 in progress | Phase 9 = OpenF1 poller. Pending: `fct_lap` + simple pace metric (10), monitoring + dbt source freshness (11), race deep-dive page (12) |
| **Tier 3 — polish** | 13–14 | ⏸ stretch | Full clean-air pace heuristic, live race page, off-season replay job |

PLAN.md has the per-phase build plan; git history has the implementation order; this file is the conventions contract.

---

## Repo layout

```
f1-pipeline/
├── extractors/
│   ├── ergast/           # daily batch extractor (HTTP-triggered)
│   └── openf1/           # 1-min poller, self-gates outside active sessions; stateless
├── loaders/
│   └── gcs_to_bq/        # GCS finalize → BigQuery load (Eventarc-triggered)
│       └── schemas/      # explicit JSON schemas per (source, endpoint), snapshotted post-first-load
├── dbt/
│   ├── models/staging/   # views; one per source endpoint
│   ├── models/marts/     # tables (dim_* + fct_*) + vw_dashboard_overview view
│   └── macros/
│       └── generate_schema_name.sql  # so +schema: marts → literal `f1_marts`
├── dbt_runner/           # container image + Dockerfile + cloudbuild.yaml for the daily Cloud Run Job
├── infra/alerts/         # Cloud Monitoring alert policies (Tier 2)
├── deploy/               # idempotent gcloud deploy scripts for each component
├── .github/
│   ├── workflows/ci.yml  # ruff + `dbt parse` (static; no BQ connection)
│   └── dbt-ci/           # CI-only profiles.yml so `dbt parse` can resolve the profile
├── docs/                 # dashboard screenshot etc.
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
- **Cloud Run runtime:** Python 3.11, `functions-framework` for Cloud Run Functions.
- **Local dev:** Python 3.12 — required by dbt-bigquery 1.11. Python 3.14 (Homebrew default) does NOT work with dbt; use `python3.12 -m venv ...`.
- All config via env vars; no hardcoded project/bucket/dataset names.
- Logging via `logging` module, INFO level, structured (`json.dumps`) to stdout (Cloud Logging picks it up).
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
- `f1_raw.*` — append-only, **unpartitioned + unclustered** (autodetect on first load; explicit JSON schema in `loaders/gcs_to_bq/schemas/<source>_<endpoint>.json` thereafter). Partitioning + clustering is a Tier 3+ refinement; current data volume doesn't justify it.
- `f1_staging.*` — views only.
- `f1_marts.*` — Tier 1: `materialized='table'` (small dims + small facts). Reserve `materialized='incremental'` for `fct_lap` (Phase 10) where lap-grain volume actually justifies it.
- Schema autodetect on initial load is fine; once a schema file is committed under `loaders/gcs_to_bq/schemas/`, the loader uses it (not autodetect).
- `ignore_unknown_values=True` on every load — schema drift never breaks the loader; new fields appear in BQ only when their schema file is updated (intentional, explicit).

### dbt
- One model = one file. File name == table/view name.
- `materialized='view'` for staging; `materialized='table'` for small dims/facts at current scale; `materialized='incremental'` only when a fact's volume actually warrants it (`fct_lap`, Phase 10).
- Every model has an entry in the relevant `schema.yml` with at least: description, columns, and `unique`+`not_null` tests on natural keys. Relationship tests use the dbt 1.10+ `arguments:` nesting.
- Use `{{ ref(...) }}` for models; `{{ source(...) }}` for raw tables. Never reference `f1_raw.*` by literal name.
- The custom `generate_schema_name` macro means `+schema: marts` writes to literal `f1_marts` (not `<target>_marts`). Don't override unless you understand it.
- Macros go in `dbt/macros/`. Don't introduce a new macro for something used in only one model.
- `dbt-bigquery==1.11.*`, locked in `dbt_runner/Dockerfile` and the example profile.

---

## Operational gotchas (learned the hard way — don't re-trip)

- **`bq update --source <file>` (not `bq add-iam-policy-binding`).** The latter silently no-ops on some bq versions; the former is the reliable shape used in `deploy/setup_gcp.sh`. Don't "simplify" back.
- **`gcloud projects add-iam-policy-binding` without `--condition=None`.** Older suggestions to pass `--condition=None` fail on newer gcloud. Plain form works everywhere.
- **OpenF1 `segments_sector_*` fields are dropped in the extractor.** They're REPEATED INTEGER arrays whose elements (and the array itself) can be `null`, which BQ rejects on load. If a future OpenF1 endpoint shows the same pattern, drop or sanitize the same way (see `extractors/openf1/main.py::_sanitize`).
- **OpenF1 poller is stateless** (re-fetches the full session every minute; dbt staging dedupes). Chosen because `f1-extractor-sa` only has `objectCreator` on the bucket — it can't `list` to find an HWM file. Don't add HWM unless you grant the SA `objectViewer` and accept that trade-off.
- **OpenF1 active-session filter:** `date_start <= now AND (date_end IS NULL OR date_end >= now)`. Filtering only by `date_end` picks up future sessions and 404s on `/laps`.
- **OpenF1 `--max-instances=1`** at deploy time so concurrent invocations can't race. Stateless mode is forgiving but the single-writer guarantee is cheap.
- **Scheduler auth split.** Cloud Run Functions / Services use **OIDC** (`--oidc-service-account-email`); the Cloud Run Jobs admin API (`:run`) uses **OAuth** (`--oauth-service-account-email`). `deploy/create_schedulers.sh` has two helpers — pick the right one for the target.
- **Resource-scoped `run.invoker`.** The scheduler SAs get `roles/run.invoker` bound to the *specific* function/job they invoke, not project-wide. Pattern: `gcloud run services add-iam-policy-binding <name> --region=...` (and `gcloud run jobs add-iam-policy-binding` for jobs).
- **Eventarc finalize trigger needs `roles/pubsub.publisher` on the GCS service agent.** `setup_gcp.sh` grants it; if a future region/project move breaks the loader trigger, this is the first thing to check.
- **Loader returns 200 on quarantine.** A poisoned file lands in `raw_quarantine/`, the function logs `severity=ERROR`, and Eventarc does NOT retry. Monitoring (Phase 11) will alert on the ERROR log.
- **Cloud Build context = repo root.** `dbt_runner/cloudbuild.yaml` builds with the project root as context so the Dockerfile can `COPY dbt/`. Don't `cd dbt_runner && gcloud builds submit .` — the build will fail.
- **Loader uses `@functions_framework.cloud_event`.** Without the decorator, the framework calls with the legacy `(data, context)` signature and the function 500s. Same applies if a new event-driven function is added.

---

## Local dev workflow

1. `gcloud auth application-default login` once.
2. Install component deps: `pip install -r extractors/ergast/requirements.txt` (etc.).
3. Run an extractor locally with `functions-framework --target=<entry_point>`.
4. dbt: `cd dbt && dbt deps && dbt build --select <model>`.

CI (`.github/workflows/ci.yml`) runs ruff + `dbt parse` (static SQL validation; no BQ connection) on every PR to `main`. Full `dbt build` in CI would need workload-identity federation; out of scope.

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

- 2026 data is sparse (4 rounds in by mid-May 2026). The dashboard refreshes daily; populates as the season runs.
- OpenF1 is community-run; mid-session outages are possible. Ergast recovers canonical history afterward.
- **Planned, not yet built:** the clean-air-pace metric (Tier 3) — fuel correction would be a linear ~30 ms/lap/lap-remaining approximation, not real telemetry; clean-air filter would be `gap_ahead > 1.5s AND not in/out lap AND no SC/VSC`.
- **Planned, not yet built:** live race page (Tier 3) — would lag ~2 minutes behind reality due to 1-min polling + Looker refresh.
- **Planned, not yet built:** off-season replay job (Tier 3) — would re-publish a stored historical race into a `_replay` dataset for demo purposes.

---

## Maintaining this file

CLAUDE.md is a **conventions contract**, not a changelog. Phase progress lives in `PLAN.md` and git history; project status lives in the README's tier table; this file answers "what are the rules of this codebase?"

**Update CLAUDE.md when any of these happens:**

1. A new top-level component or directory is added (touches **Repo layout**).
2. A convention changes — Python version, file-naming, dbt materialization choice, NDJSON shape, etc. (touches **Conventions**).
3. An IAM role / service account / project-level binding is added or modified (touches **GCP constants** or **Operational gotchas**).
4. A new BigQuery dataset, table, or schema-file is introduced (touches **BigQuery** or **Repo layout**).
5. An operational gotcha emerges — a deploy that needed manual fix, a non-obvious workaround, an API quirk (touches **Operational gotchas**).

**Do NOT update CLAUDE.md for:**
- Routine commits, bugfixes, or per-phase progress (use PLAN.md / git).
- New features that don't change a convention or contract.
- Documentation that belongs in the component-level README.

Each future phase plan in `~/.claude/plans/` includes a "Step N — Update CLAUDE.md if needed" entry that explicitly says either "no change" or lists the diff to apply. If a phase ships without that step, it's a regression — surface it.
