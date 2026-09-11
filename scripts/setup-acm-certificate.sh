#!/usr/bin/env bash
set -euo pipefail

# Request or reuse an ACM certificate in us-east-1 for CloudFront (bootstrap only).
#
# Optional:
#   CLOUDFRONT_ALIASES (comma-separated, e.g. www.mervin-cz.com,mervin-cz.com)
#   ACM_CERTIFICATE_ARN (skip if already known)
#
# Exports ACM_CERTIFICATE_ARN when a certificate is found or requested.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=aws-env.defaults.sh
source "${ROOT_DIR}/scripts/aws-env.defaults.sh"

ACM_STATE_FILE="${ROOT_DIR}/.aws-deploy/acm-certificate-arn"

if [[ -n "${ACM_CERTIFICATE_ARN:-}" ]]; then
  echo "Using existing ACM certificate: ${ACM_CERTIFICATE_ARN}"
  mkdir -p "${ROOT_DIR}/.aws-deploy"
  printf '%s\n' "$ACM_CERTIFICATE_ARN" > "$ACM_STATE_FILE"
  exit 0
fi

if [[ -z "${CLOUDFRONT_ALIASES:-}" ]]; then
  echo "No CLOUDFRONT_ALIASES set; skipping ACM certificate setup."
  exit 0
fi

ACM_REGION="us-east-1"
PRIMARY_DOMAIN="$(printf '%s' "$CLOUDFRONT_ALIASES" | awk -F, '{gsub(/^ +| +$/, "", $1); print $1}')"
ALT_DOMAINS="$(printf '%s' "$CLOUDFRONT_ALIASES" | awk -F, '{
  for (i=2; i<=NF; i++) {
    gsub(/^ +| +$/, "", $i)
    if ($i != "") print $i
  }
}')"

echo "==> Ensuring ACM certificate for ${PRIMARY_DOMAIN} (region ${ACM_REGION})"

EXISTING_ARN="$(aws acm list-certificates \
  --region "$ACM_REGION" \
  --certificate-statuses ISSUED PENDING_VALIDATION \
  --query "CertificateSummaryList[?DomainName=='${PRIMARY_DOMAIN}'].CertificateArn | [0]" \
  --output text 2>/dev/null | sed '/^None$/d')"

if [[ -n "$EXISTING_ARN" ]]; then
  echo "Found existing certificate: ${EXISTING_ARN}"
  export ACM_CERTIFICATE_ARN="$EXISTING_ARN"
else
  SAN_ARGS=()
  if [[ -n "$ALT_DOMAINS" ]]; then
    while IFS= read -r alt; do
      [[ -z "$alt" ]] && continue
      SAN_ARGS+=(--subject-alternative-names "$alt")
    done <<< "$ALT_DOMAINS"
  fi

  ACM_CERTIFICATE_ARN="$(aws acm request-certificate \
    --region "$ACM_REGION" \
    --domain-name "$PRIMARY_DOMAIN" \
    "${SAN_ARGS[@]}" \
    --validation-method DNS \
    --query CertificateArn \
    --output text)"
  echo "Requested new certificate: ${ACM_CERTIFICATE_ARN}"
  export ACM_CERTIFICATE_ARN
fi

echo
echo "==> DNS validation records (add these at your DNS provider):"
aws acm describe-certificate \
  --region "$ACM_REGION" \
  --certificate-arn "$ACM_CERTIFICATE_ARN" \
  --query 'Certificate.DomainValidationOptions[].ResourceRecord' \
  --output table

STATUS="$(aws acm describe-certificate \
  --region "$ACM_REGION" \
  --certificate-arn "$ACM_CERTIFICATE_ARN" \
  --query 'Certificate.Status' \
  --output text)"

if [[ "$STATUS" != "ISSUED" ]]; then
  echo
  echo "Certificate status: ${STATUS}"
  echo "CloudFront will use this ARN once DNS validation completes."
  echo "Re-run Bootstrap AWS after validation if the first deploy used the default cert."
fi

mkdir -p "${ROOT_DIR}/.aws-deploy"
printf '%s\n' "$ACM_CERTIFICATE_ARN" > "$ACM_STATE_FILE"
