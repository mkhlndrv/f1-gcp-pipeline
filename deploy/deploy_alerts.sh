#!/usr/bin/env bash
# Idempotent: creates or updates the f1-cloud-run-errors alert policy.
# Re-running is always safe.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-image-lab-494712}"
POLICY_FILE="${POLICY_FILE:-infra/alerts/function_errors.yaml}"
DISPLAY_NAME="f1-cloud-run-errors"

if [[ ! -f "$POLICY_FILE" ]]; then
  echo "ERROR: policy file not found: $POLICY_FILE" >&2
  exit 1
fi

echo "==> Looking up existing policy named '$DISPLAY_NAME'"
EXISTING=$(gcloud beta monitoring policies list \
  --filter="displayName=\"$DISPLAY_NAME\"" \
  --format='value(name)' \
  --project="$PROJECT_ID" 2>/dev/null | head -1)

if [[ -n "$EXISTING" ]]; then
  echo "==> Updating existing policy: $EXISTING"
  gcloud beta monitoring policies update "$EXISTING" \
    --policy-from-file="$POLICY_FILE" \
    --project="$PROJECT_ID"
else
  echo "==> Creating new policy"
  gcloud beta monitoring policies create \
    --policy-from-file="$POLICY_FILE" \
    --project="$PROJECT_ID"
fi

echo
echo "==> Done. Inspect with:"
echo "    gcloud beta monitoring policies list \\"
echo "      --filter='displayName=\"$DISPLAY_NAME\"' --project=$PROJECT_ID"
