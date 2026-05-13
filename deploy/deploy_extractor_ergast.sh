#!/usr/bin/env bash
# Deploy the Ergast extractor as a 2nd-gen Cloud Run Function.
# Idempotent: re-running this script updates the existing function in place.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-image-lab-494712}"
REGION="${REGION:-us-central1}"
BUCKET="${BUCKET:-image-lab-f1-lake}"
SA="f1-extractor-sa@${PROJECT_ID}.iam.gserviceaccount.com"
NAME="ergast-extractor"

echo "==> Deploying ${NAME} to ${PROJECT_ID}/${REGION} (SA: ${SA})"

gcloud functions deploy "$NAME" \
  --project="$PROJECT_ID" \
  --gen2 \
  --runtime=python311 \
  --region="$REGION" \
  --source=extractors/ergast \
  --entry-point=extract \
  --trigger-http \
  --no-allow-unauthenticated \
  --service-account="$SA" \
  --set-env-vars="GCS_BUCKET=${BUCKET}" \
  --memory=512Mi \
  --timeout=540s

URL=$(gcloud functions describe "$NAME" --gen2 --region="$REGION" \
        --format='value(serviceConfig.uri)')

echo
echo "==> Deployed: $URL"
echo "==> Test invoke (current season, default endpoints):"
echo "    gcloud functions call $NAME --gen2 --region=$REGION --data='{}'"
echo "==> Or curl with an identity token:"
echo "    curl -H \"Authorization: Bearer \$(gcloud auth print-identity-token)\" \"${URL}?season=2024\""
