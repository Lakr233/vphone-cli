// Builds the site's docs/ folder from the repository's own Markdown.
//
// Documents/ stays the only source: GitHub renders it as is, and this script
// copies it into the layout Rspress expects. It maps every page to a route,
// rewrites links between pages to those routes and links to anything else in
// the repository to GitHub, copies the images pages use, and turns the
// sections of Documents/README.md into the sidebar.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const siteRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = path.resolve(siteRoot, '..');
const outRoot = path.join(siteRoot, 'docs');
const githubBlob = 'https://github.com/Lakr233/vphone-cli/blob/main/';
const githubTree = 'https://github.com/Lakr233/vphone-cli/tree/main/';
const documentsIndex = 'Documents/README.md';

// MARK: - Pages

/** Repository-relative Markdown path -> site route (without extension). */
const pages = new Map([
  ['README.md', '/guide/introduction'],
  ['Documents/Downloads/README.md', '/guide/downloads'],
  ['Documents/README_zh.md', '/zh/'],
  ['Documents/README_ja.md', '/ja/'],
  ['Documents/README_ko.md', '/ko/'],
]);
for (const name of fs.readdirSync(path.join(repoRoot, 'Documents/Guides')).sort()) {
  if (name.endsWith('.md')) {
    pages.set(`Documents/Guides/${name}`, `/guide/${name.replace(/\.md$/, '')}`);
  }
}
// The contributors section of the documents index becomes a page of its own.
const contributingRoute = '/guide/contributing';

function routeFile(route) {
  return path.join(outRoot, route.endsWith('/') ? `${route}index.md` : `${route}.md`);
}

// MARK: - Links

const images = new Set();

function resolveTarget(fromFile, target) {
  const [rawPath, anchor] = target.split('#');
  const absolute = rawPath
    ? path.resolve(path.dirname(path.join(repoRoot, fromFile)), decodeURI(rawPath))
    : path.join(repoRoot, fromFile);
  return { repoPath: path.relative(repoRoot, absolute).split(path.sep).join('/'), anchor };
}

function rewriteTarget(fromFile, target) {
  if (/^[a-z][a-z0-9+.-]*:/i.test(target) || target.startsWith('#') || target.startsWith('/')) {
    return target;
  }
  const { repoPath, anchor } = resolveTarget(fromFile, target);
  const suffix = anchor ? `#${anchor}` : '';
  if (repoPath === documentsIndex) {
    return anchor === 'for-contributors' ? contributingRoute : '/guide/introduction#documentation';
  }
  if (pages.has(repoPath)) {
    return pages.get(repoPath) + suffix;
  }
  if (/\.(png|jpe?g|gif|svg|webp)$/i.test(repoPath)) {
    images.add(repoPath);
    return `/images/${repoPath}`;
  }
  const absolute = path.join(repoRoot, repoPath);
  const isDirectory = fs.existsSync(absolute) && fs.statSync(absolute).isDirectory();
  return (isDirectory ? githubTree : githubBlob) + repoPath + suffix;
}

/** Rewrites Markdown and HTML link targets outside fenced code. */
function rewriteLinks(fromFile, text) {
  let inFence = false;
  return text
    .split('\n')
    .map((line) => {
      if (/^\s*```/.test(line)) {
        inFence = !inFence;
        return line;
      }
      if (inFence) {
        return line;
      }
      return line
        .replace(/(\]\()([^)\s]+)(\))/g, (_, open, target, close) => open + rewriteTarget(fromFile, target) + close)
        .replace(/((?:href|src)=")([^"]+)(")/g, (_, open, target, close) => open + rewriteTarget(fromFile, target) + close);
    })
    .join('\n');
}

// MARK: - Page bodies

/** GitHub alerts (`> [!WARNING]`) become Rspress containers. */
function convertAlerts(text) {
  return text.replace(/^> \[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\n((?:>.*\n?)*)/gm, (_, kind, body) => {
    const type = { NOTE: 'info', TIP: 'tip', IMPORTANT: 'warning', WARNING: 'warning', CAUTION: 'danger' }[kind];
    const content = body.replace(/^> ?/gm, '').trimEnd();
    return `:::${type}\n${content}\n:::\n`;
  });
}

/** Drops what the site's own chrome replaces: language switchers and breadcrumbs. */
function dropRepositoryChrome(text) {
  return text
    .replace(/^<div align="right">.*<\/div>\n+/m, '')
    .replace(/^\[Documentation\]\([^)]*\)( · .*)?\n+/m, '');
}

function writePage(route, body) {
  const file = routeFile(route);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, body);
}

// MARK: - Sidebar

function titleOf(text) {
  return /^# (.+)$/m.exec(text)?.[1].trim();
}

/** The `## Section` tables of Documents/README.md, as Rspress sidebar groups. */
function sidebarFromIndex(indexText) {
  const groups = [];
  let current;
  for (const line of indexText.split('\n')) {
    const heading = /^## (.+)$/.exec(line);
    if (heading) {
      current = { text: heading[1].trim(), items: [] };
      groups.push(current);
      continue;
    }
    const row = /^\| \[([^\]]+)\]\(([^)]+)\) \|/.exec(line);
    if (current && row) {
      const { repoPath } = resolveTarget(documentsIndex, row[2]);
      if (pages.has(repoPath)) {
        current.items.push({ text: row[1], link: pages.get(repoPath) });
      }
    }
  }
  return groups.filter((group) => group.items.length > 0);
}

// MARK: - Run

fs.rmSync(outRoot, { recursive: true, force: true });
fs.mkdirSync(outRoot, { recursive: true });

for (const [source, route] of pages) {
  const text = fs.readFileSync(path.join(repoRoot, source), 'utf8');
  // The translated overviews are single pages outside the English sidebar.
  const frontmatter = route.startsWith('/guide/') ? '' : '---\nsidebar: false\n---\n\n';
  writePage(route, frontmatter + rewriteLinks(source, convertAlerts(dropRepositoryChrome(text))));
}

const indexText = fs.readFileSync(path.join(repoRoot, documentsIndex), 'utf8');
const contributors = /^## For Contributors\n([\s\S]*?)(?=^## |(?![\s\S]))/m.exec(indexText);
if (!contributors) {
  throw new Error(`${documentsIndex} has no "## For Contributors" section`);
}
writePage(contributingRoute, rewriteLinks(documentsIndex, `# Contributing\n\n${contributors[1].trim()}\n`));

for (const image of images) {
  const destination = path.join(outRoot, 'public/images', image);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(path.join(repoRoot, image), destination);
}

const sidebar = [
  { text: 'Overview', items: [{ text: 'Introduction', link: '/guide/introduction' }] },
  ...sidebarFromIndex(indexText),
  { text: 'Project', items: [{ text: 'Contributing', link: contributingRoute }] },
];
const listed = new Set(sidebar.flatMap((group) => group.items.map((item) => item.link)));
const unlisted = [...pages].filter(([source, route]) => route.startsWith('/guide/') && !listed.has(route));
if (unlisted.length > 0) {
  throw new Error(`Pages missing from ${documentsIndex}: ${unlisted.map(([source]) => source).join(', ')}`);
}
fs.writeFileSync(path.join(outRoot, 'sidebar.json'), `${JSON.stringify(sidebar, null, 2)}\n`);
fs.copyFileSync(path.join(siteRoot, 'theme/home.md'), path.join(outRoot, 'index.md'));

console.log(`synced ${pages.size + 1} pages, ${images.size} images, ${sidebar.length} sidebar groups`);
