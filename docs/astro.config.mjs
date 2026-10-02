// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// GitHub Pages serves this repository's site under /pv, so the base has to
// match or every internal link 404s on the deployed site while working
// perfectly in dev.
export default defineConfig({
  site: 'https://adrum.github.io',
  base: '/pv',
  integrations: [
    starlight({
      title: 'pv',
      description:
        'A fast PHP version manager: prebuilt, relocatable PHP runtimes and per-directory version resolution.',
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/adrum/pv' },
      ],
      editLink: {
        baseUrl: 'https://github.com/adrum/pv/edit/main/docs/',
      },
      sidebar: [
        {
          label: 'Guides',
          items: [
            { label: 'Getting started', slug: 'guides/getting-started' },
            { label: 'How a version is chosen', slug: 'guides/resolution' },
            { label: 'Troubleshooting', slug: 'guides/troubleshooting' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Commands', slug: 'reference/commands' },
            { label: 'Extensions', slug: 'reference/extensions' },
            { label: 'Platforms', slug: 'reference/platforms' },
            { label: 'Integrity and licensing', slug: 'reference/integrity' },
            { label: 'Scripting pv', slug: 'reference/scripting' },
          ],
        },
      ],
    }),
  ],
});
