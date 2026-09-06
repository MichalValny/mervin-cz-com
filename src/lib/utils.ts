const namedEntities: Record<string, string> = {
  amp: '&',
  lt: '<',
  gt: '>',
  quot: '"',
  apos: "'",
  nbsp: ' ',
  hellip: '…',
  mdash: '—',
  ndash: '–',
  rsquo: '\u2019',
  lsquo: '\u2018',
  rdquo: '\u201D',
  ldquo: '\u201C',
};

const legacyEntityMap: Record<string, string> = {
  '&#039;': "'",
  '&#8211;': '–',
  '&#8212;': '—',
  '&#8216;': '\u2018',
  '&#8217;': '\u2019',
  '&#8220;': '\u201C',
  '&#8221;': '\u201D',
  '&#8230;': '…',
};

export function decodeHtml(text: string): string {
  return text.replace(/&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);/g, (match, entity: string) => {
    if (entity.startsWith('#x') || entity.startsWith('#X')) {
      const code = parseInt(entity.slice(2), 16);
      return Number.isFinite(code) ? String.fromCharCode(code) : match;
    }
    if (entity.startsWith('#')) {
      const code = parseInt(entity.slice(1), 10);
      return Number.isFinite(code) ? String.fromCharCode(code) : match;
    }
    return namedEntities[entity.toLowerCase()] ?? legacyEntityMap[match] ?? match;
  });
}

export function stripHtml(html: string): string {
  return decodeHtml(html.replace(/<[^>]*>/g, ' '))
    .replace(/\u00a0/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export function formatDate(dateStr: string): string {
  const date = new Date(dateStr);
  return new Intl.DateTimeFormat('cs-CZ', {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  }).format(date);
}

export function formatDateShort(dateStr: string): string {
  const date = new Date(dateStr);
  return new Intl.DateTimeFormat('cs-CZ', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  }).format(date);
}

const SITE_URL = 'https://www.mervin-cz.com';

export function resolveImageUrl(url: string | null): string | null {
  if (!url) return null;
  if (url.startsWith('/')) return `${SITE_URL}${url}`;
  return url;
}

export function getPostImage(post: {
  featuredImage: string | null;
  galleries: string[];
  localGalleries?: { images: { src: string }[] }[];
}): string | null {
  if (post.featuredImage) return post.featuredImage;
  const local = post.localGalleries?.[0]?.images[0]?.src;
  if (local) return local;
  const gallery = post.galleries[0];
  if (!gallery) return null;
  const match = gallery.match(/object data="([^"]+)"/);
  return match?.[1] ?? null;
}

export function getExcerpt(post: { excerpt: string; content: string }, maxLength = 160): string {
  const text = stripHtml(post.excerpt || post.content);
  if (text.length <= maxLength) return text;
  return `${text.slice(0, maxLength).trim()}…`;
}

function cleanParagraphInner(html: string): string {
  return html
    .replace(/&nbsp;/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function hasDiaryIndent(html: string): boolean {
  return /^(?:\s|\u00a0|&nbsp;|&#160;){2,}/i.test(html);
}

function isRiderLine(text: string): boolean {
  const plain = stripHtml(text).replace(/\u00a0/g, ' ').trim();
  if (!/(?:–|—)/.test(plain) || plain.endsWith(':') || plain.length > 120) {
    return false;
  }
  if (/^\d/.test(plain)) {
    return false;
  }
  return /jawa|čz|pav|velo|bizon|panelka|kývačka|side|solex|simson/i.test(plain);
}

function startsWithLowercase(text: string): boolean {
  const plain = stripHtml(text).replace(/^[\s\u00a0]+/, '');
  return /^[a-záčďéěíňóřšťúůýž]/.test(plain);
}

function isDayHeading(text: string): boolean {
  return /^\d+\.\s*den\b/i.test(stripHtml(text).replace(/\u00a0/g, ' ').trim());
}

function isTripDateLine(text: string): boolean {
  return /^\d{1,2}-\d{1,2}\.\s*\d{0,2}\.?\s*\d{4}$/.test(text.replace(/\u00a0/g, ' ').trim());
}

function isExcuseLine(text: string): boolean {
  const plain = stripHtml(text).trim();
  const match = plain.match(/^(.+?)-([a-záčďéěíňóřšťúůýž].+)$/);
  if (!match) {
    return false;
  }
  const name = match[1].trim();
  return !/^\d/.test(name) && name.length <= 40;
}

function formatExcuseParagraph(inner: string): string {
  const cleaned = cleanParagraphInner(inner);
  const match = cleaned.match(/^(.+?)-([a-záčďéěíňóřšťúůýž].+)$/);
  if (!match) {
    return `<p>${cleaned}</p>`;
  }
  return `<p class="article-entry"><strong class="article-entry-label">${match[1]}</strong>–${match[2]}</p>`;
}

function mergeRiderParagraphs(html: string): string {
  return html.replace(
    /<p>([^<]+)<\/p>\s*<p>([^<]+)<\/p>/gi,
    (match, label: string, body: string) => {
      const cleanLabel = cleanParagraphInner(label);
      const cleanBody = cleanParagraphInner(body);
      if (!isRiderLine(cleanLabel) || !startsWithLowercase(cleanBody)) {
        return match;
      }
      return `<p class="article-entry"><strong class="article-entry-label">${cleanLabel}</strong> ${cleanBody}</p>`;
    },
  );
}

function groupConsecutiveRiderLines(html: string): string {
  const parts = html.split(/(?=<p class=|<ul class=|<p>)/);

  return parts.map((part) => {
    if (!part.startsWith('<p>')) {
      return part;
    }

    const riders: string[] = [];
    let rest = part;

    while (true) {
      const match = rest.match(/^<p>([^<]+)<\/p>\s*/);
      if (!match || !isRiderLine(cleanParagraphInner(match[1]))) {
        break;
      }
      riders.push(cleanParagraphInner(match[1]));
      rest = rest.slice(match[0].length);
    }

    if (riders.length === 0) {
      return part;
    }

    const list = `<ul class="article-roster">${riders.map((line) => `<li>${line}</li>`).join('')}</ul>`;
    return `${list}${rest}`;
  }).join('');
}

function markDiaryBetweenDayHeadings(html: string): string {
  const sections = html.split(/(?=<p class="article-day-heading")/);

  return sections.map((section, index) => {
    if (index === 0) {
      return section;
    }

    return section.replace(/<p>([^<]+)<\/p>/g, (_match, inner: string) => {
      const cleaned = cleanParagraphInner(inner);
      return cleaned ? `<p class="article-diary">${cleaned}</p>` : '';
    });
  }).join('');
}

function stripEmptyStrongIndent(html: string): string {
  return html.replace(
    /<p>\s*<strong>(?:&nbsp;|&#160;|\u00a0|\s)*<\/strong>\s*([^<]+)<\/p>/gi,
    (_match, inner: string) => {
      const cleaned = cleanParagraphInner(inner);
      return cleaned ? `<p class="article-diary">${cleaned}</p>` : '';
    },
  );
}

function formatPhotoCredit(html: string): string {
  return html
    .replace(
      /<p>\s*(?:<br\s*\/?>\s*)*<em>Fota\s+([^<]+)<\/em>\s*<\/p>/gi,
      (_match, author: string) =>
        `<p class="article-photo-credit"><em>Fota ${cleanParagraphInner(author)}</em></p>`,
    )
    .replace(
      /<p>\s*<em>Fota\s+([^<]+)<\/em>\s*<\/p>/gi,
      (_match, author: string) =>
        `<p class="article-photo-credit"><em>Fota ${cleanParagraphInner(author)}</em></p>`,
    );
}

export function formatArticleContent(html: string): string {
  let content = html
    .replace(/<p>(?:\s|&nbsp;)*<\/p>/gi, '')
    .replace(/\n{3,}/g, '\n\n');

  content = stripEmptyStrongIndent(content);

  content = content.replace(/<p>([^<]*)<\/p>/gi, (_match, inner: string) => {
    if (hasDiaryIndent(inner)) {
      const cleaned = cleanParagraphInner(inner);
      return cleaned ? `<p class="article-diary">${cleaned}</p>` : '';
    }

    const cleaned = cleanParagraphInner(inner);
    if (!cleaned) {
      return '';
    }
    if (isTripDateLine(cleaned)) {
      return `<p class="article-intro">${cleaned}</p>`;
    }
    if (isExcuseLine(cleaned)) {
      return formatExcuseParagraph(cleaned);
    }
    return `<p>${cleaned}</p>`;
  });

  content = content.replace(/<p>([^<]*<br[^>]*>[^<]*)<\/p>/gi, (_match, inner: string) => {
    const normalized = inner.replace(/&nbsp;/gi, ' ').replace(/\s+/g, ' ').trim();
    const plain = stripHtml(normalized);
    if (isTripDateLine(plain) || (/^\d/.test(plain) && /komentář/i.test(normalized))) {
      return `<p class="article-intro">${normalized}</p>`;
    }
    return `<p>${normalized}</p>`;
  });

  content = mergeRiderParagraphs(content);

  content = content.replace(/<p><strong>([^<]+)<\/strong><\/p>/gi, (_match, label: string) => {
    const cleanLabel = cleanParagraphInner(label);
    if (isDayHeading(cleanLabel)) {
      return `<p class="article-day-heading"><strong>${cleanLabel}</strong></p>`;
    }
    return `<p class="article-section-label"><strong>${cleanLabel}</strong></p>`;
  });

  content = groupConsecutiveRiderLines(content);
  content = content.replace(/<\/ul>\s*<ul class="article-roster">/g, '');
  content = markDiaryBetweenDayHeadings(content);
  content = formatPhotoCredit(content);

  return content.trim();
}
