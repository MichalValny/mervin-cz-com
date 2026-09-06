const entityMap: Record<string, string> = {
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
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
  return text.replace(/&(?:#?\w+);/g, (match) => entityMap[match] ?? match);
}

export function stripHtml(html: string): string {
  return decodeHtml(html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim());
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
