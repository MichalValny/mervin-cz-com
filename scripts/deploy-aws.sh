#!/usr/bin/env bash
set -euo pipefail

# Deploy static Astro build to S3 and ensure a CloudFront distribution exists.
#
# Required environment variables:
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#
# Optional:
#   AWS_REGION (default: us-east-1)
#   S3_BUCKET (default: mervin-cz-com)
#   CLOUDFRONT_COMMENT (default: mervin-cz-com static site)
#   ACM_CERTIFICATE_ARN (for custom domain aliases, must be in us-east-1)
#   CLOUDFRONT_ALIASES (comma-separated, e.g. www.mervin-cz.com,mervin-cz.com)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export PATH="${HOME}/.local/bin:${PATH}"

: "${AWS_REGION:=us-east-1}"
: "${S3_BUCKET:=mervin-cz-com}"
: "${CLOUDFRONT_COMMENT:=mervin-cz-com static site}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd aws
require_cmd npm
require_cmd jq

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "AWS credentials are not configured." >&2
  echo "Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, then rerun." >&2
  exit 1
fi

export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_REGION

echo "==> Building site"
npm run build

echo "==> Ensuring S3 bucket s3://${S3_BUCKET} exists in ${AWS_REGION}"
if ! aws s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null; then
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$S3_BUCKET"
  else
    aws s3api create-bucket \
      --bucket "$S3_BUCKET" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
  fi
fi

aws s3api put-public-access-block \
  --bucket "$S3_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "==> Syncing assets to S3"
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

echo "==> Ensuring CloudFront distribution"
STATE_DIR="${ROOT_DIR}/.aws-deploy"
mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/cloudfront.json"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ORIGIN_ID="S3-${S3_BUCKET}"
OAC_NAME="mervin-cz-com-oac"

find_distribution_id() {
  if [[ -f "$STATE_FILE" ]]; then
    jq -r '.distributionId // empty' "$STATE_FILE"
    return
  fi

  aws cloudfront list-distributions \
    --query "DistributionList.Items[?Comment=='${CLOUDFRONT_COMMENT}'].Id | [0]" \
    --output text 2>/dev/null | sed '/^None$/d'
}

ensure_oac() {
  local oac_id
  oac_id="$(aws cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id | [0]" \
    --output text 2>/dev/null | sed '/^None$/d')"

  if [[ -z "$oac_id" ]]; then
    oac_id="$(aws cloudfront create-origin-access-control \
      --origin-access-control-config "{
        \"Name\": \"${OAC_NAME}\",
        \"Description\": \"OAC for ${S3_BUCKET}\",
        \"SigningProtocol\": \"sigv4\",
        \"SigningBehavior\": \"always\",
        \"OriginAccessControlOriginType\": \"s3\"
      }" \
      --query 'OriginAccessControl.Id' \
      --output text)"
  fi

  echo "$oac_id"
}

apply_bucket_policy() {
  local distribution_id="$1"
  local policy
  policy="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontServicePrincipalReadOnly",
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudfront.amazonaws.com"
      },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${S3_BUCKET}/*",
      "Condition": {
        "StringEquals": {
          "AWS:SourceArn": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${distribution_id}"
        }
      }
    }
  ]
}
EOF
)"
  aws s3api put-bucket-policy --bucket "$S3_BUCKET" --policy "$policy"
}

create_distribution() {
  local oac_id="$1"
  local aliases_json="[]"
  if [[ -n "${CLOUDFRONT_ALIASES:-}" ]]; then
    aliases_json="$(printf '%s' "$CLOUDFRONT_ALIASES" | awk -F, '{printf "["; for (i=1; i<=NF; i++) {gsub(/^ +| +$/, "", $i); printf "%s\"%s\"", (i>1?",":""), $i}; printf "]"}')"
  fi

  local viewer_cert='{"CloudFrontDefaultCertificate": true, "MinimumProtocolVersion": "TLSv1.2_2021"}'
  if [[ -n "${ACM_CERTIFICATE_ARN:-}" ]]; then
    viewer_cert="{\"ACMCertificateArn\": \"${ACM_CERTIFICATE_ARN}\", \"SSLSupportMethod\": \"sni-only\", \"MinimumProtocolVersion\": \"TLSv1.2_2021\"}"
  fi

  aws cloudfront create-distribution \
    --distribution-config "$(jq -n \
      --arg comment "$CLOUDFRONT_COMMENT" \
      --arg origin_id "$ORIGIN_ID" \
      --arg bucket "$S3_BUCKET" \
      --arg region "$AWS_REGION" \
      --arg oac_id "$oac_id" \
      --argjson aliases "$aliases_json" \
      --argjson viewer_cert "$viewer_cert" \
      '{
        CallerReference: (now | tostring),
        Comment: $comment,
        Enabled: true,
        DefaultRootObject: "index.html",
        PriceClass: "PriceClass_100",
        Origins: {
          Quantity: 1,
          Items: [{
            Id: $origin_id,
            DomainName: ($bucket + ".s3." + $region + ".amazonaws.com"),
            OriginAccessControlId: $oac_id,
            S3OriginConfig: { OriginAccessIdentity: "" }
          }]
        },
        DefaultCacheBehavior: {
          TargetOriginId: $origin_id,
          ViewerProtocolPolicy: "redirect-to-https",
          AllowedMethods: {
            Quantity: 2,
            Items: ["GET", "HEAD"],
            CachedMethods: { Quantity: 2, Items: ["GET", "HEAD"] }
          },
          Compress: true,
          CachePolicyId: "658327ea-f89d-4fab-a63d-7e88639e58f6"
        },
        Aliases: {
          Quantity: ($aliases | length),
          Items: $aliases
        },
        ViewerCertificate: $viewer_cert
      }')" \
    --query 'Distribution.{Id:Id,DomainName:DomainName,Status:Status}' \
    --output json
}

OAC_ID="$(ensure_oac)"
DISTRIBUTION_ID="$(find_distribution_id)"

if [[ -z "$DISTRIBUTION_ID" ]]; then
  echo "Creating new CloudFront distribution"
  CREATE_RESULT="$(create_distribution "$OAC_ID")"
  DISTRIBUTION_ID="$(echo "$CREATE_RESULT" | jq -r '.Id')"
  DOMAIN_NAME="$(echo "$CREATE_RESULT" | jq -r '.DomainName')"
  echo "$CREATE_RESULT" > "$STATE_FILE"
else
  echo "Using existing CloudFront distribution ${DISTRIBUTION_ID}"
  DOMAIN_NAME="$(aws cloudfront get-distribution --id "$DISTRIBUTION_ID" --query 'Distribution.DomainName' --output text)"
  jq -n \
    --arg distributionId "$DISTRIBUTION_ID" \
    --arg domainName "$DOMAIN_NAME" \
    '{distributionId:$distributionId,domainName:$domainName}' > "$STATE_FILE"
fi

echo "==> Applying bucket policy for CloudFront OAC"
apply_bucket_policy "$DISTRIBUTION_ID"

echo "==> Creating CloudFront invalidation"
INVALIDATION_ID="$(aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*" \
  --query 'Invalidation.Id' \
  --output text)"

cat <<EOF

Deployment complete.

S3 bucket:      s3://${S3_BUCKET}
CloudFront ID:  ${DISTRIBUTION_ID}
CloudFront URL: https://${DOMAIN_NAME}/
Invalidation:   ${INVALIDATION_ID}

Next steps:
- Point DNS for www.mervin-cz.com to ${DOMAIN_NAME}
- If using custom domain, set ACM_CERTIFICATE_ARN and CLOUDFRONT_ALIASES before deploy
EOF
