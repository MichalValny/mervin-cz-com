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

export interface Post {
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
  content: string;
  galleries: string[];
  featuredImage: string | null;
  categories: PostCategory[];
  categoryIds: number[];
}

export interface SiteData {
  siteName: string;
  siteUrl: string;
  logo: string;
  favicon: string;
  instagram: boolean;
}

export interface NavItem {
  label: string;
  href: string;
  children?: NavItem[];
}
