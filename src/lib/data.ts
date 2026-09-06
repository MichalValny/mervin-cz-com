import categoriesJson from '../data/categories.json';
import postsJson from '../data/posts.json';
import siteJson from '../data/site.json';
import type { Category, NavItem, Post, SiteData } from './types';

export const site = siteJson as SiteData;
export const categories = categoriesJson as Category[];
export const posts = postsJson as Post[];

export function getPostByPath(path: string): Post | undefined {
  const normalized = path.endsWith('/') ? path : `${path}/`;
  return posts.find((p) => p.path === normalized);
}

export function getPostsByCategorySlug(slug: string): Post[] {
  return posts.filter((p) => p.categories.some((c) => c.slug === slug));
}

export function getCategoryBySlug(slug: string): Category | undefined {
  return categories.find((c) => c.slug === slug);
}

export function getChildCategories(parentId: number): Category[] {
  return categories.filter((c) => c.parent === parentId);
}

export function getArchives(): { key: string; label: string; count: number }[] {
  const map = new Map<string, { label: string; count: number }>();
  for (const post of posts) {
    const key = `${post.year}-${String(post.month).padStart(2, '0')}`;
    const monthNames = [
      'Leden', 'Únor', 'Březen', 'Duben', 'Květen', 'Červen',
      'Červenec', 'Srpen', 'Září', 'Říjen', 'Listopad', 'Prosinec',
    ];
    const label = `${monthNames[post.month - 1]} ${post.year}`;
    const existing = map.get(key);
    if (existing) existing.count += 1;
    else map.set(key, { label, count: 1 });
  }
  return [...map.entries()]
    .sort((a, b) => b[0].localeCompare(a[0]))
    .map(([key, value]) => ({ key, ...value }));
}

export const mainNav: NavItem[] = [
  { label: 'Motorky', href: '/kategorie/motorky/' },
  { label: 'Kola', href: '/kategorie/kola/' },
  { label: 'Zajímavosti', href: '/kategorie/zajimavosti/' },
  {
    label: 'Ostatní',
    href: '/kategorie/ostatni/',
    children: getChildCategories(26).map((c) => ({
      label: c.name,
      href: `/kategorie/${c.slug}/`,
    })),
  },
  { label: 'Jak přispívat', href: '/jak-prispivat/' },
];

export const featuredSections = [
  { title: 'Co je nového', href: '/jak-prispivat/', slugs: ['cestovani', 'zabijacky', 'motorky'] },
  { title: 'Zajímavosti', href: '/kategorie/zajimavosti/', slug: 'zajimavosti' },
  { title: 'Kola', href: '/kategorie/kola/', slug: 'kola' },
  { title: 'Motorky', href: '/kategorie/motorky/', slug: 'motorky' },
];
