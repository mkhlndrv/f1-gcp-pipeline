#!/usr/bin/env bash
# Phase 0: one-time GCP setup for the F1 pipeline.
# Idempotent: every step is guarded so re-runs are safe.
# Run by Misha from his laptop. Does NOT need to run in Cloud Shell.
#
# Prereqs:
#   - gcloud, bq, gsutil installed
#   - billing enabled on the project (check console first)
#   - Misha has Owner or Project IAM Admin

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-image-lab-494712}"
REGION="${REGION:-us-central1}"
BUCKET="${BUCKET:-image-lab-f1-lake}"
BQ_LOCATION="${BQ_LOCATION:-US}"

echo "==> Project: $PROJECT_ID  Region: $REGION  Bucket: $BUCKET"

# --- 0.1 Defaults ----------------------------------------------------------
gcloud config set project "$PROJECT_ID" >/dev/null
gcloud config set run/region "$REGION" >/dev/null
gcloud config set functions/region "$REGION" >/dev/null

# --- 0.2 Enable APIs -------------------------------------------------------
echo "==> Enabling APIs (this can take ~1 min)"
gcloud services enable \
  cloudfunctions.googleapis.com \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  cloudscheduler.googleapis.com \
  bigquery.googleapis.com \
  storage.googleapis.com \
  eventarc.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  iam.googleapis.com \
  artifactregistry.googleapis.com \
  pubsub.googleapis.com

# --- 0.3 Lake bucket -------------------------------------------------------
if gsutil ls -b "gs://$BUCKET" >/dev/null 2>&1; then
  echo "==> Bucket gs://$BUCKET already exists; skipping create"
else
  echo "==> Creating gs://$BUCKET"
  gsutil mb -l "$REGION" -b on "gs://$BUCKET"
fi

echo "==> Applying lifecycle policy (30-day delete on raw_quarantine/)"
LIFECYCLE_TMP=$(mktemp)
cat > "$LIFECYCLE_TMP" <<'EOF'
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 30, "matchesPrefix": ["raw_quarantine/"]}
    }
  ]
}
EOF
gsutil lifecycle set "$LIFECYCLE_TMP" "gs://$BUCKET"
rm -f "$LIFECYCLE_TMP"

# --- 0.4 BigQuery datasets -------------------------------------------------
for ds in f1_raw f1_staging f1_marts; do
  if bq --location="$BQ_LOCATION" ls -d --format=prettyjson | grep -q "\"datasetId\": \"$ds\""; then
    echo "==> Dataset $ds already exists; skipping"
  else
    echo "==> Creating dataset $ds"
    bq --location="$BQ_LOCATION" mk -d "$ds"
  fi
done

# --- 0.5 Service accounts --------------------------------------------------
for sa in f1-extractor-sa f1-loader-sa f1-dbt-sa; do
  if gcloud iam service-accounts list --format='value(email)' | grep -q "^${sa}@${PROJECT_ID}.iam.gserviceaccount.com$"; then
    echo "==> SA $sa already exists; skipping"
  else
    echo "==> Creating SA $sa"
    gcloud iam service-accounts create "$sa" --display-name="$sa"
  fi
done

EXT_SA="f1-extractor-sa@${PROJECT_ID}.iam.gserviceaccount.com"
LDR_SA="f1-loader-sa@${PROJECT_ID}.iam.gserviceaccount.com"
DBT_SA="f1-dbt-sa@${PROJECT_ID}.iam.gserviceaccount.com"

# --- 0.6 IAM bindings ------------------------------------------------------
echo "==> Granting bucket-level roles"
gsutil iam ch "serviceAccount:${EXT_SA}:objectCreator" "gs://$BUCKET"
gsutil iam ch "serviceAccount:${LDR_SA}:objectAdmin"   "gs://$BUCKET"

echo "==> Granting BigQuery dataset roles"
# Loader: write to f1_raw
bq add-iam-policy-binding --member="serviceAccount:${LDR_SA}" --role=roles/bigquery.dataEditor f1_raw >/dev/null
# dbt: read raw, write staging+marts
bq add-iam-policy-binding --member="serviceAccount:${DBT_SA}" --role=roles/bigquery.dataViewer f1_raw     >/dev/null
bq add-iam-policy-binding --member="serviceAccount:${DBT_SA}" --role=roles/bigquery.dataEditor f1_staging >/dev/null
bq add-iam-policy-binding --member="serviceAccount:${DBT_SA}" --role=roles/bigquery.dataEditor f1_marts   >/dev/null

echo "==> Granting project-level roles (job runner, eventarc, run invoker)"
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:${LDR_SA}" --role=roles/bigquery.jobUser     --condition=None >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:${DBT_SA}" --role=roles/bigquery.jobUser     --condition=None >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:${LDR_SA}" --role=roles/eventarc.eventReceiver --condition=None >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:${LDR_SA}" --role=roles/run.invoker            --condition=None >/dev/null

echo "==> Granting GCS service agent pubsub.publisher (required for Eventarc finalize triggers)"
GCS_SA=$(gsutil kms serviceaccount -p "$PROJECT_ID")
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:${GCS_SA}" --role=roles/pubsub.publisher --condition=None >/dev/null

# --- 0.8 Sanity check ------------------------------------------------------
echo
echo "==> Done. Sanity check:"
echo "    Datasets:" $(bq ls --format=prettyjson | grep -c datasetId) "(expect 3)"
echo "    Bucket:  " $(gsutil ls | grep -c "$BUCKET") "(expect 1)"
echo "    SAs:     " $(gcloud iam service-accounts list --format='value(email)' | grep -c "^f1-") "(expect 3)"
echo
echo "Now run once:  gcloud auth application-default login"
