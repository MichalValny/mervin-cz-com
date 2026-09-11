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

Účet `777171524899`, bucket `web-mervin-cz-com`, region `us-east-1`.

Kompletní návod: [`docs/AWS_SETUP.md`](docs/AWS_SETUP.md)

| Krok | Workflow | IAM user |
|------|----------|----------|
| **První setup** (S3, CloudFront, ACM, Lambda) | Actions → **Bootstrap AWS** | `mervin-cz-bootstrap` |
| **Aktualizace webu** (push do `main`) | **Deploy to AWS** | `mervin-cz-deploy` |

Lokální PC není potřeba — vše přes GitHub Actions.

## Struktura

- `src/data/` – JSON data (příspěvky, kategorie)
- `src/pages/` – stránky webu
- `src/components/` – komponenty (galerie, karty, sidebar)
- `scripts/scrape-content.py` – scraper obsahu z WordPressu
