#!/usr/bin/env bash
# Create / update Cloud Scheduler jobs for the F1 pipeline.
# Idempotent: re-running creates jobs that don't exist and updates jobs that do.
# Never deletes — running this is always safe.
#
# Jobs created here:
#   ergast-daily          — calls ergast-extractor at 06:00 Europe/Madrid daily
#   dbt-daily             — runs the dbt-runner Cloud Run Job at 06:30 Europe/Madrid daily
#   (later: openf1-1min — appended in Phase 9)

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-image-lab-494712}"
REGION="${REGION:-us-central1}"
EXT_SA="f1-extractor-sa@${PROJECT_ID}.iam.gserviceaccount.com"
DBT_SA="f1-dbt-sa@${PROJECT_ID}.iam.gserviceaccount.com"

echo "==> Cloud Scheduler in ${PROJECT_ID}/${REGION}"

# Fail fast if the project predates the App Engine→Scheduler-decoupling era
# and still needs an App Engine app. Modern projects don't, so this is a no-op.
if ! gcloud scheduler jobs list --location="$REGION" --project="$PROJECT_ID" --limit=1 >/dev/null 2>&1; then
  if gcloud scheduler jobs list --location="$REGION" --project="$PROJECT_ID" 2>&1 | grep -qi "app engine"; then
    echo "ERROR: Cloud Scheduler in this project requires an App Engine app." >&2
    echo "       Run:  gcloud app create --region=us-central --project=${PROJECT_ID}" >&2
    exit 1
  fi
fi

# Helper: create-or-update an HTTP scheduler job with OIDC auth (for Cloud Run
# Functions / Services).
upsert_http_job_oidc() {
  local name="$1" schedule="$2" tz="$3" uri="$4" method="$5" sa="$6" audience="$7"

  local action="create"
  if gcloud scheduler jobs describe "$name" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
    action="update"
  fi
  echo "==> ${action}: ${name} (${schedule} ${tz})"

  gcloud scheduler jobs "$action" http "$name" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --schedule="$schedule" \
    --time-zone="$tz" \
    --uri="$uri" \
    --http-method="$method" \
    --oidc-service-account-email="$sa" \
    --oidc-token-audience="$audience" \
    --max-retry-attempts=3 \
    --min-backoff=10s \
    --max-backoff=60s
}

# Helper: create-or-update an HTTP scheduler job with OAuth auth (for the
# Cloud Run admin API — e.g. invoking a Cloud Run Job's :run endpoint).
upsert_http_job_oauth() {
  local name="$1" schedule="$2" tz="$3" uri="$4" method="$5" sa="$6"

  local action="create"
  if gcloud scheduler jobs describe "$name" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
    action="update"
  fi
  echo "==> ${action}: ${name} (${schedule} ${tz})"

  gcloud scheduler jobs "$action" http "$name" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --schedule="$schedule" \
    --time-zone="$tz" \
    --uri="$uri" \
    --http-method="$method" \
    --oauth-service-account-email="$sa" \
    --max-retry-attempts=3 \
    --min-backoff=10s \
    --max-backoff=60s
}

# --- Ergast: daily 06:00 Europe/Madrid -------------------------------------
ERGAST_URL=$(gcloud functions describe ergast-extractor \
  --gen2 --region="$REGION" --project="$PROJECT_ID" \
  --format='value(serviceConfig.uri)')

if [[ -z "$ERGAST_URL" ]]; then
  echo "ERROR: ergast-extractor not deployed yet. Run deploy/deploy_extractor_ergast.sh first." >&2
  exit 1
fi

upsert_http_job_oidc \
  "ergast-daily" \
  "0 6 * * *" \
  "Europe/Madrid" \
  "$ERGAST_URL" \
  "GET" \
  "$EXT_SA" \
  "$ERGAST_URL"

# --- dbt: daily 06:30 Europe/Madrid (30 min after ergast) ------------------
# Cloud Run Jobs use the admin API (OAuth), not the service URL (OIDC).
DBT_URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_ID}/jobs/dbt-runner:run"

if ! gcloud run jobs describe dbt-runner --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "WARN: dbt-runner Cloud Run Job not deployed yet. Run deploy/deploy_dbt_runner.sh first."
  echo "      Skipping dbt-daily scheduler entry."
else
  upsert_http_job_oauth \
    "dbt-daily" \
    "30 6 * * *" \
    "Europe/Madrid" \
    "$DBT_URI" \
    "POST" \
    "$DBT_SA"
fi

echo
echo "==> Done. Inspect with:"
echo "    gcloud scheduler jobs list --location=$REGION"
echo "==> Manually fire jobs:"
echo "    gcloud scheduler jobs run ergast-daily --location=$REGION"
echo "    gcloud scheduler jobs run dbt-daily    --location=$REGION"
