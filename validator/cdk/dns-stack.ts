import * as cdk from 'aws-cdk-lib';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as route53 from 'aws-cdk-lib/aws-route53';
import { Construct } from 'constructs';
import type { MigaduMail, VanityDomain } from './config';

export interface LmwfDnsFoundationStackProps extends cdk.StackProps {
  /** Vanity / redirect domains to create a zone (+ optional wildcard cert) for. */
  domains: readonly VanityDomain[];
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
  /** Hosted zone per vanity domain, for other stacks to add records to. */
  public readonly zonesByDomain: Record<string, route53.IHostedZone> = {};
  /**
   * Issued wildcard cert per vanity domain (us-east-1, CloudFront-ready).
   * Only present for domains with `issueCert: true`.
   */
  public readonly certsByDomain: Record<string, acm.ICertificate> = {};

  constructor(scope: Construct, id: string, props: LmwfDnsFoundationStackProps) {
    super(scope, id, props);

    for (const { domain, issueCert, mail } of props.domains) {
      const cid = domainToConstructId(domain);

      const zone = new route53.HostedZone(this, `${cid}Zone`, {
        zoneName: domain,
        comment: `LiftMark vanity domain ${domain} — created by CDK`,
      });
      this.zonesByDomain[domain] = zone;

      // Deferred until the domain is registered + delegated (see VanityDomain
      // docs): a DNS-validated cert blocks the whole stack's CREATE until it
      // validates, which an undelegated domain never does.
      if (issueCert) {
        this.certsByDomain[domain] = new acm.Certificate(this, `${cid}Cert`, {
          domainName: domain,
          // Wildcard SAN covers future subdomains (www.*, app.*, …) without a
          // cert rotation — mirrors the per-env edge cert.
          subjectAlternativeNames: [`*.${domain}`],
          validation: acm.CertificateValidation.fromDns(zone),
        });
      }

      if (mail) {
        addMigaduRecords(this, cid, zone, mail);
      }

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

/** Migadu's DNS guide publishes every record at 3000s; mirror it exactly. */
const MIGADU_TTL = cdk.Duration.seconds(3000);

/**
 * Publish the standard Migadu hosted-mail record set in `zone` (apex =
 * `zone.zoneName`). One construct per record name+type so Route 53 never sees
 * two record sets for the same pair — in particular the apex TXT carries both
 * the ownership token and the SPF string as two values of a single set.
 */
function addMigaduRecords(
  scope: Construct,
  cid: string,
  zone: route53.IHostedZone,
  mail: MigaduMail,
): void {
  const domain = zone.zoneName;
  const migaduSrv = (port: number, host: string): route53.SrvRecordValue => ({
    priority: 0,
    weight: 1,
    port,
    hostName: `${host}.migadu.com.`,
  });

  new route53.MxRecord(scope, `${cid}MailMx`, {
    zone,
    ttl: MIGADU_TTL,
    values: [
      { priority: 10, hostName: 'aspmx1.migadu.com.' },
      { priority: 20, hostName: 'aspmx2.migadu.com.' },
    ],
  });

  new route53.TxtRecord(scope, `${cid}MailApexTxt`, {
    zone,
    ttl: MIGADU_TTL,
    values: [`hosted-email-verify=${mail.verifyToken}`, 'v=spf1 include:spf.migadu.com -all'],
  });

  new route53.TxtRecord(scope, `${cid}MailDmarc`, {
    zone,
    ttl: MIGADU_TTL,
    recordName: '_dmarc',
    values: [mail.dmarcPolicy],
  });

  // DKIM: Migadu rotates signing keys behind these three CNAMEs.
  for (const n of [1, 2, 3]) {
    new route53.CnameRecord(scope, `${cid}MailDkim${n}`, {
      zone,
      ttl: MIGADU_TTL,
      recordName: `key${n}._domainkey`,
      domainName: `key${n}.${domain}._domainkey.migadu.com.`,
    });
  }

  // Client auto-configuration (Thunderbird-style autoconfig + Outlook autodiscover).
  new route53.CnameRecord(scope, `${cid}MailAutoconfig`, {
    zone,
    ttl: MIGADU_TTL,
    recordName: 'autoconfig',
    domainName: 'autoconfig.migadu.com.',
  });
  new route53.SrvRecord(scope, `${cid}MailAutodiscover`, {
    zone,
    ttl: MIGADU_TTL,
    recordName: '_autodiscover._tcp',
    values: [migaduSrv(443, 'autodiscover')],
  });

  // Client service discovery (RFC 6186).
  new route53.SrvRecord(scope, `${cid}MailSubmissions`, {
    zone,
    ttl: MIGADU_TTL,
    recordName: '_submissions._tcp',
    values: [migaduSrv(465, 'smtp')],
  });
  new route53.SrvRecord(scope, `${cid}MailImaps`, {
    zone,
    ttl: MIGADU_TTL,
    recordName: '_imaps._tcp',
    values: [migaduSrv(993, 'imap')],
  });
  new route53.SrvRecord(scope, `${cid}MailPop3s`, {
    zone,
    ttl: MIGADU_TTL,
    recordName: '_pop3s._tcp',
    values: [migaduSrv(995, 'pop')],
  });
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
