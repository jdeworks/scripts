import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { renderSitemap, runSeo } from './seo.mjs';

const shell = (body) => `<!doctype html>
<html lang="en"><head>
  <!-- SEO:START -->
  <!-- SEO:END -->
</head><body>${body}</body></html>
`;

// --- Fixture 1: docs/ publish dir, nested trailing-slash routes (the file-viewer shape) ---
{
  const root = await mkdtemp(join(tmpdir(), 'pages-seo-'));
  const docs = join(root, 'docs');
  const child = join(docs, 'formats', 'csv');
  const configPath = join(root, 'seo.config.json');

  const config = {
    siteName: 'Fixture Viewer',
    baseUrl: 'https://example.test/viewer/',
    publishDir: 'docs',
    sitemap: 'sitemap.xml',
    pages: [
      {
        file: 'index.html',
        route: '',
        title: 'Fixture Viewer',
        description: 'Open fixture files locally in a browser.',
      },
      {
        file: 'formats/csv/index.html',
        route: 'formats/csv/',
        title: 'Fixture CSV Viewer',
        description: 'View fixture CSV tables locally in a browser.',
      },
    ],
  };

  try {
    await mkdir(child, { recursive: true });
    await writeFile(join(docs, 'index.html'), shell('<h1>Fixture Viewer</h1><a href="formats/csv/">CSV</a>'));
    await writeFile(join(child, 'index.html'), shell('<h1>CSV viewer</h1><a href="../../">Viewer</a>'));
    await writeFile(configPath, JSON.stringify(config, null, 2));

    const first = await runSeo({ configPath, write: true });
    assert.equal(first.changed, 3, 'first write updates both pages and the sitemap');
    const second = await runSeo({ configPath, write: true });
    assert.equal(second.changed, 0, 'SEO generation is idempotent');
    await runSeo({ configPath, write: false });

    const sitemap = await readFile(join(docs, 'sitemap.xml'), 'utf8');
    assert.match(sitemap, /https:\/\/example\.test\/viewer\/formats\/csv\//);
    assert.doesNotMatch(sitemap, /<lastmod>/, 'sitemap does not invent build-time lastmod values');
    assert.match(
      renderSitemap({ ...config, baseUrl: 'https://example.test/a&b/' }),
      /a&amp;b/,
      'sitemap URLs are XML escaped',
    );

    const csvPath = join(child, 'index.html');
    const csv = await readFile(csvPath, 'utf8');
    await writeFile(csvPath, csv.replace('</head>', '<meta name="robots" content="noindex"></head>'));
    await assert.rejects(
      runSeo({ configPath, write: false }),
      /contains noindex/,
      'declared indexable pages reject noindex',
    );
    await writeFile(csvPath, csv);

    const duplicated = structuredClone(config);
    duplicated.pages[1].description = duplicated.pages[0].description;
    await writeFile(configPath, JSON.stringify(duplicated, null, 2));
    await assert.rejects(
      runSeo({ configPath, write: false }),
      /description is not unique/,
      'page descriptions must be unique',
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

// --- Fixture 2: flat *.html routes (multi-page sites without directory routing) ---
{
  const root = await mkdtemp(join(tmpdir(), 'pages-seo-flat-'));
  const docs = join(root, 'docs');
  const configPath = join(root, 'seo.config.json');

  const config = {
    siteName: 'Fixture Flat',
    baseUrl: 'https://example.test/flat/',
    publishDir: 'docs',
    sitemap: 'sitemap.xml',
    pages: [
      {
        file: 'index.html',
        route: '',
        title: 'Fixture Flat Home',
        description: 'A flat-file fixture site home page.',
      },
      {
        file: 'analyzer.html',
        route: 'analyzer.html',
        title: 'Fixture Flat Analyzer',
        description: 'A flat-file fixture analyzer page.',
      },
    ],
  };

  try {
    await mkdir(docs, { recursive: true });
    await writeFile(join(docs, 'index.html'), shell('<h1>Flat home</h1><a href="analyzer.html">Analyzer</a>'));
    await writeFile(join(docs, 'analyzer.html'), shell('<h1>Analyzer</h1><a href="./">Home</a>'));
    await writeFile(configPath, JSON.stringify(config, null, 2));

    await runSeo({ configPath, write: true });
    await runSeo({ configPath, write: false });

    const analyzer = await readFile(join(docs, 'analyzer.html'), 'utf8');
    assert.match(
      analyzer,
      /<link rel="canonical" href="https:\/\/example\.test\/flat\/analyzer\.html">/,
      '.html routes produce .html canonicals',
    );
    const sitemap = await readFile(join(docs, 'sitemap.xml'), 'utf8');
    assert.match(sitemap, /https:\/\/example\.test\/flat\/analyzer\.html/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

// --- Fixture 3: publishDir "." (site published from the repo root, e.g. a user site) ---
{
  const root = await mkdtemp(join(tmpdir(), 'pages-seo-root-'));
  const configPath = join(root, 'seo.config.json');

  const config = {
    siteName: 'Fixture Root',
    baseUrl: 'https://example.test/',
    publishDir: '.',
    sitemap: 'sitemap.xml',
    pages: [
      {
        file: 'index.html',
        route: '',
        title: 'Fixture Root Site',
        description: 'A fixture site published from the repository root.',
      },
    ],
  };

  try {
    await writeFile(join(root, 'index.html'), shell('<h1>Root site</h1>'));
    await writeFile(configPath, JSON.stringify(config, null, 2));

    await runSeo({ configPath, write: true });
    await runSeo({ configPath, write: false });

    const html = await readFile(join(root, 'index.html'), 'utf8');
    assert.match(html, /<link rel="canonical" href="https:\/\/example\.test\/">/, 'root-published site gets host-root canonical');
    const sitemap = await readFile(join(root, 'sitemap.xml'), 'utf8');
    assert.match(sitemap, /<loc>https:\/\/example\.test\/<\/loc>/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

console.log('pages-seo generator and published-page checks passed');
