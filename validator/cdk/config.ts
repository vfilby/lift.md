/**
 * Per-environment CDK configuration.
 *
 * One config block per env. Adding a new env is one entry here plus a
 * stack pair instantiation in app.ts.
 */
export type EnvName = 'beta' | 'prod';

export interface EnvConfig {
  /** Env identifier — used in stack names, table names, Sentry env tag. */
  name: EnvName;
  /** AWS account ID this env deploys to. */
  account: string;
  /** Primary region for the main stack. */
  region: string;
  /** Apex (or near-apex) domain served by CloudFront for this env. */
  domainName: string;
  /**
   * Canonical web domain for the env. When set AND different from
   * `domainName`, the site is served at this domain and `domainName` (plus any
   * `redirectWebDomains`) 302-redirect their site pages here — preserving path
   * + query. API paths (`/validate`, `/v1/*`, `/version`) and the AASA file are
   * NOT redirected on `domainName`, so the iOS app and installed-app password
   * autofill keep working. The canonical domain's zone + cert come from the
   * LmwfDnsFoundationStack (passed in via stack props). Leave undefined to keep
   * `domainName` as the canonical site (beta).
   */
  canonicalWebDomain?: string;
  /**
   * Extra domains whose site pages 302-redirect to `canonicalWebDomain`
   * (full redirect — no API/AASA carve-out). Each needs a zone + cert from the
   * LmwfDnsFoundationStack. Ignored unless `canonicalWebDomain` is set.
   */
  redirectWebDomains?: readonly string[];
  /** Stripe API mode. Used by app code to pick test vs live keys. */
  stripeMode: 'test' | 'live';
  /**
   * Optional MAIL FROM subdomain for SES. When set, CDK configures the SES
   * EmailIdentity with `${sesMailFromSubdomain}.${domainName}` as the
   * MAIL FROM domain — bounces and complaints report against that
   * subdomain instead of `bounces.<region>.amazonses.com`, improving
   * deliverability. CDK auto-publishes the MX + SPF TXT records. Leave
   * undefined to keep the SES default. Per-env so an active SES support
   * case in one env doesn't get nudged by an unrelated DNS change.
   */
  sesMailFromSubdomain?: string;
  /**
   * Optional DMARC TXT policy published at `_dmarc.${domainName}`. e.g.
   * `'v=DMARC1; p=none;'` for monitor-only. Leave undefined to skip
   * publishing a DMARC record. Per-env for the same reason as
   * sesMailFromSubdomain.
   */
  dmarcPolicy?: string;
  /**
   * When true, the browser-facing CORS allowlist (HTTP API corsPreflight)
   * includes the local Astro dev origin so the website workspace can hit the
   * env's API from `localhost` during development. Beta only — never prod.
   */
  allowLocalDevOrigin?: boolean;
}

/** Local Astro dev-server origin, allowed only when `allowLocalDevOrigin`. */
export const LOCAL_DEV_ORIGIN = 'http://localhost:4321';

/**
 * Browser origins permitted to make credentialed requests to the env's HTTP
 * API. Replaces the previous wildcard CORS: an explicit allowlist is required
 * once the refresh token moves to a SameSite cookie (credentialed CORS cannot
 * use `*`).
 *
 * Only the host that actually *serves* the site + makes credentialed
 * same-origin API calls is listed: the canonical web domain when set (prod:
 * `getlift.md`), else the env apex (beta: `beta.liftmark.app`). The legacy
 * redirect-only hosts (`liftmark.app`, `workoutformat.liftmark.app`,
 * `liftmd.app`) never originate an XHR — their pages 301/308 to the canonical
 * host before any script runs — so they are intentionally NOT allowlisted
 * (GH #248).
 */
export function corsAllowedOrigins(env: EnvConfig): string[] {
  const servingOrigin = env.canonicalWebDomain ?? env.domainName;
  const origins = [`https://${servingOrigin}`];
  if (env.allowLocalDevOrigin) {
    origins.push(LOCAL_DEV_ORIGIN);
  }
  return origins;
}

export const ENVS: Record<EnvName, EnvConfig> = {
  beta: {
    name: 'beta',
    account: '323146837100',
    region: 'us-west-2',
    domainName: 'beta.liftmark.app',
    stripeMode: 'test',
    // No sesMailFromSubdomain / dmarcPolicy: beta has an in-flight SES
    // production-access support case (177985180300561). Avoid changing
    // beta's SES posture until that's resolved; mirror prod's config
    // here after.
    allowLocalDevOrigin: true,
  },
  prod: {
    name: 'prod',
    account: '825347768149',
    region: 'us-west-2',
    domainName: 'liftmark.app',
    // getlift.md is canonical and serves everything (site + API + spec +
    // schemas + AASA). liftmark.app + liftmd.app are redirect-only (301 site /
    // 308 API), with liftmark.app's AASA kept served as the sole exception for
    // already-installed apps pinned to it (GH #248). Zones/certs for the
    // canonical + redirect domains come from the LmwfDnsFoundationStack.
    canonicalWebDomain: 'getlift.md',
    redirectWebDomains: ['liftmd.app'],
    stripeMode: 'live',
    sesMailFromSubdomain: 'mail',
    dmarcPolicy: 'v=DMARC1; p=none;',
  },
};

/** Used to scope stack names + table names so envs never collide. */
export function envPrefix(env: EnvConfig): string {
  return `Lmwf${env.name.charAt(0).toUpperCase()}${env.name.slice(1)}`;
}

export interface VanityDomain {
  /** Apex domain — gets its own hosted zone. */
  domain: string;
  /**
   * Issue the wildcard ACM cert now. Keep `false` until the domain is
   * registered AND its NS are delegated to this zone: a DNS-validated cert
   * blocks the *entire stack's* CREATE until it validates, and an
   * undelegated domain never will — it just times out and rolls back every
   * other resource (including healthy zones). Defer the cert, ship the zone
   * to hold stable NS, then flip to `true` once delegation is live.
   */
  issueCert: boolean;
}

/**
 * Vanity / redirect domains that get their own long-lived Route 53 hosted
 * zone (+ optional wildcard cert) in the prod account, managed by the
 * LmwfDnsFoundationStack. Decoupled from ENVS because these are not validator
 * environments — they own registrar delegation and must outlive any app-stack
 * teardown.
 *
 * Note: `.md` is Moldova's ccTLD and is not registrable via Route 53; the
 * domain is registered at an external registrar, and only its NS delegation
 * points at the zone created here.
 */
export const VANITY_DOMAINS: readonly VanityDomain[] = [
  // Registered + delegated to the zone's AWS nameservers (2026-06-02), so the
  // wildcard cert can now validate via DNS.
  { domain: 'getlift.md', issueCert: true },
  { domain: 'liftmd.app', issueCert: true },
];
