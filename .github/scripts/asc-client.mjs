// App Store Connect API client. Shared by attach-to-group, promote-preflight, promote-production.
//
// Env required:
//   ASC_KEY_ID        — 10-char key identifier from App Store Connect
//   ASC_ISSUER_ID     — issuer UUID
//   ASC_KEY_PATH      — path to the .p8 private key file
//
// Docs: https://developer.apple.com/documentation/appstoreconnectapi

import { readFileSync } from 'node:fs';
import { createSign } from 'node:crypto';
import { homedir } from 'node:os';

const API_BASE = 'https://api.appstoreconnect.apple.com/v1';

function expandPath(p) {
  return p.startsWith('~') ? p.replace('~', homedir()) : p;
}

function makeJwt() {
  const keyId = required('ASC_KEY_ID');
  const issuerId = required('ASC_ISSUER_ID');
  const keyPath = expandPath(required('ASC_KEY_PATH'));
  const privateKey = readFileSync(keyPath, 'utf8');

  const header = { alg: 'ES256', kid: keyId, typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: issuerId,
    iat: now,
    exp: now + 1200,
    aud: 'appstoreconnect-v1',
  };

  const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
  const signingInput = `${b64(header)}.${b64(payload)}`;
  const signer = createSign('SHA256');
  signer.update(signingInput);
  // JWS ES256 requires raw R||S (IEEE P1363) — Node defaults to DER, which Apple rejects with 401.
  const signature = signer.sign({ key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${signingInput}.${signature}`;
}

export function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env: ${name}`);
  return v;
}

// Transient-failure policy shared by every outbound call in the release scripts.
// Apple's ASC API and Sentry both return sporadic 5xx / 429s; without a retry a single
// blip fails the whole weekly promotion (2026-11-17: ASC GET /apps → 500 UNEXPECTED_ERROR
// on the very first request). Only statuses that are safe to repeat are retried; 4xx
// other than 408/429 are returned to the caller unchanged so error-message contracts
// (e.g. the 409 check in submitForAppStoreReview) still hold.
const RETRYABLE_STATUSES = new Set([408, 429, 500, 502, 503, 504]);

function backoffMs(attempt, baseDelayMs, maxDelayMs) {
  return Math.min(baseDelayMs * 2 ** (attempt - 1), maxDelayMs);
}

// Retry-After is either delta-seconds or an HTTP-date. Returns null when absent/unparseable.
function retryAfterMs(headers, maxDelayMs, now = Date.now()) {
  const raw = headers?.get?.('retry-after');
  if (raw == null || raw === '') return null;
  const seconds = Number(raw);
  if (Number.isFinite(seconds) && seconds >= 0) return Math.min(seconds * 1000, maxDelayMs);
  const at = Date.parse(raw);
  if (Number.isNaN(at)) return null;
  return Math.min(Math.max(at - now, 0), maxDelayMs);
}

// fetch() with exponential backoff on retryable statuses and network errors.
// Resolves with the final Response (ok or not) so callers keep their own status
// handling; rejects only if the last attempt itself throws. `attempts` counts the
// first try, so attempts=4 means up to 3 retries. Dependencies are injectable for tests.
export async function fetchWithRetry(url, init = {}, opts = {}) {
  const {
    attempts = 4,
    baseDelayMs = 1000,
    maxDelayMs = 30_000,
    fetchImpl = globalThis.fetch,
    sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    log = (msg) => console.warn(msg),
    label = `${init.method || 'GET'} ${url}`,
  } = opts;
  if (!(attempts >= 1)) throw new Error(`fetchWithRetry: attempts must be >= 1, got ${attempts}`);

  for (let attempt = 1; ; attempt++) {
    const isLast = attempt >= attempts;
    let res;
    try {
      res = await fetchImpl(url, init);
    } catch (err) {
      if (isLast) throw err;
      const delay = backoffMs(attempt, baseDelayMs, maxDelayMs);
      log(`${label} → ${err?.message || err}; retrying in ${delay}ms (attempt ${attempt}/${attempts})`);
      await sleep(delay);
      continue;
    }
    if (res.ok || !RETRYABLE_STATUSES.has(res.status) || isLast) return res;
    const delay = retryAfterMs(res.headers, maxDelayMs) ?? backoffMs(attempt, baseDelayMs, maxDelayMs);
    log(`${label} → ${res.status}; retrying in ${delay}ms (attempt ${attempt}/${attempts})`);
    await sleep(delay);
  }
}

export async function ascFetch(path, init = {}) {
  const url = path.startsWith('http') ? path : `${API_BASE}${path}`;
  const method = init.method || 'GET';
  // One JWT for all attempts: it is valid for 20 minutes, far longer than the backoff window.
  const res = await fetchWithRetry(
    url,
    {
      ...init,
      headers: {
        Authorization: `Bearer ${makeJwt()}`,
        'Content-Type': 'application/json',
        ...(init.headers || {}),
      },
    },
    { label: `ASC ${method} ${path}` },
  );
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`ASC ${method} ${path} → ${res.status}: ${body}`);
  }
  return res.status === 204 ? null : res.json();
}

export async function getAppId(bundleId) {
  const res = await ascFetch(`/apps?filter[bundleId]=${encodeURIComponent(bundleId)}`);
  if (!res.data || res.data.length === 0) {
    throw new Error(`No app found with bundleId ${bundleId}`);
  }
  return res.data[0].id;
}

export async function getGroupId(appId, groupName) {
  // /apps/{id}/betaGroups doesn't accept filter[name]; list all and match client-side.
  const res = await ascFetch(`/apps/${appId}/betaGroups?limit=200`);
  const match = (res.data || []).find((g) => g.attributes?.name === groupName);
  if (!match) {
    throw new Error(`No TestFlight group named "${groupName}" on app ${appId}`);
  }
  return match.id;
}

// Returns [{ id, buildNumber, version, uploadedAt, processingState }]
export async function listBuildsInGroup(appId, groupName) {
  const groupId = await getGroupId(appId, groupName);
  // /betaGroups/{id}/builds doesn't accept include/fields; query /builds with filter[betaGroups] instead.
  const params = new URLSearchParams({
    'filter[betaGroups]': groupId,
    'include': 'preReleaseVersion',
    'fields[builds]': 'version,uploadedDate,processingState,preReleaseVersion',
    'fields[preReleaseVersions]': 'version',
    'limit': '200',
  });
  const res = await ascFetch(`/builds?${params}`);
  const versionById = new Map();
  for (const inc of res.included || []) {
    if (inc.type === 'preReleaseVersions') {
      versionById.set(inc.id, inc.attributes?.version);
    }
  }
  return (res.data || []).map((b) => {
    const prvId = b.relationships?.preReleaseVersion?.data?.id;
    return {
      id: b.id,
      buildNumber: b.attributes?.version,
      version: prvId ? versionById.get(prvId) : undefined,
      uploadedAt: b.attributes?.uploadedDate,
      processingState: b.attributes?.processingState,
    };
  });
}

// Look up a build by buildNumber (and optionally marketing version) for the given app.
export async function getBuild(appId, { version, buildNumber }) {
  const params = new URLSearchParams({
    'filter[app]': appId,
    'filter[version]': String(buildNumber),
    'include': 'preReleaseVersion',
    'fields[builds]': 'version,uploadedDate,processingState,preReleaseVersion',
    'fields[preReleaseVersions]': 'version',
    'limit': '200',
  });
  if (version) params.set('filter[preReleaseVersion.version]', version);
  const res = await ascFetch(`/builds?${params}`);
  if (!res.data || res.data.length === 0) return null;
  const build = res.data[0];
  const prvId = build.relationships?.preReleaseVersion?.data?.id;
  const prv = (res.included || []).find((i) => i.type === 'preReleaseVersions' && i.id === prvId);
  return {
    id: build.id,
    buildNumber: build.attributes?.version,
    version: prv?.attributes?.version,
    uploadedAt: build.attributes?.uploadedDate,
    processingState: build.attributes?.processingState,
  };
}

export async function attachBuildToGroup(buildId, groupId) {
  await ascFetch(`/betaGroups/${groupId}/relationships/builds`, {
    method: 'POST',
    body: JSON.stringify({ data: [{ type: 'builds', id: buildId }] }),
  });
}

// TestFlight "What to Test" lives on betaBuildLocalizations (one row per locale
// per build). Create the locale row if it doesn't exist yet, otherwise patch
// whatsNew on the existing one.
export async function setBetaBuildNotes(buildId, whatsNew, locale = 'en-US') {
  const existing = await ascFetch(
    `/builds/${buildId}/betaBuildLocalizations?fields[betaBuildLocalizations]=locale,whatsNew&limit=50`,
  );
  const row = (existing.data || []).find((l) => l.attributes?.locale === locale);
  if (row) {
    await ascFetch(`/betaBuildLocalizations/${row.id}`, {
      method: 'PATCH',
      body: JSON.stringify({
        data: { type: 'betaBuildLocalizations', id: row.id, attributes: { whatsNew } },
      }),
    });
  } else {
    await ascFetch('/betaBuildLocalizations', {
      method: 'POST',
      body: JSON.stringify({
        data: {
          type: 'betaBuildLocalizations',
          attributes: { locale, whatsNew },
          relationships: { build: { data: { type: 'builds', id: buildId } } },
        },
      }),
    });
  }
}

export async function submitForBetaReview(buildId) {
  await ascFetch('/betaAppReviewSubmissions', {
    method: 'POST',
    body: JSON.stringify({
      data: {
        type: 'betaAppReviewSubmissions',
        relationships: { build: { data: { type: 'builds', id: buildId } } },
      },
    }),
  });
}

// Production submission: create-or-update appStoreVersion for the build's marketing
// version, attach the build, set release strategy, write release notes, then submit.
export async function submitForAppStoreReview(buildId, { autoRelease, phasedRelease, releaseNotes }) {
  const build = await ascFetch(`/builds/${buildId}?include=app,preReleaseVersion&fields[apps]=bundleId&fields[preReleaseVersions]=version`);
  const appId = build.data.relationships.app.data.id;
  const prvId = build.data.relationships.preReleaseVersion.data.id;
  const versionString = (build.included || []).find((i) => i.type === 'preReleaseVersions' && i.id === prvId)?.attributes?.version;
  if (!versionString) throw new Error(`Could not resolve marketing version for build ${buildId}`);

  // Find existing appStoreVersion for this versionString, or create one.
  const existing = await ascFetch(`/apps/${appId}/appStoreVersions?filter[versionString]=${encodeURIComponent(versionString)}&filter[platform]=IOS&limit=10`);
  let appStoreVersionId = (existing.data || [])[0]?.id;

  const releaseType = autoRelease ? 'AFTER_APPROVAL' : 'MANUAL';

  if (!appStoreVersionId) {
    const created = await ascFetch('/appStoreVersions', {
      method: 'POST',
      body: JSON.stringify({
        data: {
          type: 'appStoreVersions',
          attributes: { platform: 'IOS', versionString, releaseType },
          relationships: {
            app: { data: { type: 'apps', id: appId } },
            build: { data: { type: 'builds', id: buildId } },
          },
        },
      }),
    });
    appStoreVersionId = created.data.id;
  } else {
    await ascFetch(`/appStoreVersions/${appStoreVersionId}`, {
      method: 'PATCH',
      body: JSON.stringify({
        data: {
          type: 'appStoreVersions',
          id: appStoreVersionId,
          attributes: { releaseType },
          relationships: { build: { data: { type: 'builds', id: buildId } } },
        },
      }),
    });
  }

  // Phased release: create or update the phasedRelease record.
  if (phasedRelease) {
    try {
      await ascFetch('/appStoreVersionPhasedReleases', {
        method: 'POST',
        body: JSON.stringify({
          data: {
            type: 'appStoreVersionPhasedReleases',
            attributes: { phasedReleaseState: 'INACTIVE' },
            relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: appStoreVersionId } } },
          },
        }),
      });
    } catch (err) {
      // 409 if one already exists for this version — ignore
      if (!String(err.message).includes('409')) throw err;
    }
  }

  // Release notes (whatsNew) live on appStoreVersionLocalizations. Update en-US if notes given.
  if (releaseNotes && releaseNotes.trim()) {
    const locs = await ascFetch(`/appStoreVersions/${appStoreVersionId}/appStoreVersionLocalizations?fields[appStoreVersionLocalizations]=locale,whatsNew&limit=50`);
    const enUS = (locs.data || []).find((l) => l.attributes?.locale === 'en-US');
    if (enUS) {
      await ascFetch(`/appStoreVersionLocalizations/${enUS.id}`, {
        method: 'PATCH',
        body: JSON.stringify({
          data: {
            type: 'appStoreVersionLocalizations',
            id: enUS.id,
            attributes: { whatsNew: releaseNotes },
          },
        }),
      });
    }
  }

  // Submit for review.
  await ascFetch('/appStoreVersionSubmissions', {
    method: 'POST',
    body: JSON.stringify({
      data: {
        type: 'appStoreVersionSubmissions',
        relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: appStoreVersionId } } },
      },
    }),
  });
}
