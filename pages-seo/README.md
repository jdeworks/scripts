# pages-seo

Deterministic SEO metadata + sitemap generator/checker for static sites (GitHub Pages
or any static host). Zero dependencies, plain Node ESM, no build step.

Originated in [`jdeworks/file-viewer`](https://github.com/jdeworks/file-viewer)
(`scripts/seo.mjs`) — file-viewer still vendors its own copy because its CI gate must
not depend on a sibling checkout. This copy is the canonical, generalized version for
every other site.

## What it owns (and what it never touches)

The tool owns exactly two things per site:

1. A marker-delimited block inside each configured page's `<head>`:

   ```html
   <!-- SEO:START -->
   ...title, description, robots, canonical, og:*, twitter:*, JSON-LD...
   <!-- SEO:END -->
   ```

2. The sitemap file (`<loc>`-only entries, one per configured page).

Visible page copy is always hand-authored — the tool never rewrites anything outside
the markers. Each page must contain **exactly one** (empty or previously generated)
marker block before the first `--write`.

## Usage

```sh
node seo.mjs --write --config /path/to/site/seo.config.json   # regenerate blocks + sitemap
node seo.mjs --check --config /path/to/site/seo.config.json   # validate, no writes (CI gate)
```

`publishDir` is resolved relative to the config file, so the tool runs from any cwd.

Check all sites at once:

```sh
for c in ~/repos/{think-tank,dead-data-cleaner-poc,anvil-poc,auto-audiobook,get-me-started,make-it-look-good,noodle-jump,elemental-surprise,jdeworks}/seo.config.json; do
  node ~/repos/scripts/pages-seo/seo.mjs --check --config "$c" || echo "FAILED: $c"
done
```

## Config contract (`seo.config.json` at the site repo root)

```jsonc
{
  "siteName": "My Site",                            // og:site_name
  "baseUrl": "https://user.github.io/repo/",        // HTTPS, must end with /
  "publishDir": "docs",                             // relative to this config file; "." for root-published sites
  "sitemap": "sitemap.xml",                         // path inside publishDir
  "pages": [
    {
      "file": "index.html",                         // path inside publishDir
      "route": "",                                  // "" (root), "sub/dir/", or "flat.html"
      "title": "Unique Page Title",
      "description": "Unique page description.",
      "image": "og.png",                            // optional; resolves against baseUrl; upgrades twitter:card to summary_large_image
      "schema": { "@context": "https://schema.org", "@type": "WebApplication", "url": "<must equal the canonical>" }  // optional JSON-LD
    }
  ]
}
```

Rules enforced by `--check` (and after every `--write`):

- The first page must be the site root (`route: ""`).
- Titles and descriptions must be unique across the config.
- Every page: generated block is fresh, exactly one canonical (matching
  `baseUrl + route`), exactly one `<h1>`, no `noindex`.
- Sitemap matches the config exactly.

## Two contracts that bite if you don't know them

- **Static reachability (BFS):** every configured page must be reachable via plain
  `<a href>` links starting from the root page. Adding a page to the config without
  linking it from an already-reachable page fails `--check` with
  "page is not reachable by static links". Link it (footer links count) before
  configuring it.
- **The `<h1>` audit is a raw-HTML regex:** inline `<script>` source that contains
  `<h1>` strings is counted as a heading. Keep heading markup out of inline script
  literals on configured pages (or build such strings dynamically).

## Vite / built-output sites

If `publishDir` is build output (e.g. Vite `outDir: "docs"`), the markers and any
static artifacts must also live where the build sources them, or the next build wipes
the SEO work:

- Put the marker block (ideally the *filled* block — its URLs are absolute, so it is
  build-safe) in the source template (root `index.html`).
- Put `sitemap.xml` / `404.html` copies in `public/`.
- After any rebuild, rerun `--write` and treat `--check` as the drift gate.

## Test

```sh
node seo.test.mjs
```
