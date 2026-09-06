# mervin-cz.com

Moderní redesign webu [mervin-cz.com](https://www.mervin-cz.com/) – Mervinovy stránky o motorkách, kolech, cestování a společných akcích.

## Technologie

- [Astro](https://astro.build/) – statický generátor
- Obsah stažen z WordPress REST API
- Galerie přes [Google Photos / publicalbum.org](https://publicalbum.org/) – stejný způsob jako původní web
- Ilustrační obrázky z původního webu (mervin-cz.com)

## Vývoj

```bash
npm install
npm run dev
```

## Build

```bash
npm run build
npm run preview
```

## Aktualizace obsahu

Pro stažení nejnovějších příspěvků z WordPressu:

```bash
npm run scrape
```

## Nasazení na AWS (S3 + CloudFront)

Bucket: `mervin-cz-com` (region `us-east-1`)

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-east-1
# volitelně pro vlastní doménu:
# export ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:...
# export CLOUDFRONT_ALIASES=www.mervin-cz.com,mervin-cz.com

chmod +x scripts/deploy-aws.sh
./scripts/deploy-aws.sh
```

Skript:
1. sestaví statický web (`npm run build`)
2. nahraje soubory do S3 s cache hlavičkami
3. vytvoří nebo použije CloudFront distribuci s OAC
4. spustí invalidaci cache

Alternativně lze nasadit přes GitHub Actions workflow `.github/workflows/deploy-aws.yml` se secrets `AWS_ACCESS_KEY_ID` a `AWS_SECRET_ACCESS_KEY`.

## Struktura

- `src/data/` – JSON data (příspěvky, kategorie)
- `src/pages/` – stránky webu
- `src/components/` – komponenty (galerie, karty, sidebar)
- `scripts/scrape-content.py` – scraper obsahu z WordPressu
