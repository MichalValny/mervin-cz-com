import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import categoriesJson from '../data/categories.json';
import instagramJson from '../data/instagram.json';
import postsMetaJson from '../data/posts.json';
import siteJson from '../data/site.json';
import type { Category, InstagramFeed, LocalGallery, NavItem, Post, PostMeta, SiteData } from './types';

const projectRoot = path.join(fileURLToPath(import.meta.url), '../../..');

interface GalleryManifest {
  slug: string;
  title?: string;
  count: number;
  images: LocalGallery['images'];
}

function loadGalleryManifest(slug: string): LocalGallery | null {
  const manifestPath = path.join(projectRoot, 'public/galleries', slug, 'manifest.json');
  if (!existsSync(manifestPath)) return null;
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf-8')) as GalleryManifest;
  return {
    slug: manifest.slug,
    title: manifest.title,
    images: manifest.images ?? [],
  };
}

function resolveLocalGalleries(meta: PostMeta): LocalGallery[] | undefined {
  if (!meta.localGalleries?.length) return undefined;
  return meta.localGalleries.map((gallery) => {
    if (gallery.slug && !gallery.images?.length) {
      return loadGalleryManifest(gallery.slug) ?? { slug: gallery.slug, title: gallery.title, images: [] };
    }
    return gallery;
  });
}

const postContentFiles = import.meta.glob<string>('../content/posts/*.html', {
  eager: true,
  query: '?raw',
  import: 'default',
});

function loadPostContent(slug: string): string {
  const path = `../content/posts/${slug}.html`;
  return postContentFiles[path] ?? '';
}

export const site = siteJson as SiteData;
export const categories = categoriesJson as Category[];
export const posts: Post[] = (postsMetaJson as PostMeta[]).map((meta) => ({
  ...meta,
  localGalleries: resolveLocalGalleries(meta),
  content: loadPostContent(meta.slug),
}));
export const instagram = instagramJson as InstagramFeed;

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
  {
    label: 'Ostatní',
    href: '/kategorie/ostatni/',
    children: [
      { label: 'Zajímavosti', href: '/kategorie/zajimavosti/' },
      ...getChildCategories(26).map((c) => ({
        label: c.name,
        href: `/kategorie/${c.slug}/`,
      })),
    ],
  },
];

export const featuredSections = [
  { title: 'Co je nového', href: '/', slugs: ['cestovani', 'zabijacky', 'motorky'] },
  { title: 'Zajímavosti', href: '/kategorie/zajimavosti/', slug: 'zajimavosti' },
  { title: 'Kola', href: '/kategorie/kola/', slug: 'kola' },
  { title: 'Motorky', href: '/kategorie/motorky/', slug: 'motorky' },
];
