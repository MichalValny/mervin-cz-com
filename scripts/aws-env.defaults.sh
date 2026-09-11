# Shared AWS defaults for mervin-cz.com on account 777171524899.
# Source from deploy scripts; override via environment variables.

: "${AWS_REGION:=us-east-1}"
: "${AWS_ACCOUNT_ID:=777171524899}"
: "${S3_BUCKET:=web-mervin-cz-com}"
: "${UPLOAD_S3_BUCKET:=${S3_BUCKET}}"
: "${UPLOAD_S3_PREFIX:=uploads-staging}"
: "${UPLOAD_API_NAME:=mervin-upload-api}"
: "${CLOUDFRONT_COMMENT:=web-mervin-cz-com static site}"
: "${GITHUB_UPLOAD_REPO:=MichalValny/mervin-cz-com}"
: "${DEPLOY_IAM_USER:=mervin-cz-deploy}"
: "${BOOTSTRAP_IAM_USER:=mervin-cz-bootstrap}"

export AWS_REGION AWS_ACCOUNT_ID S3_BUCKET UPLOAD_S3_BUCKET UPLOAD_S3_PREFIX UPLOAD_API_NAME CLOUDFRONT_COMMENT GITHUB_UPLOAD_REPO DEPLOY_IAM_USER BOOTSTRAP_IAM_USER
