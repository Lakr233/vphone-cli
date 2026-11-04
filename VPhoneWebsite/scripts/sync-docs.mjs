// Builds the site's docs/ folder from the repository's own Markdown.
//
// The repository stays the only source: GitHub renders it as is, and this
// script copies it into the layout Rspress expects.
//
// - Documents/<lang>/ is the user manual, one identical tree per language.
//   English pages are served without a prefix, the others under /<lang>/.
//   The `## Section` tables of each Documents/<lang>/README.md are the sidebar.
// - Research/ is served untranslated under /research/; its sidebar follows
//   the folders.
// - theme/home/<lang>.md are the home pages.
//
// Links between pages become site routes, images are copied, and links to
// anything else in the repository point to GitHub.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { bundledLanguages, bundledLanguagesAlias } from 'shiki';

const siteRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = path.resolve(siteRoot, '..');
const outRoot = path.join(siteRoot, 'docs');
const githubBlob = 'https://github.com/Lakr233/vphone-cli/blob/main/';
const githubTree = 'https://github.com/Lakr233/vphone-cli/tree/main/';
const siteURL = 'https://lakr233.github.io/vphone-cli/';

export const languages = ['en', 'zh', 'ja', 'ko'];
const defaultLanguage = 'en';

// MARK: - Pages

function walk(directory) {
  const absolute = path.join(repoRoot, directory);
  return fs
    .readdirSync(absolute, { withFileTypes: true })
    .sort((a, b) => a.name.localeCompare(b.name))
    .flatMap((entry) => {
      const child = `${directory}/${entry.name}`;
      if (entry.isDirectory()) {
        return walk(child);
      }
      return entry.name.endsWith('.md') ? [child] : [];
    });
}

function prefix(language) {
  return language === defaultLanguage ? '' : `/${language}`;
}

/** Repository-relative Markdown path -> { route, language }. */
const pages = new Map();

for (const language of languages) {
  for (const source of walk(`Documents/${language}`)) {
    const relative = source.slice(`Documents/${language}/`.length).replace(/\.md$/, '');
    const route = relative === 'README' ? `${prefix(language)}/` : `${prefix(language)}/${relative}`;
    pages.set(source, { route, language });
  }
}
for (const source of walk('Research')) {
  const relative = source.slice('Research/'.length).replace(/\.md$/, '');
  const route = relative === 'README' ? '/research/' : `/research/${relative.replace(/(^|\/)README$/, '$1')}`;
  pages.set(source, { route, language: defaultLanguage });
}

/** The output file of a route; the default language lives in docs/en/. */
function routeFile(route, language) {
  const local = language === defaultLanguage ? route : route.slice(language.length + 1);
  const relative = local.endsWith('/') ? `${local}index.md` : `${local}.md`;
  return path.join(outRoot, language, relative);
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
  if (pages.has(repoPath)) {
    const page = pages.get(repoPath);
    // Rspress resolves links on a translated page inside that language, and the
    // research notes exist only in English, so those links leave the locale.
    const fromLanguage = pages.get(fromFile)?.language ?? defaultLanguage;
    if (page.language !== fromLanguage) {
      return siteURL + page.route.slice(1) + suffix;
    }
    return page.route + suffix;
  }
  if (/\.(png|jpe?g|gif|svg|webp)$/i.test(repoPath) && fs.existsSync(path.join(repoRoot, repoPath))) {
    images.add(repoPath);
    return `/images/${repoPath}`;
  }
  const absolute = path.join(repoRoot, repoPath);
  const isDirectory = fs.existsSync(absolute) && fs.statSync(absolute).isDirectory();
  return encodeURI((isDirectory ? githubTree : githubBlob) + repoPath) + suffix;
}

/** Rewrites Markdown and HTML link targets outside code. */
function rewriteLinks(fromFile, text) {
  return mapOutsideCode(text, (prose) =>
    prose
      .replace(/(\]\()(<[^>]+>|[^)\s]+)((?:\s+"[^"]*")?\))/g, (_, open, target, close) => {
        const bare = target.replace(/^<|>$/g, '');
        return open + rewriteTarget(fromFile, bare) + close;
      })
      .replace(/^(\[[^\]]+\]:\s*)(\S+)/gm, (_, open, target) => open + rewriteTarget(fromFile, target))
      .replace(/((?:href|src)=")([^"]+)(")/g, (_, open, target, close) => open + rewriteTarget(fromFile, target) + close),
  );
}

/**
 * Applies `transform` to the text outside fenced code blocks and inline code
 * spans. Inline spans may wrap onto the next line, so the text between fences
 * is handled a paragraph at a time.
 */
function mapOutsideCode(text, transform) {
  const output = [];
  let prose = [];
  let fence = null;
  const flush = () => {
    if (prose.length > 0) {
      output.push(...prose.join('\n').split(/(\n[ \t]*\n)/).map((chunk) => mapProse(chunk, transform)).join('').split('\n'));
      prose = [];
    }
  };
  for (const line of text.split('\n')) {
    const marker = /^\s*(`{3,}|~{3,})/.exec(line);
    if (fence || marker) {
      flush();
      if (marker && !fence) {
        fence = marker[1];
      } else if (marker && marker[1][0] === fence[0] && marker[1].length >= fence.length) {
        fence = null;
      }
      output.push(line);
    } else {
      prose.push(line);
    }
  }
  flush();
  return output.join('\n');
}

/** Splits one paragraph on inline code spans (a run of backticks closed by an equal run). */
function mapProse(paragraph, transform) {
  let result = '';
  let plain = '';
  let index = 0;
  while (index < paragraph.length) {
    const run = /^`+/.exec(paragraph.slice(index));
    if (run) {
      const closing = new RegExp(`(?<!\`)${run[0]}(?!\`)`, 'g');
      closing.lastIndex = index + run[0].length;
      const close = closing.exec(paragraph);
      if (close) {
        result += transform(plain) + paragraph.slice(index, close.index + run[0].length);
        plain = '';
        index = close.index + run[0].length;
        continue;
      }
      plain += run[0];
      index += run[0].length;
      continue;
    }
    plain += paragraph[index];
    index += 1;
  }
  return result + transform(plain);
}

// MARK: - Page bodies

/** Code fences in a language Shiki does not know fail the build; they become plain text. */
const fenceAliases = { plist: 'xml', entitlements: 'xml', zsh: 'sh', asm: 'asm', objc: 'objective-c' };

function normalizeFences(text) {
  return text.replace(/^(\s*(?:`{3,}|~{3,}))([^\s`{]+)(.*)$/gm, (line, fence, language, rest) => {
    const lower = language.toLowerCase();
    const mapped = fenceAliases[lower] ?? lower;
    const known = mapped in bundledLanguages || mapped in bundledLanguagesAlias;
    return `${fence}${known ? mapped : 'text'}${rest}`;
  });
}

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
    .replace(/^\[[^\]]+\]\([^)]*\)( · \[[^\]]+\]\([^)]*\))*\n+(?=#|\S)/, '');
}

/**
 * Research notes are plain Markdown written for GitHub. Rspress compiles
 * pages as MDX, so characters MDX treats as syntax are escaped outside code:
 * braces, `<` that does not open a known HTML tag, and HTML comments.
 */
const htmlTags = new Set([
  'a', 'b', 'br', 'code', 'details', 'div', 'em', 'i', 'img', 'kbd', 'li', 'ol', 'p', 'pre', 'span',
  'strong', 'sub', 'summary', 'sup', 'table', 'tbody', 'td', 'th', 'thead', 'tr', 'u', 'ul',
]);

function escapeForMdx(text) {
  return mapOutsideCode(text.replace(/<!--[\s\S]*?-->/g, ''), (part) =>
    part
      .replace(/<((?:https?|mailto):[^>\s]+)>/g, '[$1]($1)')
      .replace(/[{}]/g, (brace) => `\\${brace}`)
      .replace(/<(\/?)([^>\s/]*)/g, (match, slash, name) => (htmlTags.has(name.toLowerCase()) ? match : `&lt;${slash}${name}`))
      .replace(/<(img|br)\b([^>]*?)\s*\/?>/gi, '<$1$2 />'),
  );
}

function writeFile(file, body) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, body);
}

function titleOf(text) {
  return /^# (.+)$/m.exec(text)?.[1].trim().replace(/`/g, '');
}

// MARK: - Sidebars

/** The `## Section` tables of a manual index, as Rspress sidebar groups. */
function manualSidebar(indexSource) {
  const indexText = fs.readFileSync(path.join(repoRoot, indexSource), 'utf8');
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
      const { repoPath } = resolveTarget(indexSource, row[2]);
      if (!pages.has(repoPath)) {
        throw new Error(`${indexSource} links to ${row[2]}, which is not a manual page`);
      }
      current.items.push({ text: row[1], link: pages.get(repoPath).route });
    }
  }
  return groups.filter((group) => group.items.length > 0);
}

/** Research folders, as collapsed sidebar groups titled by their notes' headings. */
function researchSidebar(titles) {
  const groups = new Map();
  for (const [source, { route }] of pages) {
    if (!source.startsWith('Research/') || source === 'Research/README.md') {
      continue;
    }
    const parts = source.slice('Research/'.length).split('/');
    const group = parts.length > 1 ? parts.slice(0, -1).join(' / ') : 'General';
    if (!groups.has(group)) {
      groups.set(group, []);
    }
    groups.get(group).push({ text: titles.get(source) ?? parts.at(-1), link: route });
  }
  const ordered = [...groups].sort(([a], [b]) => (a === 'General' ? -1 : b === 'General' ? 1 : a.localeCompare(b)));
  return [
    { text: 'Research', items: [{ text: 'Index', link: '/research/' }] },
    ...ordered.map(([text, items]) => ({ text, collapsible: true, collapsed: true, items })),
  ];
}

// MARK: - Run

fs.rmSync(outRoot, { recursive: true, force: true });

const titles = new Map();
for (const [source, { route, language }] of pages) {
  const raw = fs.readFileSync(path.join(repoRoot, source), 'utf8');
  titles.set(source, titleOf(raw));
  let body = rewriteLinks(source, convertAlerts(dropRepositoryChrome(normalizeFences(raw))));
  if (source.startsWith('Research/')) {
    body = escapeForMdx(body);
  }
  // A manual index is the sidebar on the site, not a page of its own.
  const isManualIndex = source.startsWith('Documents/') && source.endsWith('/README.md');
  if (!isManualIndex) {
    writeFile(routeFile(route, language), body);
  }
}

for (const language of languages) {
  const home = path.join(siteRoot, 'theme/home', `${language}.md`);
  fs.copyFileSync(home, routeFile(`${prefix(language)}/`, language));
}

for (const image of images) {
  const destination = path.join(outRoot, 'public/images', image);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(path.join(repoRoot, image), destination);
}

const sidebars = { research: researchSidebar(titles) };
for (const language of languages) {
  const index = `Documents/${language}/README.md`;
  const sidebar = manualSidebar(index);
  const listed = new Set(sidebar.flatMap((group) => group.items.map((item) => item.link)));
  const unlisted = [...pages]
    .filter(([source, page]) => page.language === language && source.startsWith(`Documents/${language}/`))
    .filter(([source, page]) => source !== index && !listed.has(page.route));
  if (unlisted.length > 0) {
    throw new Error(`Pages missing from ${index}: ${unlisted.map(([source]) => source).join(', ')}`);
  }
  sidebars[language] = sidebar;
}
writeFile(path.join(outRoot, 'sidebars.json'), `${JSON.stringify(sidebars, null, 2)}\n`);

console.log(`synced ${pages.size} pages, ${images.size} images`);
