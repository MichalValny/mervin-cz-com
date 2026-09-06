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

export function getPostImage(post: { featuredImage: string | null; galleries: string[] }): string | null {
  if (post.featuredImage) return post.featuredImage;
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

export function formatArticleContent(html: string): string {
  let content = html
    .replace(/<p>(?:\s|&nbsp;)*<\/p>/gi, '')
    .replace(/\n{3,}/g, '\n\n');

  content = content.replace(/<p>([^<]*)<\/p>/gi, (_match, inner: string) => {
    const cleaned = cleanParagraphInner(inner);
    return cleaned ? `<p>${cleaned}</p>` : '';
  });

  content = mergeRiderParagraphs(content);

  content = content.replace(/<p><strong>([^<]+)<\/strong><\/p>/gi, (_match, label: string) => {
    const cleanLabel = cleanParagraphInner(label);
    if (isDayHeading(cleanLabel)) {
      return `<p class="article-day-heading"><strong>${cleanLabel}</strong></p>`;
    }
    return `<p class="article-section-label"><strong>${cleanLabel}</strong></p>`;
  });

  content = content.replace(
    /<p>(?:&nbsp;|\s){2,}([^<]+)<\/p>/gi,
    (_match, inner: string) => `<p class="article-diary">${cleanParagraphInner(inner)}</p>`,
  );

  return content.trim();
}
