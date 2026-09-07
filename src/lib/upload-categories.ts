import categoriesJson from '../data/categories.json';
import type { Category } from './types';

const categories = categoriesJson as Category[];

/** Categories available in the upload form (excludes parent-only "Ostatní"). */
export const uploadCategories = categories
  .filter((category) => category.slug !== 'ostatni')
  .sort((a, b) => a.name.localeCompare(b.name, 'cs'));
