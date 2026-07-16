#!/usr/bin/env node
// Deterministic SEO metadata + sitemap maintenance for a published static site
// (GitHub Pages or any static host). Visible page copy is always hand-authored;
// this script only owns the marker-delimited <head> block and the sitemap.
// Originated in jdeworks/file-viewer (scripts/seo.mjs), generalized for any repo:
//   node seo.mjs (--write | --check) --config /path/to/site/seo.config.json
import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export const SEO_START = '<!-- SEO:START -->';
export const SEO_END = '<!-- SEO:END -->';

function htmlEscape(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

function xmlEscape(value) {
  return htmlEscape(value).replaceAll("'", '&apos;');
}

function canonicalUrl(config, page) {
  return new URL(page.route, config.baseUrl).href;
}

function validateConfig(config) {
  const errors = [];
  let base;
  try {
    base = new URL(config.baseUrl);
  } catch {
    errors.push('baseUrl must be an absolute URL');
  }
  if (base && (base.protocol !== 'https:' || !base.pathname.endsWith('/'))) {
    errors.push('baseUrl must use HTTPS and end with /');
  }
  if (!config.siteName?.trim()) errors.push('siteName is required');
  if (!config.publishDir?.trim()) errors.push('publishDir is required');
  if (!config.sitemap?.trim() || config.sitemap.startsWith('/') || config.sitemap.includes('..')) {
    errors.push('sitemap must be a safe path inside publishDir');
  }
  if (!Array.isArray(config.pages) || config.pages.length === 0) errors.push('pages must not be empty');

  const files = new Set();
  const routes = new Set();
  const titles = new Set();
  const descriptions = new Set();
  for (const [index, page] of (config.pages || []).entries()) {
    const label = `pages[${index}]`;
    if (!page.file || page.file.startsWith('/') || page.file.includes('..') || !page.file.endsWith('.html')) {
      errors.push(`${label}.file must be a safe HTML path inside publishDir`);
    } else if (files.has(page.file)) {
      errors.push(`${label}.file duplicates ${page.file}`);
    }
    files.add(page.file);

    if (typeof page.route !== 'string' || page.route.startsWith('/') || page.route.includes('..') ||
        page.route.includes('?') || page.route.includes('#') ||
        (page.route && !page.route.endsWith('/') && !page.route.endsWith('.html'))) {
      errors.push(`${label}.route must be empty, a safe trailing-slash path, or a safe *.html path relative to baseUrl`);
    } else if (routes.has(page.route)) {
      errors.push(`${label}.route duplicates ${page.route}`);
    }
    routes.add(page.route);

    if (!page.title?.trim()) errors.push(`${label}.title is required`);
    else if (titles.has(page.title)) errors.push(`${label}.title is not unique`);
    titles.add(page.title);

    if (!page.description?.trim()) errors.push(`${label}.description is required`);
    else if (descriptions.has(page.description)) errors.push(`${label}.description is not unique`);
    descriptions.add(page.description);

    if (base && typeof page.route === 'string') {
      const canonical = canonicalUrl(config, page);
      if (!canonical.startsWith(config.baseUrl)) errors.push(`${label}.route escapes baseUrl`);
      if (page.schema?.url && page.schema.url !== canonical) errors.push(`${label}.schema.url must equal its canonical URL`);
    }
  }
  if (config.pages?.[0]?.route !== '') errors.push('the first page must be the site root (route "")');
  return errors;
}

export function renderHeadBlock(config, page) {
  const canonical = canonicalUrl(config, page);
  const title = htmlEscape(page.title);
  const description = htmlEscape(page.description);
  const lines = [
    SEO_START,
    `<title>${title}</title>`,
    `<meta name="description" content="${description}">`,
    '<meta name="robots" content="index,follow,max-image-preview:large,max-snippet:-1,max-video-preview:-1">',
    `<link rel="canonical" href="${htmlEscape(canonical)}">`,
    '<meta property="og:type" content="website">',
    `<meta property="og:site_name" content="${htmlEscape(config.siteName)}">`,
    `<meta property="og:title" content="${title}">`,
    `<meta property="og:description" content="${description}">`,
    `<meta property="og:url" content="${htmlEscape(canonical)}">`,
  ];
  if (page.image) {
    lines.push(`<meta property="og:image" content="${htmlEscape(new URL(page.image, config.baseUrl).href)}">`);
  }
  lines.push(
    `<meta name="twitter:card" content="${page.image ? 'summary_large_image' : 'summary'}">`,
    `<meta name="twitter:title" content="${title}">`,
    `<meta name="twitter:description" content="${description}">`,
  );
  if (page.image) {
    lines.push(`<meta name="twitter:image" content="${htmlEscape(new URL(page.image, config.baseUrl).href)}">`);
  }
  if (page.schema) {
    lines.push('<script type="application/ld+json">');
    lines.push(...JSON.stringify(page.schema, null, 2).replaceAll('<', '\\u003c').split('\n'));
    lines.push('</script>');
  }
  lines.push(SEO_END);
  return lines.map((line) => `  ${line}`).join('\n');
}

export function applyHeadBlock(html, config, page) {
  const pattern = /[ \t]*<!-- SEO:START -->[\s\S]*?[ \t]*<!-- SEO:END -->/g;
  const matches = html.match(pattern) || [];
  if (matches.length !== 1) throw new Error(`${page.file}: expected exactly one SEO marker block, found ${matches.length}`);
  return html.replace(pattern, renderHeadBlock(config, page));
}

export function renderSitemap(config) {
  const urls = config.pages.map((page) => `  <url>\n    <loc>${xmlEscape(canonicalUrl(config, page))}</loc>\n  </url>`);
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    ...urls,
    '</urlset>',
    '',
  ].join('\n');
}

function anchorHrefs(html) {
  return [...html.matchAll(/<a\b[^>]*\bhref\s*=\s*["']([^"']+)["']/gi)].map((match) => match[1]);
}

function robotsNoindex(html) {
  return /<meta\b[^>]*\bname=["']robots["'][^>]*\bcontent=["'][^"']*\bnoindex\b/iu.test(html) ||
    /<meta\b[^>]*\bcontent=["'][^"']*\bnoindex\b[^>]*\bname=["']robots["']/iu.test(html);
}

async function auditPublished(config, configDir, { requireFresh = true } = {}) {
  const errors = validateConfig(config);
  if (errors.length) return errors;
  const publishDir = resolve(configDir, config.publishDir);
  const pagesByUrl = new Map();

  for (const page of config.pages) {
    const canonical = canonicalUrl(config, page);
    const path = resolve(publishDir, page.file);
    let html;
    try {
      html = await readFile(path, 'utf8');
    } catch (error) {
      errors.push(`${page.file}: cannot read published page (${error.code || error.message})`);
      continue;
    }

    let generated;
    try {
      generated = applyHeadBlock(html, config, page);
    } catch (error) {
      errors.push(error.message);
      continue;
    }
    if (requireFresh && generated !== html) errors.push(`${page.file}: generated SEO block is stale; run seo.mjs --write`);

    const h1s = [...html.matchAll(/<h1(?:\s|>)/gi)].length;
    if (h1s !== 1) errors.push(`${page.file}: expected exactly one authored h1, found ${h1s}`);
    if (robotsNoindex(html)) errors.push(`${page.file}: indexable page contains noindex`);

    const canonicalMatches = [...html.matchAll(/<link\b[^>]*\brel=["']canonical["'][^>]*\bhref=["']([^"']+)["']/gi)];
    if (canonicalMatches.length !== 1 || canonicalMatches[0][1] !== canonical) {
      errors.push(`${page.file}: expected one canonical link to ${canonical}`);
    }
    pagesByUrl.set(canonical, { page, html });
  }

  if (pagesByUrl.size === config.pages.length) {
    const start = canonicalUrl(config, config.pages[0]);
    const reached = new Set([start]);
    const queue = [start];
    while (queue.length) {
      const current = queue.shift();
      const entry = pagesByUrl.get(current);
      for (const href of anchorHrefs(entry.html)) {
        let target;
        try {
          target = new URL(href, current);
        } catch {
          continue;
        }
        target.hash = '';
        const normalized = target.href;
        if (pagesByUrl.has(normalized) && !reached.has(normalized)) {
          reached.add(normalized);
          queue.push(normalized);
        }
      }
    }
    for (const [url, { page }] of pagesByUrl) {
      if (!reached.has(url)) errors.push(`${page.file}: page is not reachable by static links from ${config.baseUrl}`);
    }
  }

  const sitemapPath = resolve(publishDir, config.sitemap);
  let currentSitemap = '';
  try {
    currentSitemap = await readFile(sitemapPath, 'utf8');
  } catch (error) {
    if (requireFresh) errors.push(`${config.sitemap}: cannot read generated sitemap (${error.code || error.message})`);
  }
  if (requireFresh && currentSitemap && currentSitemap !== renderSitemap(config)) {
    errors.push(`${config.sitemap}: generated sitemap is stale; run seo.mjs --write`);
  }
  return errors;
}

export async function runSeo({ configPath = 'seo.config.json', write = false } = {}) {
  const absoluteConfig = resolve(configPath);
  const configDir = dirname(absoluteConfig);
  const config = JSON.parse(await readFile(absoluteConfig, 'utf8'));
  const configErrors = validateConfig(config);
  if (configErrors.length) throw new Error(configErrors.join('\n'));

  let changed = 0;
  if (write) {
    const publishDir = resolve(configDir, config.publishDir);
    for (const page of config.pages) {
      const path = resolve(publishDir, page.file);
      const html = await readFile(path, 'utf8');
      const next = applyHeadBlock(html, config, page);
      if (next !== html) {
        await writeFile(path, next);
        changed++;
      }
    }
    const sitemapPath = resolve(publishDir, config.sitemap);
    const nextSitemap = renderSitemap(config);
    let previous = '';
    try { previous = await readFile(sitemapPath, 'utf8'); } catch { /* first generation */ }
    if (nextSitemap !== previous) {
      await writeFile(sitemapPath, nextSitemap);
      changed++;
    }
  }

  const errors = await auditPublished(config, configDir);
  if (errors.length) throw new Error(errors.join('\n'));
  return { changed, pages: config.pages.length };
}

const isCli = process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url;
if (isCli) {
  const write = process.argv.includes('--write');
  const check = process.argv.includes('--check');
  const configIndex = process.argv.indexOf('--config');
  const configPath = configIndex >= 0 ? process.argv[configIndex + 1] : 'seo.config.json';
  if (write === check) {
    console.error('Usage: node seo.mjs (--write | --check) [--config path]');
    process.exitCode = 2;
  } else {
    try {
      const result = await runSeo({ configPath, write });
      console.log(write
        ? `SEO artifacts ready: ${result.pages} pages, ${result.changed} file(s) updated.`
        : `SEO artifacts valid: ${result.pages} indexable pages.`);
    } catch (error) {
      console.error(`SEO validation failed:\n${error.message}`);
      process.exitCode = 1;
    }
  }
}
