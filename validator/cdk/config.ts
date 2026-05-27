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
  },
  prod: {
    name: 'prod',
    account: '825347768149',
    region: 'us-west-2',
    domainName: 'liftmark.app',
    stripeMode: 'live',
    sesMailFromSubdomain: 'mail',
    dmarcPolicy: 'v=DMARC1; p=none;',
  },
};

/** Used to scope stack names + table names so envs never collide. */
export function envPrefix(env: EnvConfig): string {
  return `Lmwf${env.name.charAt(0).toUpperCase()}${env.name.slice(1)}`;
}
