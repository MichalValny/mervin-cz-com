# AWS setup – web-mervin-cz-com (účet 777171524899)

Kompletní návod pro nový AWS účet: S3, CloudFront, upload Lambda, GitHub Secrets.

## Přehled

| Resource | Název |
|----------|-------|
| AWS Account ID | `777171524899` |
| S3 bucket | `web-mervin-cz-com` |
| Region | `us-east-1` |
| CloudFront comment | `web-mervin-cz-com static site` |
| Lambda | `mervin-upload-api` |
| Lambda role | `mervin-upload-api-role` |
| Upload S3 prefix | `uploads-staging/` |

## 1. IAM users

Vytvořte v **IAM → Users**:

| User | Policy | Účel |
|------|--------|------|
| `mervin-cz-bootstrap` | `AdministratorAccess` | Jednorázový první deploy |
| `mervin-cz-deploy` | inline `mervin-cz-deploy` | GitHub Actions + běžný deploy |

### Inline policy `mervin-cz-deploy`

Soubor v repozitáři: [`docs/iam/mervin-cz-deploy-policy.json`](iam/mervin-cz-deploy-policy.json)

IAM → Users → `mervin-cz-deploy` → Add permissions → Create inline policy → JSON vložit z toho souboru.

## 2. První deploy

### Varianta A – bez lokálního PC (doporučeno)

1. Nastavte **GitHub Secrets a Variables** (viz sekce 3 a 4) — klíče od **`mervin-cz-bootstrap`**.
2. Spusťte **Actions → Bootstrap AWS → Run workflow**.
3. Po úspěchu v Secrets **vyměňte** AWS klíče za **`mervin-cz-deploy`** a bootstrap user deaktivujte.

### Varianta B – lokálně na PC

Nainstalujte: AWS CLI, Node.js 22, npm, jq, python3, git.

```bash
git clone https://github.com/MichalValny/mervin-cz-com.git
cd mervin-cz-com

# Klíče od mervin-cz-bootstrap (první běh)
export AWS_ACCESS_KEY_ID='...'
export AWS_SECRET_ACCESS_KEY='...'
export AWS_REGION='us-east-1'

# Upload API (volitelné, lze doplnit později)
export UPLOAD_JWT_SECRET="$(openssl rand -hex 32)"
export UPLOAD_PASSWORD_MICHAL='...'
export UPLOAD_PASSWORD_HORAK='...'
export UPLOAD_GITHUB_TOKEN='ghp_...'

bash scripts/bootstrap-aws.sh
```

Skript:
1. Vytvoří bucket `web-mervin-cz-com`
2. Vytvoří CloudFront + OAC + rewrite funkci
3. Nahraje web
4. (Volitelně) nasadí upload Lambda + API Gateway

Výstup obsahuje CloudFront URL a checklist pro GitHub.

Po úspěchu: **smažte access key u `mervin-cz-bootstrap`**.

## 3. GitHub Secrets

**Settings → Secrets and variables → Actions → Secrets**

| Secret | Hodnota |
|--------|---------|
| `AWS_ACCESS_KEY_ID` | klíč od **`mervin-cz-deploy`** |
| `AWS_SECRET_ACCESS_KEY` | secret od **`mervin-cz-deploy`** |
| `UPLOAD_PASSWORD_MICHAL` | upload heslo |
| `UPLOAD_PASSWORD_HORAK` | upload heslo |
| `UPLOAD_JWT_SECRET` | stejný jako při deployi Lambda |
| `UPLOAD_GITHUB_TOKEN` | GitHub PAT (`repo` + `workflow`) |

## 4. GitHub Variables

**Settings → Secrets and variables → Actions → Variables**

| Variable | Hodnota |
|----------|---------|
| `S3_BUCKET` | `web-mervin-cz-com` |
| `UPLOAD_S3_BUCKET` | `web-mervin-cz-com` |
| `AWS_REGION` | `us-east-1` |
| `PUBLIC_UPLOAD_API_URL` | URL z `src/data/upload-api.json` po deployi upload API |
| `ACM_CERTIFICATE_ARN` | (volitelné) certifikát pro www.mervin-cz.com v us-east-1 |
| `CLOUDFRONT_ALIASES` | (volitelné) `www.mervin-cz.com,mervin-cz.com` |

## 5. Průběžný deploy

Po nastavení GitHub Secrets stačí push do `main` nebo **Actions → Deploy to AWS → Run workflow**.

Lokální deploy:

```bash
export AWS_ACCESS_KEY_ID='...'   # mervin-cz-deploy
export AWS_SECRET_ACCESS_KEY='...'
bash scripts/deploy-aws.sh
```

Upload API redeploy:

```bash
bash scripts/deploy-upload-api.sh
```

## 6. Lambda role (automaticky)

Deploy skript vytvoří roli `mervin-upload-api-role` s:

- managed policy `AWSLambdaBasicExecutionRole`
- inline policy `mervin-upload-api-role-s3` — viz [`docs/iam/mervin-upload-api-role-s3-policy.json`](iam/mervin-upload-api-role-s3-policy.json)

## 7. DNS (volitelné)

Po deployi nasměrujte DNS záznamy domény na CloudFront domain name z výstupu deploy skriptu (nebo z `.aws-deploy/cloudfront.json`).

Pro custom doménu nastavte před deployem:

```bash
export ACM_CERTIFICATE_ARN='arn:aws:acm:us-east-1:777171524899:certificate/...'
export CLOUDFRONT_ALIASES='www.mervin-cz.com,mervin-cz.com'
bash scripts/deploy-aws.sh
```

## 8. Upload portal

Detailní popis uploadu: [`UPLOAD_SETUP.md`](UPLOAD_SETUP.md)

## Troubleshooting

| Chyba | Řešení |
|-------|--------|
| `AccessDenied` on `CreateBucket` | Bucket ještě neexistuje — spusťte **Bootstrap AWS** s `mervin-cz-bootstrap` |
| `S3 bucket ... was not found` | Stejné — bootstrap workflow nebo `bash scripts/bootstrap-aws.sh` |
| `AccessDenied` on `iam:CreateRole` | Policy `mervin-cz-deploy` nebo bootstrap admin |
| Upload login „Failed to fetch“ | Zkontrolujte `PUBLIC_UPLOAD_API_URL` a CORS (`UPLOAD_ALLOWED_ORIGINS`) |
| Instagram nefunguje | Workflow **Refresh Instagram feed** (denně automaticky) |
