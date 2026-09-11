#!/usr/bin/env bash
set -euo pipefail

# Build the site and publish to S3 + CloudFront invalidation.
# Intended for GitHub Actions with mervin-cz-deploy credentials.
#
# Required environment variables:
#   AWS_ACCESS_KEY_ID (or AWS_DEPLOY_ACCESS_KEY_ID)
#   AWS_SECRET_ACCESS_KEY (or AWS_DEPLOY_SECRET_ACCESS_KEY)
#
# Optional:
#   AWS_REGION, S3_BUCKET, CLOUDFRONT_DISTRIBUTION_ID, PUBLIC_UPLOAD_API_URL

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export PATH="${HOME}/.local/bin:${PATH}"
# shellcheck source=aws-env.defaults.sh
source "${ROOT_DIR}/scripts/aws-env.defaults.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd aws
require_cmd npm
require_cmd jq

export AWS_ACCESS_KEY_ID="${AWS_DEPLOY_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
export AWS_SECRET_ACCESS_KEY="${AWS_DEPLOY_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"

if [[ -z "${AWS_ACCESS_KEY_ID}" || -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
  echo "AWS deploy credentials are not configured." >&2
  echo "Set AWS_DEPLOY_ACCESS_KEY_ID and AWS_DEPLOY_SECRET_ACCESS_KEY (mervin-cz-deploy)." >&2
  exit 1
fi

export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_REGION

echo "==> Building site"
export PUBLIC_UPLOAD_API_URL="${PUBLIC_UPLOAD_API_URL:-}"
if [[ -n "$PUBLIC_UPLOAD_API_URL" ]]; then
  echo "Upload API URL: ${PUBLIC_UPLOAD_API_URL}"
else
  echo "Upload API URL: using src/data/upload-api.json fallback"
fi
npm run build

echo "==> AWS identity"
aws sts get-caller-identity

INFRA_FILE="${ROOT_DIR}/src/data/aws-infra.json"
DISTRIBUTION_ID="${CLOUDFRONT_DISTRIBUTION_ID:-}"
if [[ -z "$DISTRIBUTION_ID" && -f "$INFRA_FILE" ]]; then
  DISTRIBUTION_ID="$(jq -r '.distributionId // empty' "$INFRA_FILE")"
fi
if [[ -z "$DISTRIBUTION_ID" ]]; then
  DISTRIBUTION_ID="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Comment=='${CLOUDFRONT_COMMENT}'] | sort_by(@, &Id)[].Id" \
    --output text 2>/dev/null | awk '{print $1}' | sed '/^None$/d')"
fi

if [[ -z "$DISTRIBUTION_ID" ]]; then
  echo "CloudFront distribution not found. Run Bootstrap AWS workflow first." >&2
  exit 1
fi

echo "==> Uploading assets to s3://${S3_BUCKET}"
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

echo "==> Creating CloudFront invalidation"
INVALIDATION_ID="$(aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*" \
  --query 'Invalidation.Id' \
  --output text)"

DOMAIN_NAME="$(aws cloudfront get-distribution --id "$DISTRIBUTION_ID" --query 'Distribution.DomainName' --output text)"

cat <<EOF

Deployment complete.

S3 bucket:      s3://${S3_BUCKET}
CloudFront ID:  ${DISTRIBUTION_ID}
CloudFront URL: https://${DOMAIN_NAME}/
Invalidation:   ${INVALIDATION_ID}
EOF
