import { serve } from '@hono/node-server';
import { app } from './app.js';

const port = Number(process.env.PORT ?? 3000);

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
