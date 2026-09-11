#!/usr/bin/env bash
set -euo pipefail

# Create or update S3 + CloudFront infrastructure (bootstrap / mervin-cz-bootstrap only).

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
require_cmd jq

export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_REGION

STATE_DIR="${ROOT_DIR}/.aws-deploy"
mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/cloudfront.json"
INFRA_FILE="${ROOT_DIR}/src/data/aws-infra.json"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ORIGIN_ID="S3-${S3_BUCKET}"
OAC_NAME="web-mervin-cz-com-oac"

create_s3_bucket() {
  local err_file="$1"
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$S3_BUCKET" 2>"$err_file"
  else
    aws s3api create-bucket \
      --bucket "$S3_BUCKET" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" \
      2>"$err_file"
  fi
}

ensure_s3_bucket() {
  local err_file
  local attempt
  local wait_seconds
  err_file="$(mktemp)"

  for attempt in $(seq 1 12); do
    if aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
      rm -f "$err_file"
      echo "Bucket s3://${S3_BUCKET} already exists."
      return 0
    fi

    : >"$err_file"
    if create_s3_bucket "$err_file"; then
      rm -f "$err_file"
      echo "Bucket s3://${S3_BUCKET} is ready."
      return 0
    fi

    if grep -qE 'BucketAlreadyOwnedByYou|BucketAlreadyExists' "$err_file"; then
      rm -f "$err_file"
      echo "Bucket s3://${S3_BUCKET} already exists (owned by this account)."
      return 0
    fi

    if grep -q 'OperationAborted' "$err_file"; then
      wait_seconds=$((attempt * 30))
      echo "Bucket name still propagating after deletion (OperationAborted). Retry ${attempt}/12 in ${wait_seconds}s..."
      sleep "$wait_seconds"
      continue
    fi

    echo "Failed to ensure S3 bucket s3://${S3_BUCKET}:" >&2
    cat "$err_file" >&2
    rm -f "$err_file"
    exit 1
  done

  echo "Failed to create s3://${S3_BUCKET} after retries." >&2
  echo "If the bucket was recently deleted in another AWS account, wait up to an hour and rerun Bootstrap AWS." >&2
  cat "$err_file" >&2
  rm -f "$err_file"
  exit 1
}

echo "==> Ensuring S3 bucket s3://${S3_BUCKET}"
ensure_s3_bucket

aws s3api put-public-access-block \
  --bucket "$S3_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

find_distribution_id() {
  if [[ -f "$STATE_FILE" ]]; then
    local saved_id
    saved_id="$(jq -r '.distributionId // empty' "$STATE_FILE")"
    if [[ -n "$saved_id" ]]; then
      echo "$saved_id"
      return
    fi
  fi

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

apply_bucket_cors() {
  local cloudfront_domain="$1"
  local cors_file
  cors_file="$(mktemp)"

  jq -n \
    --arg cf "https://${cloudfront_domain}" \
    --arg aliases "${CLOUDFRONT_ALIASES:-}" \
    '{
      CORSRules: [{
        AllowedHeaders: ["*"],
        AllowedMethods: ["GET", "PUT", "HEAD"],
        AllowedOrigins: (
          ["https://www.mervin-cz.com", "https://mervin-cz.com", "http://localhost:4321"] +
          (if $cf != "https://" then [$cf] else [] end) +
          ($aliases | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | map(if startswith("http") then . else "https://" + . end))
        ),
        ExposeHeaders: ["ETag"],
        MaxAgeSeconds: 3000
      }]
    }' > "$cors_file"

  aws s3api put-bucket-cors --bucket "$S3_BUCKET" --cors-configuration "file://${cors_file}"
  rm -f "$cors_file"
  echo "Applied S3 CORS for browser uploads"
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
    },
    {
      "Sid": "AllowDeployUser",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:user/mervin-cz-deploy"
      },
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:PutBucketPolicy",
        "s3:GetBucketPolicy",
        "s3:PutBucketPublicAccessBlock",
        "s3:GetBucketPublicAccessBlock"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET}",
        "arn:aws:s3:::${S3_BUCKET}/*"
      ]
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

echo "==> Ensuring CloudFront distribution"
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
  attach_index_rewrite_function "$DISTRIBUTION_ID" "$FUNCTION_ARN"
  jq -n \
    --arg distributionId "$DISTRIBUTION_ID" \
    --arg domainName "$DOMAIN_NAME" \
    '{distributionId:$distributionId,domainName:$domainName}' > "$STATE_FILE"
fi

echo "==> Applying bucket policy"
apply_bucket_policy "$DISTRIBUTION_ID"

echo "==> Applying S3 CORS for upload portal"
apply_bucket_cors "$DOMAIN_NAME"

node -e "
const fs = require('fs');
const payload = {
  bucket: process.argv[1],
  distributionId: process.argv[2],
  domainName: process.argv[3],
  region: process.argv[4],
  accountId: process.argv[5],
};
fs.writeFileSync(process.argv[6], JSON.stringify(payload, null, 2) + '\n');
" "$S3_BUCKET" "$DISTRIBUTION_ID" "$DOMAIN_NAME" "$AWS_REGION" "$ACCOUNT_ID" "$INFRA_FILE"

echo "Wrote ${INFRA_FILE}"
echo "CloudFront URL: https://${DOMAIN_NAME}/"
