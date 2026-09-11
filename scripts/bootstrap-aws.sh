#!/usr/bin/env bash
set -euo pipefail

# One-time bootstrap on a new AWS account (777171524899).
# Creates S3 bucket, CloudFront distribution, and optionally upload API.
#
# Prerequisites:
#   - AWS CLI, npm, jq, python3
#   - IAM user mervin-cz-bootstrap (AdministratorAccess) for first run
#     OR mervin-cz-deploy with docs/iam/mervin-cz-deploy-policy.json
#
# Usage:
#   export AWS_ACCESS_KEY_ID='...'
#   export AWS_SECRET_ACCESS_KEY='...'
#   export UPLOAD_JWT_SECRET='...'              # optional, for upload API
#   export UPLOAD_PASSWORD_MICHAL='...'
#   export UPLOAD_PASSWORD_HORAK='...'
#   export UPLOAD_GITHUB_TOKEN='ghp_...'
#   bash scripts/bootstrap-aws.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=aws-env.defaults.sh
source "${ROOT_DIR}/scripts/aws-env.defaults.sh"

require_var() {
  if [[ -z "${!1:-}" ]]; then
    echo "Missing required environment variable: $1" >&2
    exit 1
  fi
}

require_var AWS_ACCESS_KEY_ID
require_var AWS_SECRET_ACCESS_KEY

export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_REGION

echo "==> AWS account check"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
if [[ "$ACCOUNT_ID" != "$AWS_ACCOUNT_ID" ]]; then
  echo "Warning: expected account ${AWS_ACCOUNT_ID}, got ${ACCOUNT_ID}" >&2
fi

echo
echo "==> Step 1/2: Deploy static site (S3 + CloudFront)"
bash scripts/deploy-aws.sh

CLOUDFRONT_URL=""
if [[ -f "${ROOT_DIR}/.aws-deploy/cloudfront.json" ]]; then
  CLOUDFRONT_URL="$(node -e "const fs=require('fs'); try { const d=JSON.parse(fs.readFileSync('.aws-deploy/cloudfront.json','utf8')); process.stdout.write(d.domainName ? 'https://'+d.domainName+'/' : ''); } catch {}" 2>/dev/null || true)"
fi

UPLOAD_READY=true
for var in UPLOAD_JWT_SECRET UPLOAD_PASSWORD_MICHAL UPLOAD_PASSWORD_HORAK UPLOAD_GITHUB_TOKEN; do
  if [[ -z "${!var:-}" ]]; then
    UPLOAD_READY=false
  fi
done

if [[ "$UPLOAD_READY" == "true" ]]; then
  echo
  echo "==> Step 2/2: Deploy upload API (Lambda + API Gateway)"
  if [[ -n "$CLOUDFRONT_URL" ]]; then
    export UPLOAD_ALLOWED_ORIGINS="https://www.mervin-cz.com,https://mervin-cz.com,${CLOUDFRONT_URL%/},http://localhost:4321"
  fi
  bash scripts/deploy-upload-api.sh
else
  echo
  echo "==> Step 2/2 skipped (upload secrets not set)"
  echo "Set UPLOAD_JWT_SECRET, UPLOAD_PASSWORD_MICHAL, UPLOAD_PASSWORD_HORAK, UPLOAD_GITHUB_TOKEN"
  echo "and rerun: bash scripts/deploy-upload-api.sh"
fi

cat <<EOF

Bootstrap finished.

Resources:
  S3 bucket:      s3://${S3_BUCKET}
  CloudFront URL: ${CLOUDFRONT_URL:-see .aws-deploy/cloudfront.json}
  Upload API URL: see src/data/upload-api.json (if deployed)

GitHub → Settings → Secrets and variables → Actions

Secrets:
  AWS_ACCESS_KEY_ID        (from IAM user mervin-cz-deploy)
  AWS_SECRET_ACCESS_KEY    (from IAM user mervin-cz-deploy)
  UPLOAD_PASSWORD_MICHAL
  UPLOAD_PASSWORD_HORAK
  UPLOAD_JWT_SECRET
  UPLOAD_GITHUB_TOKEN

Variables:
  S3_BUCKET                = ${S3_BUCKET}
  UPLOAD_S3_BUCKET         = ${UPLOAD_S3_BUCKET}
  PUBLIC_UPLOAD_API_URL    = (URL from deploy-upload-api.sh)
  AWS_REGION               = ${AWS_REGION}

After GitHub secrets are set, push to main or run workflow "Deploy to AWS".

Deactivate IAM user mervin-cz-bootstrap when done.

EOF
