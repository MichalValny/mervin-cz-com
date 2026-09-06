import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://www.mervin-cz.com',
  trailingSlash: 'always',
  build: {
    format: 'directory',
  },
});
