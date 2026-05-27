import { serve } from '@hono/node-server';
import { serveStatic } from '@hono/node-server/serve-static';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { app } from './app.js';

const port = Number(process.env.PORT ?? 3000);

// E2E support: when WEBSITE_DIST points at a built website (astro
// build → dist/), mount it as static files so the API + website share
// one origin. Lambda never sets this env var, so production topology
// (CloudFront fronting S3 + API Gateway) stays unchanged.
//
// Registration order matters: this runs AFTER all API routes have been
// registered in app.ts, so /validate, /version, and /v1/* still hit
// their handlers first. Paths that don't match any API route fall
// through to the static handler. Bare directory paths get rewritten to
// `index.html` to match the CloudFront URL-rewrite function in
// cdk/stack.ts → urlRewriteFunction.
const websiteDist = process.env.WEBSITE_DIST;
if (websiteDist) {
  const abs = path.resolve(websiteDist);
  if (!fs.existsSync(abs)) {
    throw new Error(
      `WEBSITE_DIST=${abs} does not exist. Run 'npm run build' in website/ first.`,
    );
  }
  // serveStatic resolves `root` relative to cwd; absolute paths work too
  // when expressed as the relative path from cwd to abs.
  const rootRel = path.relative(process.cwd(), abs) || '.';
  app.use(
    '*',
    serveStatic({
      root: rootRel,
      rewriteRequestPath: (reqPath) => {
        if (reqPath.endsWith('/')) return `${reqPath}index.html`;
        const last = reqPath.split('/').pop() ?? '';
        if (!last.includes('.')) return `${reqPath}/index.html`;
        return reqPath;
      },
    }),
  );
  console.log(
    JSON.stringify({
      level: 'info',
      event: 'static_files_mounted',
      root: abs,
    }),
  );
}

serve({ fetch: app.fetch, port }, (info) => {
  console.log(
    JSON.stringify({
      level: 'info',
      event: 'server_started',
      port: info.port,
      url: `http://localhost:${info.port}`,
    }),
  );
});
