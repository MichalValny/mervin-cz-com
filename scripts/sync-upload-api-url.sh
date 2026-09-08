#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${AWS_REGION:=us-east-1}"
: "${UPLOAD_API_NAME:=mervin-upload-api}"

export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_REGION

if ! command -v aws >/dev/null 2>&1; then
  echo "Missing required command: aws" >&2
  exit 1
fi

api_id="$(aws apigatewayv2 get-apis --query "Items[?Name=='${UPLOAD_API_NAME}'].ApiId | [0]" --output text | sed '/^None$/d')"
if [[ -z "$api_id" ]]; then
  echo "Upload API '${UPLOAD_API_NAME}' was not found in ${AWS_REGION}." >&2
  echo "Run: bash scripts/deploy-upload-api.sh" >&2
  exit 1
fi

api_url="$(aws apigatewayv2 get-api --api-id "$api_id" --query 'ApiEndpoint' --output text)"
node -e "const fs=require('fs'); fs.writeFileSync('src/data/upload-api.json', JSON.stringify({ apiUrl: process.argv[1] }, null, 2) + '\n');" "$api_url"

cat <<EOF
Upload API URL synced from AWS.

  API ID:  ${api_id}
  API URL: ${api_url}

Updated src/data/upload-api.json
Set GitHub variable PUBLIC_UPLOAD_API_URL to the same URL, then redeploy the site.
EOF
