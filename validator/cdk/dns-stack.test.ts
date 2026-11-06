import { describe, it, expect } from 'vitest';
import * as cdk from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { LmwfDnsFoundationStack } from './dns-stack';
import { VANITY_DOMAINS, type VanityDomain } from './config';

/**
 * Spec: spec/services/lmwf-validator.md → "Mail for getlift.md (Migadu)".
 * Synthesises the DNS foundation stack and asserts the exact Migadu record set
 * lands in the mail domain's zone, and nowhere else.
 */

const MAIL = { verifyToken: 'tok123', dmarcPolicy: 'v=DMARC1; p=quarantine;' };

function synth(domains: readonly VanityDomain[]): Template {
  const app = new cdk.App();
  const stack = new LmwfDnsFoundationStack(app, 'TestDns', {
    env: { account: '111111111111', region: 'us-east-1' },
    domains,
  });
  return Template.fromStack(stack);
}

/** Every record set in the template, keyed by `Name|Type` for lookup. */
function recordSets(t: Template): Map<string, Record<string, unknown>> {
  const out = new Map<string, Record<string, unknown>>();
  for (const r of Object.values(t.findResources('AWS::Route53::RecordSet'))) {
    const p = r.Properties as Record<string, unknown>;
    out.set(`${p.Name}|${p.Type}`, p);
  }
  return out;
}

describe('LmwfDnsFoundationStack — Migadu mail records', () => {
  const t = synth([
    { domain: 'getlift.md', issueCert: false, mail: MAIL },
    { domain: 'liftmd.app', issueCert: false },
  ]);
  const rs = recordSets(t);

  it('publishes MX for both Migadu inbound hosts with the given priorities', () => {
    expect(rs.get('getlift.md.|MX')).toMatchObject({
      TTL: '3000',
      ResourceRecords: ['10 aspmx1.migadu.com.', '20 aspmx2.migadu.com.'],
    });
  });

  it('puts the ownership token and a strict SPF in ONE apex TXT record set', () => {
    // Route 53 allows a single TXT set per name; two TxtRecord constructs for
    // the apex would fail at deploy time, so they must be values of one set.
    const apexTxt = rs.get('getlift.md.|TXT');
    expect(apexTxt).toMatchObject({
      TTL: '3000',
      ResourceRecords: ['"hosted-email-verify=tok123"', '"v=spf1 include:spf.migadu.com -all"'],
    });
    const spf = (apexTxt!.ResourceRecords as string[]).find((v) => v.includes('v=spf1'));
    expect(spf).toMatch(/-all"$/);
  });

  it('publishes the configured DMARC policy', () => {
    expect(rs.get('_dmarc.getlift.md.|TXT')).toMatchObject({
      TTL: '3000',
      ResourceRecords: ['"v=DMARC1; p=quarantine;"'],
    });
  });

  it('delegates DKIM key1..key3 to Migadu via CNAME', () => {
    for (const n of [1, 2, 3]) {
      expect(rs.get(`key${n}._domainkey.getlift.md.|CNAME`)).toMatchObject({
        TTL: '3000',
        ResourceRecords: [`key${n}.getlift.md._domainkey.migadu.com.`],
      });
    }
  });

  it('publishes autoconfig CNAME + autodiscover SRV', () => {
    expect(rs.get('autoconfig.getlift.md.|CNAME')).toMatchObject({
      ResourceRecords: ['autoconfig.migadu.com.'],
    });
    expect(rs.get('_autodiscover._tcp.getlift.md.|SRV')).toMatchObject({
      ResourceRecords: ['0 1 443 autodiscover.migadu.com.'],
    });
  });

  it('publishes RFC 6186 client SRV records for submissions/imaps/pop3s', () => {
    expect(rs.get('_submissions._tcp.getlift.md.|SRV')).toMatchObject({
      ResourceRecords: ['0 1 465 smtp.migadu.com.'],
    });
    expect(rs.get('_imaps._tcp.getlift.md.|SRV')).toMatchObject({
      ResourceRecords: ['0 1 993 imap.migadu.com.'],
    });
    expect(rs.get('_pop3s._tcp.getlift.md.|SRV')).toMatchObject({
      ResourceRecords: ['0 1 995 pop.migadu.com.'],
    });
  });

  it('every mail record lives in the mail domain’s own hosted zone', () => {
    const zones = t.findResources('AWS::Route53::HostedZone', {
      Properties: { Name: 'getlift.md.' },
    });
    const [zoneLogicalId] = Object.keys(zones);
    expect(zoneLogicalId).toBeDefined();
    for (const [key, p] of rs) {
      if (!key.includes('getlift.md.')) continue;
      expect(p.HostedZoneId, key).toEqual({ Ref: zoneLogicalId });
    }
  });

  it('creates exactly the Migadu record set and nothing else for the mail domain', () => {
    // 1 MX + 2 TXT + 4 CNAME + 4 SRV = 11 (no cert → no ACM validation records).
    t.resourceCountIs('AWS::Route53::RecordSet', 11);
  });

  it('creates no mail records for a domain without a `mail` block', () => {
    t.resourcePropertiesCountIs(
      'AWS::Route53::RecordSet',
      { Name: Match.stringLikeRegexp('liftmd\\.app\\.$') },
      0,
    );
  });
});

describe('VANITY_DOMAINS config', () => {
  it('enables Migadu mail on getlift.md only, with a strict DMARC policy', () => {
    const withMail = VANITY_DOMAINS.filter((d) => d.mail);
    expect(withMail.map((d) => d.domain)).toEqual(['getlift.md']);
    expect(withMail[0]!.mail!.dmarcPolicy).toMatch(/^v=DMARC1; p=(quarantine|reject);/);
    expect(withMail[0]!.mail!.verifyToken).toMatch(/^[a-z0-9]+$/);
  });
});
