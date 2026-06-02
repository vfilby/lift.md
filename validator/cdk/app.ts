#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { ENVS, VANITY_DOMAINS, envPrefix } from './config';
import { LmwfDnsFoundationStack } from './dns-stack';
import { LmwfEdgeStack } from './edge-stack';
import { LmwfValidatorStack } from './stack';

const app = new cdk.App();

const commonTags = {
  Project: 'LiftMark',
  Service: 'lmwf-validator',
};

// Vanity / redirect domains — long-lived zones + wildcard certs in the prod
// account, decoupled from any validator env so an app teardown can't orphan
// registrar delegation. us-east-1 so the certs are CloudFront-ready. Created
// before the env loop so the prod stack can serve / redirect these domains.
const dnsFoundation = new LmwfDnsFoundationStack(app, 'LmwfDnsFoundationStack', {
  description: 'LiftMark vanity-domain hosted zones + wildcard certs (getlift.md, liftmd.app)',
  env: { account: ENVS.prod.account, region: 'us-east-1' },
  tags: { ...commonTags, Service: 'lmwf-dns' },
  domains: VANITY_DOMAINS,
});

/** Resolve a vanity domain to its {domain, zone, certificate} from the DNS stack. */
function vanityWebDomain(domain: string) {
  const zone = dnsFoundation.zonesByDomain[domain];
  const certificate = dnsFoundation.certsByDomain[domain];
  if (!zone || !certificate) {
    throw new Error(
      `canonical/redirect domain "${domain}" needs a zone + issued cert in VANITY_DOMAINS (issueCert: true)`,
    );
  }
  return { domain, zone, certificate };
}

for (const cfg of Object.values(ENVS)) {
  const prefix = envPrefix(cfg);
  const tags = { ...commonTags, Env: cfg.name };

  // Edge stack — us-east-1 for CloudFront cert + hosted zone owner.
  const edge = new LmwfEdgeStack(app, `${prefix}EdgeStack`, {
    description: `LMWF ${cfg.name} edge (hosted zone + us-east-1 CloudFront cert)`,
    env: { account: cfg.account, region: 'us-east-1' },
    crossRegionReferences: true,
    tags,
    envConfig: cfg,
  });

  // When the env canonicalises to a vanity domain, hand the prod stack the
  // canonical site's zone + cert plus each redirect domain's zone + cert.
  const canonicalWeb =
    cfg.canonicalWebDomain && cfg.canonicalWebDomain !== cfg.domainName
      ? vanityWebDomain(cfg.canonicalWebDomain)
      : undefined;
  const redirectWeb = canonicalWeb
    ? (cfg.redirectWebDomains ?? []).map(vanityWebDomain)
    : [];

  // Main stack — Lambda, HTTP API, DDB, CloudFront, DNS, alarms.
  new LmwfValidatorStack(app, `${prefix}ValidatorStack`, {
    description: `LMWF Validator (${cfg.name}) - LiftMark Workout Format validation service`,
    env: { account: cfg.account, region: cfg.region },
    crossRegionReferences: true,
    tags,
    envConfig: cfg,
    hostedZone: edge.hostedZone,
    cloudFrontCertificate: edge.certificate,
    webAclArn: edge.webAclArn,
    canonicalWeb,
    redirectWeb,
  });
}
