// @ts-check
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://workoutformat.liftmark.app',
  output: 'static',
  trailingSlash: 'ignore',
  build: {
    format: 'directory',
  },
  vite: {
    build: {
      // Force processed <script> modules to emit as external /_astro/*.js
      // files instead of being inlined into the HTML. A strict
      // `script-src 'self'` CSP (set by the CloudFront ResponseHeadersPolicy)
      // rejects inline scripts; keeping every bundled script external means we
      // need neither `unsafe-inline` nor per-script sha256 hashes. The
      // function form targets only JavaScript so other small assets keep
      // Vite's default inlining behavior.
      assetsInlineLimit: (filePath) => (filePath.endsWith('.js') ? false : undefined),
    },
  },
});
