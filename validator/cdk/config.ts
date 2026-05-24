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
}

export const ENVS: Record<EnvName, EnvConfig> = {
  beta: {
    name: 'beta',
    account: '323146837100',
    region: 'us-west-2',
    domainName: 'beta.liftmark.app',
    stripeMode: 'test',
  },
  prod: {
    name: 'prod',
    account: '825347768149',
    region: 'us-west-2',
    domainName: 'liftmark.app',
    stripeMode: 'live',
  },
};

/** Used to scope stack names + table names so envs never collide. */
export function envPrefix(env: EnvConfig): string {
  return `Lmwf${env.name.charAt(0).toUpperCase()}${env.name.slice(1)}`;
}
