// Shared API helper for the /account portal.
//
// Auth model (matches validator/src/routes/auth/refresh.ts):
//
//   - access JWT (lmwf_access_jwt): short-lived (1h), sent as
//     `Authorization: Bearer <jwt>` on every API call. Stored in
//     localStorage. When it expires the server returns 401 and
//     withRefresh() transparently swaps in a fresh one.
//
//   - refresh token (lmwf_refresh_token): opaque, long-lived (1y
//     absolute from initial login). Stored in localStorage. Used ONLY
//     to mint a new access JWT (and a new refresh token, since the
//     server rotates per use) via POST /v1/auth/refresh. Never sent on
//     resource requests, never put in URLs.
//
// localStorage is acceptable for the beta inspection dashboard.
// Production-grade would put both in httpOnly cookies set by the API.
// Not implementing cookies here.

export const JWT_KEY = 'lmwf_access_jwt';
export const REFRESH_KEY = 'lmwf_refresh_token';
export const USER_KEY = 'lmwf_user';

export function getJwt() {
  try { return localStorage.getItem(JWT_KEY); } catch { return null; }
}

export function getRefreshToken() {
  try { return localStorage.getItem(REFRESH_KEY); } catch { return null; }
}

export function getUser() {
  try {
    const raw = localStorage.getItem(USER_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch { return null; }
}

export function setSession(accessJwt, refreshToken, user) {
  try {
    localStorage.setItem(JWT_KEY, accessJwt);
    if (refreshToken) localStorage.setItem(REFRESH_KEY, refreshToken);
    if (user) localStorage.setItem(USER_KEY, JSON.stringify(user));
  } catch {}
}

export function clearSession() {
  try {
    localStorage.removeItem(JWT_KEY);
    localStorage.removeItem(REFRESH_KEY);
    localStorage.removeItem(USER_KEY);
  } catch {}
}

function sessionHeader() {
  const jwt = getJwt();
  return jwt ? { Authorization: `Bearer ${jwt}` } : {};
}

// Internal: call /v1/auth/refresh with the stored refresh token.
// On success, swaps both tokens in localStorage and returns true.
// On any failure clears the session and returns false.
async function tryRefreshTokens() {
  const refresh_token = getRefreshToken();
  if (!refresh_token) return false;
  try {
    const res = await fetch(window.location.origin + '/v1/auth/refresh', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token }),
    });
    if (res.status !== 200) {
      // 401 here can mean expired, revoked, OR reuse-detected (the
      // whole family is dead). All three are unrecoverable from the
      // client — the only path forward is re-login.
      clearSession();
      return false;
    }
    const body = await res.json();
    if (!body || !body.access_jwt || !body.refresh_token) {
      clearSession();
      return false;
    }
    setSession(body.access_jwt, body.refresh_token, null);
    return true;
  } catch {
    return false;
  }
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

  // Auto-refresh on 401 — only when:
  //   (1) the caller is using the session (not a `bearer` override or auth:false)
  //   (2) we have a refresh token to spend
  // Bypassing on `bearer` keeps PAT-driven calls (e.g. testing a fresh
  // PAT) from accidentally consuming a refresh-token rotation.
  if (res.status === 401 && auth && !bearer && getRefreshToken()) {
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

  if (res.status === 401 && !bearer && getRefreshToken()) {
    const refreshed = await tryRefreshTokens();
    if (refreshed) {
      res = await doFetch(getJwt());
    }
  }

  let parsed = null;
  try { parsed = await res.json(); } catch {}
  return { status: res.status, body: parsed };
}

export function requireSessionOrRedirect() {
  if (!getJwt()) {
    window.location.replace('/account/login');
    return false;
  }
  return true;
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
