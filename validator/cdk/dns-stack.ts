import * as cdk from 'aws-cdk-lib';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as route53 from 'aws-cdk-lib/aws-route53';
import { Construct } from 'constructs';

export interface LmwfDnsFoundationStackProps extends cdk.StackProps {
  /** Vanity / redirect domains to create a zone + wildcard cert for. */
  domains: readonly string[];
}

/**
 * DNS foundation stack — long-lived Route 53 hosted zones (+ wildcard ACM
 * certs) for vanity / redirect domains that are NOT tied to a validator env.
 *
 * Kept deliberately separate from the per-env edge + validator stacks: these
 * zones own the registrar delegation — their NS records are pasted into each
 * registrar exactly once — so they must outlive any app-stack `cdk destroy`.
 * A validator teardown must never orphan these delegations.
 *
 * Lives in us-east-1 so the wildcard certs are directly usable by a future
 * CloudFront distribution without a cross-region cert lookup.
 *
 * Deploy ordering (DNS-validated certs need a resolvable zone):
 *   1. `cdk deploy` creates the hosted zones quickly, then BLOCKS on ACM
 *      validation of each cert.
 *   2. While it blocks, read each zone's NS records (Route 53 console or
 *      `aws route53 list-hosted-zones` / `get-hosted-zone`) and paste them
 *      into the matching registrar.
 *   3. Once delegation propagates, ACM validates and the deploy completes,
 *      printing the NS records as stack outputs for the record.
 * If a registrar is slow, the cert resource can time out — re-run the deploy
 * after delegation lands; the zone already exists so it's idempotent.
 */
export class LmwfDnsFoundationStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: LmwfDnsFoundationStackProps) {
    super(scope, id, props);

    for (const domain of props.domains) {
      const cid = domainToConstructId(domain);

      const zone = new route53.HostedZone(this, `${cid}Zone`, {
        zoneName: domain,
        comment: `LiftMark vanity domain ${domain} — created by CDK`,
      });

      new acm.Certificate(this, `${cid}Cert`, {
        domainName: domain,
        // Wildcard SAN covers future subdomains (www.*, app.*, …) without a
        // cert rotation — mirrors the per-env edge cert.
        subjectAlternativeNames: [`*.${domain}`],
        validation: acm.CertificateValidation.fromDns(zone),
      });

      new cdk.CfnOutput(this, `${cid}ZoneId`, {
        value: zone.hostedZoneId,
        description: `Hosted zone ID for ${domain}`,
      });

      new cdk.CfnOutput(this, `${cid}NameServers`, {
        value: cdk.Fn.join(',', zone.hostedZoneNameServers ?? []),
        description: `Delegate ${domain} at the registrar to these name servers`,
      });
    }
  }
}

/**
 * Turn a domain into a PascalCase construct-id prefix.
 * `getlift.md` → `GetliftMd`, `liftmd.app` → `LiftmdApp`.
 */
function domainToConstructId(domain: string): string {
  return domain
    .split(/[.-]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1).toLowerCase())
    .join('');
}
