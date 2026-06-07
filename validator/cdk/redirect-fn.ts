/**
 * CloudFront viewer-request Function body that permanently redirects to the
 * canonical host, preserving path + query (GH #248). Kept in its own module
 * (no CDK imports) so the generated function can be unit-tested by evaluating
 * it against sample events — see redirect-fn.test.ts.
 *
 * Status code is chosen per-path:
 *   - API paths (`/validate`, `/version`, `/v1/*`) → **308** so a `POST` keeps
 *     its method + body when the client replays against the canonical host
 *     (a 301/302 would let the client downgrade to `GET` and drop the body).
 *   - Everything else (site pages) → **301**.
 *
 * When `keepWellKnown` is true, `/.well-known/*` is served from origin instead
 * of redirected — the AASA exception: Apple does not follow redirects when
 * fetching `apple-app-site-association`, and already-installed apps are pinned
 * to this host. The redirect is returned at the edge; the origin is never
 * reached for redirected paths.
 */
export function redirectFnCode(canonicalHost: string, keepWellKnown: boolean): string {
  const wellKnownGuard = keepWellKnown
    ? "  if (request.uri.indexOf('/.well-known/') === 0) { return request; }\n"
    : '';
  return `
function handler(event) {
  var request = event.request;
${wellKnownGuard}  var qs = '';
  var keys = Object.keys(request.querystring);
  if (keys.length > 0) {
    qs = '?' + keys.map(function (k) {
      var v = request.querystring[k];
      return v.value !== '' ? k + '=' + v.value : k;
    }).join('&');
  }
  var u = request.uri;
  var isApi = u === '/validate' || u === '/version' || u.indexOf('/v1/') === 0;
  return {
    statusCode: isApi ? 308 : 301,
    statusDescription: isApi ? 'Permanent Redirect' : 'Moved Permanently',
    headers: { 'location': { value: 'https://${canonicalHost}' + request.uri + qs } },
  };
}
`;
}
