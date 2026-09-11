#!/usr/bin/env bash
set -euo pipefail

# One-time full AWS setup on account 777171524899 via mervin-cz-bootstrap.
# Run from GitHub Actions workflow "Bootstrap AWS" — no local PC required.
#
# Creates: IAM deploy user, ACM cert (optional), S3, CloudFront, Lambda, API Gateway.
#
# Required GitHub Secrets:
#   AWS_BOOTSTRAP_ACCESS_KEY_ID / AWS_BOOTSTRAP_SECRET_ACCESS_KEY (AdministratorAccess)
#   UPLOAD_JWT_SECRET, UPLOAD_PASSWORD_MICHAL, UPLOAD_PASSWORD_HORAK, UPLOAD_GITHUB_TOKEN

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export PATH="${HOME}/.local/bin:${PATH}"
# shellcheck source=aws-env.defaults.sh
source "${ROOT_DIR}/scripts/aws-env.defaults.sh"

require_var() {
  if [[ -z "${!1:-}" ]]; then
    echo "Missing required environment variable: $1" >&2
    exit 1
  fi
}

require_var AWS_BOOTSTRAP_ACCESS_KEY_ID
require_var AWS_BOOTSTRAP_SECRET_ACCESS_KEY

export AWS_ACCESS_KEY_ID="${AWS_BOOTSTRAP_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${AWS_BOOTSTRAP_SECRET_ACCESS_KEY}"

export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_REGION

echo "==> Bootstrap identity (expect mervin-cz-bootstrap / admin)"
aws sts get-caller-identity

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
if [[ "$ACCOUNT_ID" != "$AWS_ACCOUNT_ID" ]]; then
  echo "Error: expected AWS account ${AWS_ACCOUNT_ID}, got ${ACCOUNT_ID}" >&2
  exit 1
fi

echo
echo "==> Step 1/6: IAM user mervin-cz-deploy"
bash "${ROOT_DIR}/scripts/ensure-deploy-iam.sh"

echo
echo "==> Step 2/6: ACM certificate (if CLOUDFRONT_ALIASES set)"
bash "${ROOT_DIR}/scripts/setup-acm-certificate.sh"
if [[ -f "${ROOT_DIR}/.aws-deploy/acm-certificate-arn" ]]; then
  export ACM_CERTIFICATE_ARN="$(cat "${ROOT_DIR}/.aws-deploy/acm-certificate-arn")"
fi

echo
echo "==> Step 3/6: S3 bucket + CloudFront"
bash "${ROOT_DIR}/scripts/setup-aws-infra.sh"

CLOUDFRONT_URL=""
if [[ -f "${ROOT_DIR}/src/data/aws-infra.json" ]]; then
  CLOUDFRONT_URL="$(jq -r 'if .domainName then "https://" + .domainName + "/" else "" end' "${ROOT_DIR}/src/data/aws-infra.json")"
fi

echo
echo "==> Step 4/6: Build and upload site (bootstrap credentials)"
export PUBLIC_UPLOAD_API_URL="${PUBLIC_UPLOAD_API_URL:-}"
npm run build

echo "==> Uploading to s3://${S3_BUCKET}"
aws s3 sync dist/ "s3://${S3_BUCKET}/" \
  --delete \
  --only-show-errors \
  --exclude "index.html" \
  --exclude "**/index.html" \
  --cache-control "public, max-age=31536000, immutable"

aws s3 sync dist/ "s3://${S3_BUCKET}/" \
  --only-show-errors \
  --exclude "*" \
  --include "index.html" \
  --include "**/index.html" \
  --cache-control "public, max-age=300, must-revalidate"

DISTRIBUTION_ID="$(jq -r '.distributionId' "${ROOT_DIR}/src/data/aws-infra.json")"
INVALIDATION_ID="$(aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*" \
  --query 'Invalidation.Id' \
  --output text)"
echo "Invalidation: ${INVALIDATION_ID}"

UPLOAD_READY=true
for var in UPLOAD_JWT_SECRET UPLOAD_PASSWORD_MICHAL UPLOAD_PASSWORD_HORAK UPLOAD_GITHUB_TOKEN; do
  if [[ -z "${!var:-}" ]]; then
    UPLOAD_READY=false
  fi
done

if [[ "$UPLOAD_READY" == "true" ]]; then
  echo
  echo "==> Step 5/6: Upload API (Lambda + API Gateway)"
  if [[ -n "$CLOUDFRONT_URL" ]]; then
    export UPLOAD_ALLOWED_ORIGINS="https://www.mervin-cz.com,https://mervin-cz.com,${CLOUDFRONT_URL%/},http://localhost:4321"
  fi
  bash "${ROOT_DIR}/scripts/deploy-upload-api.sh"
else
  echo
  echo "==> Step 5/6 skipped (upload secrets not set)"
fi

echo
echo "==> Step 6/6: Summary"

UPLOAD_API_URL=""
if [[ -f "${ROOT_DIR}/src/data/upload-api.json" ]]; then
  UPLOAD_API_URL="$(jq -r '.apiUrl // empty' "${ROOT_DIR}/src/data/upload-api.json")"
fi

cat <<EOF

Bootstrap finished on account ${AWS_ACCOUNT_ID}.

Resources:
  S3 bucket:       s3://${S3_BUCKET}
  CloudFront URL:  ${CLOUDFRONT_URL:-see src/data/aws-infra.json}
  Upload API URL:  ${UPLOAD_API_URL:-not deployed}

Committed config files (after workflow push):
  src/data/aws-infra.json
  src/data/upload-api.json (if upload API deployed)

GitHub Secrets — set these for ongoing deploys (mervin-cz-deploy):
  AWS_DEPLOY_ACCESS_KEY_ID
  AWS_DEPLOY_SECRET_ACCESS_KEY
  UPLOAD_PASSWORD_MICHAL
  UPLOAD_PASSWORD_HORAK
  UPLOAD_JWT_SECRET
  UPLOAD_GITHUB_TOKEN

GitHub Variables:
  S3_BUCKET=${S3_BUCKET}
  UPLOAD_S3_BUCKET=${UPLOAD_S3_BUCKET}
  AWS_REGION=${AWS_REGION}
  PUBLIC_UPLOAD_API_URL=${UPLOAD_API_URL}
  CLOUDFRONT_DISTRIBUTION_ID=${DISTRIBUTION_ID}
  ACM_CERTIFICATE_ARN=${ACM_CERTIFICATE_ARN:-}
  CLOUDFRONT_ALIASES=${CLOUDFRONT_ALIASES:-}

Ongoing updates: push to main or run workflow "Deploy to AWS".

Deactivate access keys for mervin-cz-bootstrap when deploy secrets are configured.

EOF
