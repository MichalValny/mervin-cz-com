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
| `UPLOAD_GITHUB_TOKEN` | GitHub PAT pro spuštění workflow `process-upload.yml` (viz níže) |

### `UPLOAD_GITHUB_TOKEN` — povinná oprávnění

Token musí umět spustit workflow `process-upload.yml` přes API. Bez toho `/complete` vrátí chybu 502.

**Classic PAT** (doporučeno): scopes `repo` + `workflow`

**Fine-grained PAT**:
- Repository: `MichalValny/mervin-cz-com`
- Permissions: **Actions: Read and write**, Metadata: Read

Po změně tokenu znovu spusťte **Bootstrap AWS** — Lambda si načte novou hodnotu z secrets.

`AWS_DEPLOY_ACCESS_KEY_ID` a `AWS_DEPLOY_SECRET_ACCESS_KEY` (uživatel `mervin-cz-deploy`) se používají pro stažení fotek ze S3 ve workflow `process-upload.yml`.

## 2. GitHub Variables

**Settings → Secrets and variables → Actions → Variables**:

| Variable | Příklad |
|----------|---------|
| `PUBLIC_UPLOAD_API_URL` | volitelné – přepíše `src/data/upload-api.json` |
| `UPLOAD_S3_BUCKET` | `web-mervin-cz-com` (volitelné) |
| `UPLOAD_S3_PREFIX` | `uploads-staging` (volitelné) |
| `S3_BUCKET` | `web-mervin-cz-com` |

Správnou API URL z AWS zjistíte:

```bash
bash scripts/sync-upload-api-url.sh
```

Kompletní AWS setup (nový účet): viz [`AWS_SETUP.md`](AWS_SETUP.md).

## 3. Nasazení upload API

Upload API (Lambda + API Gateway) se nasadí automaticky při workflow **Bootstrap AWS** — viz [`AWS_SETUP.md`](AWS_SETUP.md).

Policy pro `mervin-cz-deploy` (včetně Lambda): [`docs/iam/mervin-cz-deploy-policy.json`](iam/mervin-cz-deploy-policy.json)

Ruční redeploy (volitelné):

```bash
export AWS_BOOTSTRAP_ACCESS_KEY_ID='…'   # nebo AWS_DEPLOY_* pro update kódu
export AWS_BOOTSTRAP_SECRET_ACCESS_KEY='…'
export UPLOAD_JWT_SECRET='…'
export UPLOAD_PASSWORD_MICHAL='…'
export UPLOAD_PASSWORD_HORAK='…'
export UPLOAD_GITHUB_TOKEN='ghp_…'
bash scripts/deploy-upload-api.sh
```

## 4. Nasazení webu

Po aktualizaci `src/data/upload-api.json` (nebo nastavení `PUBLIC_UPLOAD_API_URL`) pushněte do `main` – deploy workflow sestaví stránku `/upload/` s odkazem na API.

## Tok dat

1. Uživatel se přihlásí na `/upload/`
2. Frontend pošle metadata na API → dostane S3 presigned URL
3. Fotky se nahrají přímo do S3 (`uploads-staging/{uuid}/`)
4. API spustí GitHub workflow `process-upload.yml`
5. Workflow stáhne fotky, vytvoří článek + galerii, otevře PR
6. Po merge PR proběhne běžný deploy na CloudFront

## Troubleshooting

| Chyba | Řešení |
|-------|--------|
| `Failed to fetch` / CORS při nahrávání fotek | S3 bucket nemá CORS pro `www.mervin-cz.com` — znovu spusťte **Bootstrap AWS** (nastaví CORS automaticky) |
| `Požadavek selhal` / 502 na `/complete` | `UPLOAD_GITHUB_TOKEN` nemá oprávnění `workflow` / Actions — vytvořte nový PAT a znovu spusťte **Bootstrap AWS** |
| `Nepodařilo se spojit s upload API` | Zkontrolujte `PUBLIC_UPLOAD_API_URL` a `src/data/upload-api.json` |

## Schvalování

Každý upload vytvoří PR s názvem `Upload: {nadpis}`. Sloučením PR se článek publikuje.
