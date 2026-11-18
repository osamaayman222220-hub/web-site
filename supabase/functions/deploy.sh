#!/usr/bin/env bash
# ============================================================
# CareNest - Deploy Edge Functions to Supabase
# Project Ref: tfolrgauojmbeofartaq
# ============================================================

set -e

PROJECT_REF="tfolrgauojmbeofartaq"

echo "=========================================================="
echo "Starting Edge Functions Deployment for CareNest ($PROJECT_REF)"
echo "=========================================================="

FUNCTIONS=(
  "save-national-id"
  "get-national-id"
  "verify-visit-code"
  "excel-sync"
  "export-carenest-data"
)

for fn in "${FUNCTIONS[@]}"; do
  echo "🚀 Deploying function: $fn..."
  supabase functions deploy "$fn" --project-ref "$PROJECT_REF" --no-verify-jwt
  echo "✅ Deployed: $fn successfully."
  echo "----------------------------------------------------------"
done

echo "🎉 All Edge Functions deployed successfully!"

