#!/usr/bin/env bash
set -euo pipefail

# Deploy the upload API Lambda + HTTP API Gateway.
#
# Required environment variables:
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#   UPLOAD_JWT_SECRET
#   UPLOAD_PASSWORD_MICHAL
#   UPLOAD_PASSWORD_HORAK
#   UPLOAD_GITHUB_TOKEN
#
# Optional:
#   AWS_REGION (default: us-east-1)
#   UPLOAD_S3_BUCKET (default: mervin-cz-com)
#   UPLOAD_S3_PREFIX (default: uploads-staging)
#   UPLOAD_API_NAME (default: mervin-upload-api)
#   GITHUB_UPLOAD_REPO (default: MichalValny/mervin-cz-com)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export PATH="${HOME}/.local/bin:${PATH}"
: "${AWS_REGION:=us-east-1}"
: "${UPLOAD_S3_BUCKET:=mervin-cz-com}"
: "${UPLOAD_S3_PREFIX:=uploads-staging}"
: "${UPLOAD_API_NAME:=mervin-upload-api}"
: "${GITHUB_UPLOAD_REPO:=MichalValny/mervin-cz-com}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd aws
require_cmd npm
require_cmd jq

create_zip_archive() {
  local archive_path="$1"
  local source_dir="$2"
  rm -f "$archive_path"
  if command -v zip >/dev/null 2>&1; then
    (cd "$source_dir" && zip -qr "$archive_path" .)
    return
  fi
  echo "zip not found, using npx bestzip (Windows Git Bash friendly)…"
  (cd "$source_dir" && npx --yes bestzip "$archive_path" .)
}

for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY UPLOAD_JWT_SECRET UPLOAD_PASSWORD_MICHAL UPLOAD_PASSWORD_HORAK UPLOAD_GITHUB_TOKEN; do
  if [[ -z "${!var:-}" ]]; then
    echo "Missing required environment variable: $var" >&2
    exit 1
  fi
done

export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_REGION

STATE_DIR="${ROOT_DIR}/.aws-deploy"
mkdir -p "$STATE_DIR"
STATE_FILE="${STATE_DIR}/upload-api.json"

ROLE_NAME="${UPLOAD_API_NAME}-role"
FUNCTION_NAME="${UPLOAD_API_NAME}"
API_NAME="${UPLOAD_API_NAME}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

ensure_lambda_role() {
  if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    return
  fi

  TRUST_POLICY='{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }'

  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" >/dev/null

  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

  POLICY_DOC="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:HeadObject"],
      "Resource": "arn:aws:s3:::${UPLOAD_S3_BUCKET}/${UPLOAD_S3_PREFIX}/*"
    }
  ]
}
EOF
)"

  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "${ROLE_NAME}-s3" \
    --policy-document "$POLICY_DOC"

  echo "Waiting for IAM role propagation…"
  sleep 10
}

build_lambda_package() {
  echo "==> Installing upload API dependencies"
  npm ci --prefix upload-api
  PACKAGE_DIR="${ROOT_DIR}/.upload-api-package"
  rm -rf "$PACKAGE_DIR"
  mkdir -p "$PACKAGE_DIR"
  cp upload-api/src/*.mjs "$PACKAGE_DIR/"
  cp -R upload-api/node_modules "$PACKAGE_DIR/node_modules"
  cat > "${PACKAGE_DIR}/index.mjs" <<'EOF'
export { handler } from './handler.mjs';
EOF
  create_zip_archive "${ROOT_DIR}/.upload-api.zip" "$PACKAGE_DIR"
}

deploy_lambda() {
  build_lambda_package
  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
  ENV_JSON="$(jq -n \
    --arg jwt "$UPLOAD_JWT_SECRET" \
    --arg michal "$UPLOAD_PASSWORD_MICHAL" \
    --arg horak "$UPLOAD_PASSWORD_HORAK" \
    --arg github "$UPLOAD_GITHUB_TOKEN" \
    --arg repo "$GITHUB_UPLOAD_REPO" \
    --arg bucket "$UPLOAD_S3_BUCKET" \
    --arg prefix "$UPLOAD_S3_PREFIX" \
    '{
      Variables: {
        UPLOAD_JWT_SECRET: $jwt,
        UPLOAD_PASSWORD_MICHAL: $michal,
        UPLOAD_PASSWORD_HORAK: $horak,
        UPLOAD_GITHUB_TOKEN: $github,
        GITHUB_UPLOAD_REPO: $repo,
        UPLOAD_S3_BUCKET: $bucket,
        UPLOAD_S3_PREFIX: $prefix
      }
    }')"

  if aws lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
    aws lambda update-function-code \
      --function-name "$FUNCTION_NAME" \
      --zip-file "fileb://${ROOT_DIR}/.upload-api.zip" >/dev/null
    aws lambda wait function-updated --function-name "$FUNCTION_NAME"
    aws lambda update-function-configuration \
      --function-name "$FUNCTION_NAME" \
      --runtime nodejs22.x \
      --handler index.handler \
      --timeout 30 \
      --memory-size 512 \
      --environment "$ENV_JSON" >/dev/null
  else
    aws lambda create-function \
      --function-name "$FUNCTION_NAME" \
      --runtime nodejs22.x \
      --role "$ROLE_ARN" \
      --handler index.handler \
      --timeout 30 \
      --memory-size 512 \
      --zip-file "fileb://${ROOT_DIR}/.upload-api.zip" \
      --environment "$ENV_JSON" >/dev/null
  fi
}

ensure_http_api() {
  local api_id function_arn integration_id route_id

  if [[ -f "$STATE_FILE" ]]; then
    api_id="$(jq -r '.apiId // empty' "$STATE_FILE")"
  else
    api_id=""
  fi

  if [[ -z "$api_id" ]]; then
    api_id="$(aws apigatewayv2 get-apis --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text | sed '/^None$/d')"
  fi

  if [[ -z "$api_id" ]]; then
    api_id="$(aws apigatewayv2 create-api \
      --name "$API_NAME" \
      --protocol-type HTTP \
      --cors-configuration AllowOrigins='*',AllowMethods='GET,POST,OPTIONS',AllowHeaders='authorization,content-type' \
      --query ApiId \
      --output text)"
  fi

  function_arn="$(aws lambda get-function --function-name "$FUNCTION_NAME" --query 'Configuration.FunctionArn' --output text)"

  integration_id="$(aws apigatewayv2 get-integrations --api-id "$api_id" --query 'Items[0].IntegrationId' --output text | sed '/^None$/d')"
  if [[ -z "$integration_id" ]]; then
    integration_id="$(aws apigatewayv2 create-integration \
      --api-id "$api_id" \
      --integration-type AWS_PROXY \
      --integration-uri "$function_arn" \
      --payload-format-version 2.0 \
      --query IntegrationId \
      --output text)"
  fi

  route_id="$(aws apigatewayv2 get-routes --api-id "$api_id" --query "Items[?RouteKey=='ANY /{proxy+}'].RouteId | [0]" --output text | sed '/^None$/d')"
  if [[ -z "$route_id" ]]; then
    aws apigatewayv2 create-route \
      --api-id "$api_id" \
      --route-key 'ANY /{proxy+}' \
      --target "integrations/${integration_id}" >/dev/null
  fi

  stage_exists="$(aws apigatewayv2 get-stages --api-id "$api_id" --query "Items[?StageName=='\$default'].StageName | [0]" --output text | sed '/^None$/d')"
  if [[ -z "$stage_exists" ]]; then
    aws apigatewayv2 create-stage \
      --api-id "$api_id" \
      --stage-name '$default' \
      --auto-deploy >/dev/null
  fi

  aws lambda add-permission \
    --function-name "$FUNCTION_NAME" \
    --statement-id "${API_NAME}-apigw" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${api_id}/*/*" \
    >/dev/null 2>&1 || true

  api_endpoint="$(aws apigatewayv2 get-api --api-id "$api_id" --query 'ApiEndpoint' --output text)"
  jq -n \
    --arg apiId "$api_id" \
    --arg apiEndpoint "$api_endpoint" \
    '{apiId:$apiId, apiEndpoint:$apiEndpoint}' > "$STATE_FILE"

  echo "$api_endpoint"
}

ensure_lambda_role
deploy_lambda
API_URL="$(ensure_http_api)"

cat <<EOF

Upload API deployed.

API base URL: ${API_URL}

Set GitHub repository variable:
  PUBLIC_UPLOAD_API_URL=${API_URL}

Required GitHub secrets (if not already set):
  UPLOAD_PASSWORD_MICHAL
  UPLOAD_PASSWORD_HORAK
  UPLOAD_JWT_SECRET
  UPLOAD_GITHUB_TOKEN

EOF
