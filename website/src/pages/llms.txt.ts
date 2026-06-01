import type { APIRoute } from 'astro';

const body = `# lift.md format

lift.md format (formerly "LMWF") is a markdown-based format for strength training workouts. It is human-writable and machine-parseable. Used by the LiftMark iOS app (https://liftmark.app) but open for any tooling.

## Docs

- [Format hub](https://liftmark.app/format): Pitch, examples, live validator, and the full spec.
- [Full spec](https://liftmark.app/spec.md): Complete lift.md format specification in markdown.
- [Validator API](https://liftmark.app/validate): POST JSON \`{"markdown": "..."}\` to validate lift.md format content. Returns \`{success, summary, errors, warnings}\`.

## Optional

- [Claude Code skill installer](https://liftmark.app/install.sh): One-line installer (\`curl -fsSL https://liftmark.app/install.sh | sh\`) for a skill that generates and validates lift.md format workouts.
`;

export const GET: APIRoute = () => {
  return new Response(body, {
    status: 200,
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'public, max-age=300',
    },
  });
};
