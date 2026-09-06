export interface Category {
  id: number;
  name: string;
  slug: string;
  parent: number;
  count: number;
  link: string;
}

export interface PostCategory {
  id: number;
  name: string;
  slug: string;
}

export interface GalleryImage {
  src: string;
  thumb: string;
  alt?: string;
}

export interface LocalGallery {
  title?: string;
  images: GalleryImage[];
}

export interface PostMeta {
  id: number;
  title: string;
  slug: string;
  path: string;
  date: string;
  year: number;
  month: number;
  day: number;
  link: string;
  excerpt: string;
  galleries: string[];
  localGalleries?: LocalGallery[];
  featuredImage: string | null;
  categories: PostCategory[];
  categoryIds: number[];
}

export interface Post extends PostMeta {
  content: string;
}

export interface SiteData {
  siteName: string;
  siteUrl: string;
  logo: string;
  favicon: string;
  instagram: boolean;
  instagramUsername?: string;
  instagramProfileUrl?: string;
}

export interface InstagramPost {
  id: string;
  permalink: string;
  imageUrl: string;
  mediaType: string;
}

export interface InstagramFeed {
  username: string;
  profileUrl: string;
  updatedAt: string | null;
  source: string;
  posts: InstagramPost[];
}

export interface NavItem {
  label: string;
  href: string;
  children?: NavItem[];
}
