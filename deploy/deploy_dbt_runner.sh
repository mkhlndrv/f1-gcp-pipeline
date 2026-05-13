#!/usr/bin/env bash
# Build the dbt-runner image, push to Artifact Registry, deploy as a Cloud Run Job.
# Idempotent: re-runs update the image and the job in place.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-image-lab-494712}"
REGION="${REGION:-us-central1}"
REPO="${REPO:-f1}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/dbt-runner:latest"
DBT_SA="f1-dbt-sa@${PROJECT_ID}.iam.gserviceaccount.com"

echo "==> AR repo: ${REGION}/${REPO}  Image: ${IMAGE}  SA: ${DBT_SA}"

# 1) Artifact Registry repo (idempotent)
if ! gcloud artifacts repositories describe "$REPO" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "==> creating Artifact Registry repo $REPO"
  gcloud artifacts repositories create "$REPO" \
    --repository-format=docker --location="$REGION" --project="$PROJECT_ID"
else
  echo "==> AR repo $REPO already exists"
fi

# 2) Build + push via Cloud Build
echo "==> submitting build (may take ~3 min on first run)"
gcloud builds submit \
  --project="$PROJECT_ID" \
  --config=dbt_runner/cloudbuild.yaml \
  --substitutions="_IMAGE=${IMAGE}" \
  .

# 3) Cloud Run Job (create-or-update)
action="create"
if gcloud run jobs describe dbt-runner --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  action="update"
fi
echo "==> ${action} Cloud Run Job dbt-runner"
gcloud run jobs "$action" dbt-runner \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --image="$IMAGE" \
  --service-account="$DBT_SA" \
  --max-retries=1 \
  --task-timeout=1800 \
  --cpu=1 \
  --memory=1Gi

echo
echo "==> Deployed. Smoke test:"
echo "    gcloud run jobs execute dbt-runner --region=$REGION --wait"
