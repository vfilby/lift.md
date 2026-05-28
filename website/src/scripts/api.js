// Shared API helper for the /account portal.
//
// Auth model (matches validator/src/routes/auth/refresh.ts):
//
//   - refresh token: opaque, long-lived (1y absolute from initial login),
//     rotated per use. The browser NEVER sees or stores it as readable JS
//     state. On login and on POST /v1/auth/refresh the server sets it as an
//     httpOnly cookie (`lmwf_refresh`; HttpOnly, Secure, SameSite=Strict,
//     Path=/v1/auth). Because it is httpOnly it is unreadable from JS and so
//     cannot be exfiltrated by an XSS regression. The login/refresh JSON
//     bodies still return `refresh_token` for iOS bearer clients, but the
//     website deliberately ignores it.
//
//   - access JWT: short-lived (~1h), sent as `Authorization: Bearer <jwt>` on
//     every API call. Held ONLY in a module-scope in-memory variable (never
//     localStorage). Because it lives in memory it is gone after a reload —
//     pages bootstrap a fresh one from the refresh cookie via ensureSession().
//
//   - USER_KEY: non-sensitive display data (name/email/tier). Kept in
//     localStorage purely so the dashboard can paint a name before the first
//     network round-trip; contains no credential material.
//
// Refresh is driven entirely by the httpOnly cookie: tryRefreshTokens() POSTs
// to /v1/auth/refresh with `credentials: 'include'` and no body, the server
// reads the cookie, rotates it, and returns a new access JWT.

export const USER_KEY = 'lmwf_user';

// Short-lived access JWT — in memory only, never persisted.
let accessJwt = null;

export function getJwt() {
  return accessJwt;
}

export function getUser() {
  try {
    const raw = localStorage.getItem(USER_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch { return null; }
}

// Store the access JWT in memory. The refresh token is intentionally NOT a
// parameter — it lives only in the httpOnly cookie the server set.
export function setSession(accessJwtValue, user) {
  accessJwt = accessJwtValue || null;
  try {
    if (user) localStorage.setItem(USER_KEY, JSON.stringify(user));
  } catch {}
}

export function clearSession() {
  accessJwt = null;
  try {
    localStorage.removeItem(USER_KEY);
  } catch {}
}

function sessionHeader() {
  return accessJwt ? { Authorization: `Bearer ${accessJwt}` } : {};
}

// Internal: mint a fresh access JWT from the httpOnly refresh cookie.
// Sends NO refresh_token body — the cookie carries it — and MUST use
// `credentials: 'include'` so the browser attaches the cookie. On success the
// server has rotated the cookie and returned a new access_jwt; we store only
// that JWT in memory (the returned refresh_token is ignored). On any failure
// the session is cleared and false is returned.
async function tryRefreshTokens() {
  try {
    const res = await fetch(window.location.origin + '/v1/auth/refresh', {
      method: 'POST',
      credentials: 'include',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({}),
    });
    if (res.status !== 200) {
      // 401 here can mean expired, revoked, OR reuse-detected (the whole
      // family is dead). All three are unrecoverable from the client — the
      // only path forward is re-login.
      clearSession();
      return false;
    }
    const body = await res.json();
    if (!body || !body.access_jwt) {
      clearSession();
      return false;
    }
    // Discard body.refresh_token — the cookie was rotated server-side.
    setSession(body.access_jwt, null);
    return true;
  } catch {
    return false;
  }
}

// Ensure there is a usable in-memory access JWT, minting one from the refresh
// cookie if needed (e.g. on first page load after a reload, when the in-memory
// JWT is gone). Returns true if a session is available, false otherwise.
export async function ensureSession() {
  if (accessJwt) return true;
  return tryRefreshTokens();
}

// Generic JSON call. Uses access JWT unless `auth: false` or a `bearer` override.
// On 401, attempts a single refresh + retry. If the refresh fails, returns
// the original 401 so the caller can redirect to /account/login.
export async function api(path, opts = {}) {
  const { auth = true, bearer, headers = {}, body, ...rest } = opts;

  async function doFetch() {
    const finalHeaders = { ...headers };
    if (bearer) {
      finalHeaders.Authorization = `Bearer ${bearer}`;
    } else if (auth) {
      Object.assign(finalHeaders, sessionHeader());
    }
    if (body !== undefined && !(body instanceof FormData) && typeof body !== 'string') {
      finalHeaders['Content-Type'] = finalHeaders['Content-Type'] || 'application/json';
    }
    return fetch(window.location.origin + path, {
      ...rest,
      headers: finalHeaders,
      body: body && typeof body === 'object' && !(body instanceof FormData)
        ? JSON.stringify(body)
        : body,
    });
  }

  let res = await doFetch();

  // Auto-refresh on 401 — only when the caller is using the session (not a
  // `bearer` override or auth:false). Bypassing on `bearer` keeps PAT-driven
  // calls (e.g. testing a fresh PAT) from accidentally triggering a refresh
  // rotation. The refresh itself relies on the httpOnly cookie, so there is
  // no client-readable token to gate on.
  if (res.status === 401 && auth && !bearer) {
    const refreshed = await tryRefreshTokens();
    if (refreshed) {
      res = await doFetch();
    }
  }

  let parsed = null;
  if (res.status !== 204) {
    try { parsed = await res.json(); } catch { parsed = null; }
  }
  return { status: res.status, body: parsed };
}

// Raw text POST — used to push LMWF as text/markdown.
// Uses access JWT unless an explicit `bearer` override is passed.
// Same 401-refresh-retry pattern as api().
export async function apiRawText(path, text, bearer) {
  async function doFetch(jwt) {
    const headers = { 'Content-Type': 'text/markdown' };
    if (jwt) headers.Authorization = `Bearer ${jwt}`;
    return fetch(window.location.origin + path, {
      method: 'POST',
      headers,
      body: text,
    });
  }

  let res = await doFetch(bearer ?? getJwt());

  if (res.status === 401 && !bearer) {
    const refreshed = await tryRefreshTokens();
    if (refreshed) {
      res = await doFetch(getJwt());
    }
  }

  let parsed = null;
  try { parsed = await res.json(); } catch {}
  return { status: res.status, body: parsed };
}

// Async session guard. The access JWT lives only in memory, so on a fresh page
// load it must be re-minted from the refresh cookie. Awaits that bootstrap and
// redirects to /account/login if no session can be established. Returns true
// when a session is available.
export async function requireSessionOrRedirect() {
  if (await ensureSession()) return true;
  window.location.replace('/account/login');
  return false;
}

export function escapeHtml(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export function formatDate(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString();
}

export function formatDateShort(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toISOString().slice(0, 10);
}
