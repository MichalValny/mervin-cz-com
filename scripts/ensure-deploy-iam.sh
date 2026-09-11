#!/usr/bin/env bash
set -euo pipefail

# Create IAM user mervin-cz-deploy with deploy policy (bootstrap only).
# Requires AdministratorAccess (mervin-cz-bootstrap).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=aws-env.defaults.sh
source "${ROOT_DIR}/scripts/aws-env.defaults.sh"

: "${DEPLOY_IAM_USER:=mervin-cz-deploy}"
: "${DEPLOY_IAM_POLICY_NAME:=mervin-cz-deploy}"

POLICY_FILE="${ROOT_DIR}/docs/iam/mervin-cz-deploy-policy.json"

if [[ ! -f "$POLICY_FILE" ]]; then
  echo "Missing IAM policy file: ${POLICY_FILE}" >&2
  exit 1
fi

echo "==> Ensuring IAM user ${DEPLOY_IAM_USER}"
if ! aws iam get-user --user-name "$DEPLOY_IAM_USER" >/dev/null 2>&1; then
  aws iam create-user --user-name "$DEPLOY_IAM_USER" >/dev/null
  echo "Created IAM user ${DEPLOY_IAM_USER}"
else
  echo "IAM user ${DEPLOY_IAM_USER} already exists"
fi

aws iam put-user-policy \
  --user-name "$DEPLOY_IAM_USER" \
  --policy-name "$DEPLOY_IAM_POLICY_NAME" \
  --policy-document "file://${POLICY_FILE}"

echo "Applied inline policy ${DEPLOY_IAM_POLICY_NAME} to ${DEPLOY_IAM_USER}"
echo
echo "Next: create an access key for ${DEPLOY_IAM_USER} in AWS Console"
echo "and save it as GitHub Secrets AWS_DEPLOY_ACCESS_KEY_ID / AWS_DEPLOY_SECRET_ACCESS_KEY"
