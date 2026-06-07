import { describe, it, expect } from 'vitest';
import { redirectFnCode } from './redirect-fn';

/**
 * Evaluates a generated CloudFront-Function body and invokes its `handler`
 * against a synthetic viewer-request event. CloudFront Functions are
 * ECMAScript 5.1 — plain `function handler(event){…}` — so a `new Function`
 * wrapper that returns the handler is a faithful enough harness for the pure
 * routing logic we care about (status code, Location, well-known pass-through).
 */
function makeHandler(code: string): (event: any) => any {
  // eslint-disable-next-line @typescript-eslint/no-implied-eval
  return new Function(`${code}\nreturn handler;`)() as (event: any) => any;
}

function req(uri: string, querystring: Record<string, { value: string }> = {}) {
  return { request: { uri, querystring } };
}

const CANON = 'getlift.md';

describe('redirectFnCode — keepWellKnown (legacy apex, e.g. liftmark.app)', () => {
  const handler = makeHandler(redirectFnCode(CANON, true));

  it('301-redirects a site page to the canonical host, path preserved', () => {
    const res = handler(req('/account'));
    expect(res.statusCode).toBe(301);
    expect(res.statusDescription).toBe('Moved Permanently');
    expect(res.headers.location.value).toBe('https://getlift.md/account');
  });

  it('301-redirects the root', () => {
    expect(handler(req('/')).headers.location.value).toBe('https://getlift.md/');
    expect(handler(req('/')).statusCode).toBe(301);
  });

  it('308-redirects /validate (method + body preserved)', () => {
    const res = handler(req('/validate'));
    expect(res.statusCode).toBe(308);
    expect(res.statusDescription).toBe('Permanent Redirect');
    expect(res.headers.location.value).toBe('https://getlift.md/validate');
  });

  it('308-redirects /version', () => {
    expect(handler(req('/version')).statusCode).toBe(308);
  });

  it('308-redirects /v1/* API paths', () => {
    expect(handler(req('/v1/workouts')).statusCode).toBe(308);
    expect(handler(req('/v1/auth/password/login')).statusCode).toBe(308);
    expect(handler(req('/v1/workouts/outbox')).headers.location.value).toBe(
      'https://getlift.md/v1/workouts/outbox',
    );
  });

  it('does NOT redirect the AASA / any /.well-known path — passes through to origin', () => {
    const aasa = handler(req('/.well-known/apple-app-site-association'));
    // Pass-through returns the original request object itself (no statusCode),
    // which CloudFront then forwards to the S3 origin.
    expect(aasa.statusCode).toBeUndefined();
    expect(aasa.uri).toBe('/.well-known/apple-app-site-association');
  });

  it('preserves the query string', () => {
    const res = handler(req('/account', { tab: { value: 'tokens' }, x: { value: '' } }));
    expect(res.headers.location.value).toBe('https://getlift.md/account?tab=tokens&x');
  });

  it('treats /v1 (no trailing slash) as a site page, not API', () => {
    // Only /v1/* (with slash) is API; a bare /v1 is not a real route but must
    // not be mis-308'd — guards the indexOf('/v1/') boundary.
    expect(handler(req('/v1')).statusCode).toBe(301);
  });
});

describe('redirectFnCode — redirect-all (vanity domains, e.g. liftmd.app)', () => {
  const handler = makeHandler(redirectFnCode(CANON, false));

  it('redirects /.well-known/* too (no installed app pins these hosts)', () => {
    const res = handler(req('/.well-known/apple-app-site-association'));
    expect(res.statusCode).toBe(301);
    expect(res.headers.location.value).toBe(
      'https://getlift.md/.well-known/apple-app-site-association',
    );
  });

  it('still 308s API paths', () => {
    expect(handler(req('/v1/workouts')).statusCode).toBe(308);
  });

  it('301s site pages', () => {
    expect(handler(req('/format/spec')).statusCode).toBe(301);
  });
});
