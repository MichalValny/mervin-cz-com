# Upload portal – setup

Webové nahrávání příspěvků je na `/upload/`. Po přihlášení uživatel vyplní formulář a fotky; systém vytvoří **Pull Request** ke schválení.

## Účty

| Jméno | Heslo |
|-------|-------|
| `Michal` | nastavíte v secret `UPLOAD_PASSWORD_MICHAL` |
| `Horak` | nastavíte v secret `UPLOAD_PASSWORD_HORAK` |

**Hesla neukládejte do repozitáře.** Nastavte je jen v GitHub Secrets / AWS Lambda.

## 1. GitHub Secrets

V repozitáři **Settings → Secrets and variables → Actions**:

| Secret | Popis |
|--------|--------|
| `UPLOAD_PASSWORD_MICHAL` | Vaše upload heslo |
| `UPLOAD_PASSWORD_HORAK` | Heslo pro Hořáka |
| `UPLOAD_JWT_SECRET` | Náhodný řetězec (např. `openssl rand -hex 32`) |
| `UPLOAD_GITHUB_TOKEN` | GitHub PAT s oprávněním `repo` a `workflow` |

Stávající `AWS_ACCESS_KEY_ID` a `AWS_SECRET_ACCESS_KEY` se používají i pro stažení fotek ze S3 ve workflow `process-upload.yml`.

## 2. GitHub Variables

**Settings → Secrets and variables → Actions → Variables**:

| Variable | Příklad |
|----------|---------|
| `PUBLIC_UPLOAD_API_URL` | `https://abc123.execute-api.us-east-1.amazonaws.com` |
| `UPLOAD_S3_BUCKET` | `mervin-cz-com` (volitelné) |
| `UPLOAD_S3_PREFIX` | `uploads-staging` (volitelné) |

## 3. Nasazení upload API (Lambda)

Na stroji s nakonfigurovaným AWS CLI:

```bash
export UPLOAD_JWT_SECRET='…'
export UPLOAD_PASSWORD_MICHAL='…'
export UPLOAD_PASSWORD_HORAK='…'
export UPLOAD_GITHUB_TOKEN='ghp_…'
bash scripts/deploy-upload-api.sh
```

Skript vytvoří Lambda + HTTP API a vypíše URL. Tu vložte do `PUBLIC_UPLOAD_API_URL`.

## 4. Nasazení webu

Po nastavení `PUBLIC_UPLOAD_API_URL` pushněte do `main` – deploy workflow sestaví stránku `/upload/` s odkazem na API.

## Tok dat

1. Uživatel se přihlásí na `/upload/`
2. Frontend pošle metadata na API → dostane S3 presigned URL
3. Fotky se nahrají přímo do S3 (`uploads-staging/{uuid}/`)
4. API spustí GitHub workflow `process-upload.yml`
5. Workflow stáhne fotky, vytvoří článek + galerii, otevře PR
6. Po merge PR proběhne běžný deploy na CloudFront

## Schvalování

Každý upload vytvoří PR s názvem `Upload: {nadpis}`. Sloučením PR se článek publikuje.
