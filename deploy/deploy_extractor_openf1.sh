#!/usr/bin/env bash
# Deploy the OpenF1 micro-batch poller as a 2nd-gen Cloud Run Function.
# Idempotent: re-running updates the existing function in place.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-image-lab-494712}"
REGION="${REGION:-us-central1}"
BUCKET="${BUCKET:-image-lab-f1-lake}"
SA="f1-extractor-sa@${PROJECT_ID}.iam.gserviceaccount.com"
NAME="openf1-poller"

echo "==> Deploying ${NAME} to ${PROJECT_ID}/${REGION} (SA: ${SA})"

gcloud functions deploy "$NAME" \
  --project="$PROJECT_ID" \
  --gen2 \
  --runtime=python311 \
  --region="$REGION" \
  --source=extractors/openf1 \
  --entry-point=poll \
  --trigger-http \
  --no-allow-unauthenticated \
  --service-account="$SA" \
  --set-env-vars="GCS_BUCKET=${BUCKET}" \
  --memory=512Mi \
  --timeout=120s \
  --max-instances=1

URL=$(gcloud functions describe "$NAME" --gen2 --region="$REGION" \
        --format='value(serviceConfig.uri)')

echo
echo "==> Deployed: $URL"
echo "==> Default-mode test (should 204 outside an active F1 session window):"
echo "    gcloud functions call $NAME --gen2 --region=$REGION --data='{}'"
echo "==> Backfill smoke test (replace KEY with a real past session_key):"
echo "    curl -H \"Authorization: Bearer \$(gcloud auth print-identity-token)\" \"${URL}?session_key=KEY\""
