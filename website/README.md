# getlift.md

Static Astro site for the LiftMark Workout Format (LMWF): human landing page, full spec, validator playground, and LLM-oriented endpoints (`/llms.txt`, `/spec.md`, `/install.sh`).

## Source of truth

The spec is **not** duplicated here. It is imported at build time from:

```
/Users/vfilby/Projects/LiftMark/liftmark-workout-format/LIFTMARK_WORKOUT_FORMAT_SPEC.md
```

via a Vite `?raw` import in `src/pages/spec.astro` and `src/pages/spec.md.ts`. Edits go in that file.

## Local development

Requires Node 20+.

```sh
cd mobile-apps/../website   # or: cd /Users/vfilby/Projects/LiftMark/website
npm install
npm run dev
```

Dev server runs on <http://localhost:4321>. The "Try it" widget on the landing page posts to the live production validator at <https://getlift.md/validate> (CORS `*`), so you can exercise it against real infra from localhost.

## Build

```sh
npm run build
```

Output lands in `dist/` — a fully static site that can be uploaded to any object store / CDN.

## Deployment

TBD. Phase 1 infra plan: S3 + CloudFront fronting both this site and the `/validate` Lambda under a single origin (`getlift.md`). For now `dist/` is just built and synced manually.

## Structure

```
website/
  astro.config.mjs
  package.json
  src/
    layouts/Base.astro       # header + footer + global CSS
    pages/
      index.astro            # landing page + validator widget
      spec.astro             # rendered spec (HTML)
      spec.md.ts             # raw spec (text/markdown)
      llms.txt.ts            # llmstxt.org endpoint
      install.sh.ts          # skill installer script
```
