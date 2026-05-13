#!/usr/bin/env bash
# Deploy the GCS → BigQuery loader as a 2nd-gen Cloud Run Function with an
# Eventarc finalize trigger on the lake bucket.
# Idempotent: re-running updates the existing function/trigger in place.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-image-lab-494712}"
REGION="${REGION:-us-central1}"
BUCKET="${BUCKET:-image-lab-f1-lake}"
RAW_DATASET="${RAW_DATASET:-f1_raw}"
SA="f1-loader-sa@${PROJECT_ID}.iam.gserviceaccount.com"
NAME="gcs-to-bq-loader"

echo "==> Deploying ${NAME} to ${PROJECT_ID}/${REGION} (SA: ${SA}, bucket: ${BUCKET})"

gcloud functions deploy "$NAME" \
  --project="$PROJECT_ID" \
  --gen2 \
  --runtime=python311 \
  --region="$REGION" \
  --source=loaders/gcs_to_bq \
  --entry-point=load \
  --trigger-event-filters="type=google.cloud.storage.object.v1.finalized" \
  --trigger-event-filters="bucket=${BUCKET}" \
  --service-account="$SA" \
  --trigger-service-account="$SA" \
  --set-env-vars="PROJECT_ID=${PROJECT_ID},RAW_DATASET=${RAW_DATASET}" \
  --memory=512Mi \
  --timeout=540s \
  --retry

echo
echo "==> Deployed. First trigger after deploy has ~1-2 min of Pub/Sub propagation lag."
echo "==> Smoke test (re-invoke the extractor to land new files):"
echo "    gcloud functions call ergast-extractor --gen2 --region=$REGION --data='{}'"
echo "==> Tail logs:"
echo "    gcloud functions logs read $NAME --gen2 --region=$REGION --limit=20"
echo "==> Then check BQ:"
echo "    bq ls $RAW_DATASET"
echo "    bq query --use_legacy_sql=false 'SELECT COUNT(*) FROM \`${PROJECT_ID}.${RAW_DATASET}.ergast_results\`'"
