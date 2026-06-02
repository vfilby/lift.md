// @ts-check
import { defineConfig } from 'astro/config';

export default defineConfig({
  // Canonical domain is now getlift.md; liftmark.app 302-redirects its site
  // pages to getlift.md. The format hub lives at getlift.md/format; the
  // legacy workoutformat.liftmark.app subdomain still resolves to the same
  // CloudFront distribution (see validator/cdk/stack.ts), so old links keep
  // working while canonical/OG/sitemap metadata points at getlift.md.
  site: 'https://getlift.md',
  output: 'static',
  trailingSlash: 'ignore',
  // Old format URLs → new IA. Astro emits these as meta-refresh redirect
  // pages in the static build (beta — backward-compat is best-effort, not a
  // hard contract; see issue #188).
  redirects: {
    '/spec': '/format/spec',
  },
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
