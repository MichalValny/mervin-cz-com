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
| `PUBLIC_UPLOAD_API_URL` | volitelné – přepíše `src/data/upload-api.json` jen pokud soubor chybí nebo je neplatný |

Správnou URL z AWS zjistíte příkazem:

```bash
bash scripts/sync-upload-api-url.sh
```

Adresa musí přesně odpovídat výstupu deploy skriptu (zkopírujte celý řetězec, ne hádání z písma terminálu).
| `UPLOAD_S3_BUCKET` | `mervin-cz-com` (volitelné) |
| `UPLOAD_S3_PREFIX` | `uploads-staging` (volitelné) |

## 3. AWS oprávnění pro deploy upload API

Deploy skript potřebuje **více oprávnění** než samotný upload webu na S3. Uživatel `mervin-cz-delete` (nebo jiný deploy účet) musí umět vytvořit Lambda, API Gateway a IAM roli.

V **AWS Console → IAM → Users → váš uživatel → Add permissions → Create inline policy → JSON** vložte:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:PutRolePolicy",
        "iam:AttachRolePolicy",
        "iam:PassRole"
      ],
      "Resource": [
        "arn:aws:iam::146240438812:role/mervin-upload-api-role"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:GetFunction",
        "lambda:AddPermission"
      ],
      "Resource": "arn:aws:lambda:*:146240438812:function:mervin-upload-api"
    },
    {
      "Effect": "Allow",
      "Action": [
        "apigateway:GET",
        "apigateway:POST",
        "apigateway:PATCH"
      ],
      "Resource": "arn:aws:apigateway:*::/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:HeadObject"
      ],
      "Resource": "arn:aws:s3:::mervin-cz-com/uploads-staging/*"
    },
    {
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
```

Účet ID `146240438812` a bucket `mervin-cz-com` upravte, pokud se liší.

**Alternativa:** přihlaste se AWS CLI jednou účtem s admin právy, spusťte deploy, a pak stačí uživateli pro běh uploadu jen S3 + Lambda update (nebo deploy znovu jen při změně API).

## 4. Nasazení upload API (Lambda)

Na stroji s nakonfigurovaným AWS CLI:

```bash
export UPLOAD_JWT_SECRET='…'
export UPLOAD_PASSWORD_MICHAL='…'
export UPLOAD_PASSWORD_HORAK='…'
export UPLOAD_GITHUB_TOKEN='ghp_…'
export AWS_ACCESS_KEY_ID='…'
export AWS_SECRET_ACCESS_KEY='…'
bash scripts/deploy-upload-api.sh
```

Skript vytvoří Lambda + HTTP API, aktualizuje `src/data/upload-api.json` a vypíše URL. Soubor commitněte a pushněte do `main`, nebo nastavte `PUBLIC_UPLOAD_API_URL` v GitHub Variables.

## 5. Nasazení webu

Po aktualizaci `src/data/upload-api.json` (nebo nastavení `PUBLIC_UPLOAD_API_URL`) pushněte do `main` – deploy workflow sestaví stránku `/upload/` s odkazem na API.

## Tok dat

1. Uživatel se přihlásí na `/upload/`
2. Frontend pošle metadata na API → dostane S3 presigned URL
3. Fotky se nahrají přímo do S3 (`uploads-staging/{uuid}/`)
4. API spustí GitHub workflow `process-upload.yml`
5. Workflow stáhne fotky, vytvoří článek + galerii, otevře PR
6. Po merge PR proběhne běžný deploy na CloudFront

## Schvalování

Každý upload vytvoří PR s názvem `Upload: {nadpis}`. Sloučením PR se článek publikuje.
