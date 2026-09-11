# AWS setup – účet 777171524899

Kompletní infrastruktura se vytvoří **jedním kliknutím v GitHub Actions** — bez lokálního PC.

## Architektura

```
┌─────────────────────────────────────────────────────────────────┐
│  Jednorázově: Bootstrap AWS (workflow_dispatch)                 │
│  IAM: mervin-cz-bootstrap (AdministratorAccess)                 │
│  → IAM user mervin-cz-deploy, S3, CloudFront, ACM, Lambda       │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  Průběžně: Deploy to AWS (push do main / workflow_dispatch)      │
│  IAM: mervin-cz-deploy (omezená policy)                         │
│  → build, upload S3, CloudFront invalidation                      │
└─────────────────────────────────────────────────────────────────┘
```

| Resource | Název |
|----------|-------|
| AWS Account ID | `777171524899` |
| S3 bucket | `web-mervin-cz-com` |
| Region | `us-east-1` |
| Bootstrap IAM user | `mervin-cz-bootstrap` |
| Deploy IAM user | `mervin-cz-deploy` |
| CloudFront comment | `web-mervin-cz-com static site` |
| Lambda | `mervin-upload-api` |
| Upload S3 prefix | `uploads-staging/` |

## 1. Příprava v AWS Console (jednou, ručně)

1. V účtu `777171524899` vytvořte IAM uživatele **`mervin-cz-bootstrap`** s policy **`AdministratorAccess`**.
2. Vytvořte access key a uložte ji do GitHub Secrets (viz níže).
3. Uživatele **`mervin-cz-deploy`** vytvoří bootstrap automaticky — access key vytvoříte po bootstrapu v Console.

## 2. GitHub Secrets

**Settings → Secrets and variables → Actions → Secrets**

### Bootstrap (jen pro workflow „Bootstrap AWS“)

| Secret | Hodnota |
|--------|---------|
| `AWS_BOOTSTRAP_ACCESS_KEY_ID` | klíč od `mervin-cz-bootstrap` |
| `AWS_BOOTSTRAP_SECRET_ACCESS_KEY` | secret od `mervin-cz-bootstrap` |

### Deploy (pro workflow „Deploy to AWS“ a upload)

| Secret | Hodnota |
|--------|---------|
| `AWS_DEPLOY_ACCESS_KEY_ID` | klíč od `mervin-cz-deploy` (po bootstrapu) |
| `AWS_DEPLOY_SECRET_ACCESS_KEY` | secret od `mervin-cz-deploy` |
| `UPLOAD_PASSWORD_MICHAL` | upload heslo |
| `UPLOAD_PASSWORD_HORAK` | upload heslo |
| `UPLOAD_JWT_SECRET` | `openssl rand -hex 32` |
| `UPLOAD_GITHUB_TOKEN` | GitHub PAT (`repo` + `workflow`) |

> **Důležité:** Smažte nebo deaktivujte staré secrets `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` z původního účtu `146240438812`. Deploy workflow je už nepoužívá.

## 3. GitHub Variables

**Settings → Secrets and variables → Actions → Variables**

| Variable | Hodnota |
|----------|---------|
| `S3_BUCKET` | `web-mervin-cz-com` |
| `UPLOAD_S3_BUCKET` | `web-mervin-cz-com` |
| `AWS_REGION` | `us-east-1` |
| `CLOUDFRONT_ALIASES` | (volitelné) `www.mervin-cz.com,mervin-cz.com` |
| `ACM_CERTIFICATE_ARN` | (volitelné) nechte prázdné — bootstrap certifikát vyžádá |
| `CLOUDFRONT_DISTRIBUTION_ID` | doplní se po bootstrapu (nebo z `src/data/aws-infra.json`) |
| `PUBLIC_UPLOAD_API_URL` | doplní se po bootstrapu |

## 4. Bootstrap (první nasazení)

1. V účtu `777171524899` nastavte secrets `AWS_BOOTSTRAP_*` a upload secrets.
2. V GitHub Variables nastavte `S3_BUCKET` a `UPLOAD_S3_BUCKET` na `web-mervin-cz-com`.
3. Pokud bucket `web-mervin-cz-com` dříve existoval v jiném AWS účtu, musí být tam smazán (S3 názvy jsou globální).
4. (Volitelně) nastavte `CLOUDFRONT_ALIASES` pro vlastní doménu.
5. Spusťte **Actions → Bootstrap AWS → Run workflow**.

Bootstrap automaticky:
1. Vytvoří IAM uživatele `mervin-cz-deploy` s policy z [`docs/iam/mervin-cz-deploy-policy.json`](iam/mervin-cz-deploy-policy.json)
2. Vyžádá ACM certifikát (pokud jsou nastaveny aliasy) a vypíše DNS záznamy pro validaci
3. Vytvoří S3 bucket, CloudFront + OAC, rewrite funkci, bucket policy
4. Nahraje web
5. Nasadí upload Lambda + API Gateway
6. Commitne `src/data/aws-infra.json` a `src/data/upload-api.json`

### Po bootstrapu

1. V AWS Console vytvořte **access key** pro `mervin-cz-deploy`.
2. Uložte do GitHub Secrets jako `AWS_DEPLOY_ACCESS_KEY_ID` / `AWS_DEPLOY_SECRET_ACCESS_KEY`.
3. Zkopírujte z výstupu workflow do Variables: `CLOUDFRONT_DISTRIBUTION_ID`, `PUBLIC_UPLOAD_API_URL`.
4. **Deaktivujte** access key u `mervin-cz-bootstrap`.
5. Pokud bootstrap vyžádal ACM certifikát — přidejte DNS validační záznamy, počkejte na `ISSUED`, pak znovu spusťte Bootstrap (aktualizuje CloudFront).

## 5. Průběžný deploy

Po nastavení `AWS_DEPLOY_*` secrets:

- **push do `main`** → automaticky workflow **Deploy to AWS**
- nebo **Actions → Deploy to AWS → Run workflow**

Deploy pouze: sestaví web → nahraje na S3 → invaliduje CloudFront cache.

## 6. DNS

Nasměrujte `www.mervin-cz.com` a `mervin-cz.com` na CloudFront domain z `src/data/aws-infra.json` (např. `d3q9grbtf4hms1.cloudfront.net`).

## 7. Upload portal

Detailní popis: [`UPLOAD_SETUP.md`](UPLOAD_SETUP.md)

## Troubleshooting

| Chyba | Řešení |
|-------|--------|
| `expected AWS account 777171524899` | Secrets patří do jiného účtu — zkontrolujte `AWS_BOOTSTRAP_*` nebo `AWS_DEPLOY_*` |
| `BucketAlreadyExists` | Název bucketu drží jiný AWS účet — smažte bucket tam, nebo zvolte jiný název |
| `CloudFront distribution not found` | Spusťte **Bootstrap AWS** |
| `AccessDenied` při deployi | Zkontrolujte `AWS_DEPLOY_*` secrets a policy u `mervin-cz-deploy` |
| ACM certifikát `PENDING_VALIDATION` | Přidejte DNS CNAME z výstupu bootstrapu |
| Upload „Failed to fetch“ | Nastavte `PUBLIC_UPLOAD_API_URL` |

## Soubory

| Soubor | Účel |
|--------|------|
| `scripts/bootstrap-aws.sh` | Orchestrace bootstrapu |
| `scripts/setup-aws-infra.sh` | S3 + CloudFront |
| `scripts/setup-acm-certificate.sh` | ACM certifikát |
| `scripts/ensure-deploy-iam.sh` | IAM user deploy |
| `scripts/deploy-aws.sh` | Průběžný deploy |
| `src/data/aws-infra.json` | CloudFront ID, bucket (commitováno po bootstrapu) |
