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
#   S3_BUCKET (default: web-mervin-cz-com)
#   CLOUDFRONT_COMMENT (default: web-mervin-cz-com static site)
#   ACM_CERTIFICATE_ARN (for custom domain aliases, must be in us-east-1)
#   CLOUDFRONT_ALIASES (comma-separated, e.g. www.mervin-cz.com,mervin-cz.com)

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

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "AWS credentials are not configured." >&2
  echo "Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, then rerun." >&2
  exit 1
fi

export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_REGION

echo "==> Building site"
export PUBLIC_UPLOAD_API_URL="${PUBLIC_UPLOAD_API_URL:-}"
if [[ -n "$PUBLIC_UPLOAD_API_URL" ]]; then
  echo "Upload API URL: ${PUBLIC_UPLOAD_API_URL} (from environment)"
else
  echo "Upload API URL: using src/data/upload-api.json fallback"
fi
npm run build

echo "==> Ensuring S3 bucket s3://${S3_BUCKET} exists in ${AWS_REGION}"
bucket_missing() {
  local err_file
  err_file="$(mktemp)"

  if aws s3api get-bucket-location --bucket "$S3_BUCKET" >/dev/null 2>"$err_file"; then
    rm -f "$err_file"
    return 1
  fi
  if ! grep -qE 'NoSuchBucket|404|Not Found' "$err_file"; then
    if aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>"$err_file"; then
      rm -f "$err_file"
      return 1
    fi
    if ! grep -qE 'NoSuchBucket|404|Not Found' "$err_file"; then
      echo "Cannot access S3 bucket s3://${S3_BUCKET}:" >&2
      cat "$err_file" >&2
      rm -f "$err_file"
      exit 1
    fi
  fi

  rm -f "$err_file"
  return 0
}

if bucket_missing; then
  if [[ "${AWS_ALLOW_CREATE_BUCKET:-}" != "true" ]]; then
    echo "S3 bucket s3://${S3_BUCKET} was not found." >&2
    echo "Run scripts/bootstrap-aws.sh first (with mervin-cz-bootstrap credentials)." >&2
    exit 1
  fi
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$S3_BUCKET"
  else
    aws s3api create-bucket \
      --bucket "$S3_BUCKET" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
  fi
fi

if ! aws s3api put-public-access-block \
  --bucket "$S3_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true 2>/dev/null; then
  echo "Warning: could not update public access block (may already be set or need s3:PutBucketPublicAccessBlock)."
fi

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
OAC_NAME="web-mervin-cz-com-oac"

find_distribution_id() {
  if [[ -f "$STATE_FILE" ]]; then
    local saved_id
    saved_id="$(jq -r '.distributionId // empty' "$STATE_FILE")"
    if [[ -n "$saved_id" ]]; then
      echo "$saved_id"
      return
    fi
  fi

  # Prefer the oldest deployed distribution with our comment.
  aws cloudfront list-distributions \
    --query "DistributionList.Items[?Comment=='${CLOUDFRONT_COMMENT}'] | sort_by(@, &Id)[].Id" \
    --output text 2>/dev/null | awk '{print $1}' | sed '/^None$/d'
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

s3_origin_domain() {
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    echo "${S3_BUCKET}.s3.amazonaws.com"
  else
    echo "${S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com"
  fi
}

ensure_index_rewrite_function() {
  local function_name="web-mervin-cz-com-index-rewrite"
  local etag
  local existing
  existing="$(aws cloudfront list-functions \
    --query "FunctionList.Items[?Name=='${function_name}'].Name | [0]" \
    --output text 2>/dev/null | sed '/^None$/d')"

  if [[ -z "$existing" ]]; then
    etag="$(aws cloudfront create-function \
      --name "$function_name" \
      --function-config '{"Comment":"Append index.html for directory URLs","Runtime":"cloudfront-js-2.0"}' \
      --function-code "fileb://${ROOT_DIR}/scripts/cloudfront-index-rewrite.js" \
      --query 'ETag' \
      --output text)"
  else
    etag="$(aws cloudfront describe-function --name "$function_name" --query 'ETag' --output text)"
    etag="$(aws cloudfront update-function \
      --name "$function_name" \
      --if-match "$etag" \
      --function-config '{"Comment":"Append index.html for directory URLs","Runtime":"cloudfront-js-2.0"}' \
      --function-code "fileb://${ROOT_DIR}/scripts/cloudfront-index-rewrite.js" \
      --query 'ETag' \
      --output text)"
  fi

  aws cloudfront publish-function --name "$function_name" --if-match "$etag" >/dev/null
  echo "arn:aws:cloudfront::${ACCOUNT_ID}:function/${function_name}"
}

attach_index_rewrite_function() {
  local distribution_id="$1"
  local function_arn="$2"
  local config_file="${STATE_DIR}/distribution-config.json"
  local etag

  aws cloudfront get-distribution-config --id "$distribution_id" --output json > "$config_file"
  etag="$(jq -r '.ETag' "$config_file")"
  jq --arg arn "$function_arn" \
    '.DistributionConfig.DefaultCacheBehavior.FunctionAssociations = {
      "Quantity": 1,
      "Items": [{ "FunctionARN": $arn, "EventType": "viewer-request" }]
    } | .DistributionConfig' \
    "$config_file" > "${config_file}.updated"

  aws cloudfront update-distribution \
    --id "$distribution_id" \
    --if-match "$etag" \
    --distribution-config "file://${config_file}.updated" >/dev/null
}

create_distribution() {
  local oac_id="$1"
  local function_arn="$2"
  local aliases_json="[]"
  if [[ -n "${CLOUDFRONT_ALIASES:-}" ]]; then
    aliases_json="$(printf '%s' "$CLOUDFRONT_ALIASES" | awk -F, '{printf "["; for (i=1; i<=NF; i++) {gsub(/^ +| +$/, "", $i); printf "%s\"%s\"", (i>1?",":""), $i}; printf "]"}')"
  fi

  local viewer_cert='{"CloudFrontDefaultCertificate": true, "MinimumProtocolVersion": "TLSv1.2_2021"}'
  if [[ -n "${ACM_CERTIFICATE_ARN:-}" ]]; then
    viewer_cert="{\"ACMCertificateArn\": \"${ACM_CERTIFICATE_ARN}\", \"SSLSupportMethod\": \"sni-only\", \"MinimumProtocolVersion\": \"TLSv1.2_2021\"}"
  fi

  local origin_domain
  origin_domain="$(s3_origin_domain)"

  aws cloudfront create-distribution \
    --distribution-config "$(jq -n \
      --arg comment "$CLOUDFRONT_COMMENT" \
      --arg origin_id "$ORIGIN_ID" \
      --arg origin_domain "$origin_domain" \
      --arg oac_id "$oac_id" \
      --arg function_arn "$function_arn" \
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
            DomainName: $origin_domain,
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
          CachePolicyId: "658327ea-f89d-4fab-a63d-7e88639e58f6",
          FunctionAssociations: {
            Quantity: 1,
            Items: [{ FunctionARN: $function_arn, EventType: "viewer-request" }]
          }
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
FUNCTION_ARN="$(ensure_index_rewrite_function)"
DISTRIBUTION_ID="$(find_distribution_id)"

if [[ -z "$DISTRIBUTION_ID" ]]; then
  echo "Creating new CloudFront distribution"
  CREATE_RESULT="$(create_distribution "$OAC_ID" "$FUNCTION_ARN")"
  DISTRIBUTION_ID="$(echo "$CREATE_RESULT" | jq -r '.Id')"
  DOMAIN_NAME="$(echo "$CREATE_RESULT" | jq -r '.DomainName')"
  echo "$CREATE_RESULT" > "$STATE_FILE"
else
  echo "Using existing CloudFront distribution ${DISTRIBUTION_ID}"
  DOMAIN_NAME="$(aws cloudfront get-distribution --id "$DISTRIBUTION_ID" --query 'Distribution.DomainName' --output text)"
  echo "==> Ensuring index.html rewrite function is attached"
  attach_index_rewrite_function "$DISTRIBUTION_ID" "$FUNCTION_ARN"
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
