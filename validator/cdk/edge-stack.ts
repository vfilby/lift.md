import * as cdk from 'aws-cdk-lib';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as wafv2 from 'aws-cdk-lib/aws-wafv2';
import { Construct } from 'constructs';
import type { EnvConfig } from './config';

export interface LmwfEdgeStackProps extends cdk.StackProps {
  envConfig: EnvConfig;
}

/**
 * Edge stack — lives in us-east-1 (CloudFront cert region requirement).
 *
 * Owns the env's Route 53 hosted zone (zones are global but CDK needs them
 * created somewhere), the CloudFront ACM cert, and the CLOUDFRONT-scoped
 * WAFv2 web ACL (which also must live in us-east-1). The main stack reads
 * all three via cross-region references.
 */
export class LmwfEdgeStack extends cdk.Stack {
  public readonly hostedZone: route53.HostedZone;
  public readonly certificate: acm.Certificate;
  /** ARN of the CLOUDFRONT-scoped web ACL — wired to the distribution's webAclId. */
  public readonly webAclArn: string;

  constructor(scope: Construct, id: string, props: LmwfEdgeStackProps) {
    super(scope, id, props);

    const { envConfig } = props;

    this.hostedZone = new route53.HostedZone(this, 'EnvZone', {
      zoneName: envConfig.domainName,
      comment: `LiftMark ${envConfig.name} env — created by CDK`,
    });

    this.certificate = new acm.Certificate(this, 'CloudFrontCert', {
      domainName: envConfig.domainName,
      // Wildcard SAN covers future subdomains (api.*, www.*) without a
      // cert rotation.
      subjectAlternativeNames: [`*.${envConfig.domainName}`],
      validation: acm.CertificateValidation.fromDns(this.hostedZone),
    });

    // ── WAFv2 web ACL (CLOUDFRONT scope) ──
    // CLOUDFRONT-scoped web ACLs MUST be created in us-east-1, so this lives
    // in the edge stack alongside the cert. The ARN is exported and wired to
    // the distribution's `webAclId` in the main stack via crossRegionReferences
    // (same SSM-parameter mechanism the cert + hosted zone already use).
    //
    // Rule priorities are explicit and ordered: the targeted auth rate rule
    // runs before the broad rate rule so credential-stuffing on /v1/auth/* is
    // blunted at a much lower threshold than general traffic.
    const namePrefix = `lmwf-${envConfig.name}`;
    const webAcl = new wafv2.CfnWebACL(this, 'EdgeWebAcl', {
      name: `${namePrefix}-cloudfront`,
      scope: 'CLOUDFRONT',
      defaultAction: { allow: {} },
      // WAFv2 description is regex-constrained (no em-dash / non-ASCII punctuation).
      description: `LMWF ${envConfig.name} CloudFront WAF - managed rules and rate limits`,
      // CloudFront inspects only the first 16 KB of a request body by default.
      // Completed-workout outbox pushes (POST /v1/workouts/outbox) routinely
      // exceed that (a real session is ~19 KB+), so raise the inspection window
      // to 64 KB. Without this, large bodies sail past the managed rules
      // uninspected; with it (plus the SizeRestrictions_BODY override below)
      // they are scanned and allowed instead of blocked. Adds WCU but stays
      // well within the default 1500 WCU ceiling.
      associationConfig: {
        requestBody: {
          CLOUDFRONT: { defaultSizeInspectionLimit: 'KB_64' },
        },
      },
      visibilityConfig: {
        cloudWatchMetricsEnabled: true,
        metricName: `${namePrefix}-cloudfront-acl`,
        sampledRequestsEnabled: true,
      },
      rules: [
        // Stricter rate-based rule scoped to /v1/auth/* to blunt
        // credential-stuffing / password-spray. The scope-down statement
        // limits the count to requests whose URI path starts with /v1/auth/.
        // L2 follow-up: the per-account application lockout half (a DDB
        // counter table keyed on identity) is intentionally deferred — this
        // rule only covers the per-IP abuse half.
        {
          name: 'AuthPathRateLimit',
          priority: 0,
          action: { block: {} },
          statement: {
            rateBasedStatement: {
              limit: 100, // requests per 5-min window, per source IP
              aggregateKeyType: 'IP',
              scopeDownStatement: {
                byteMatchStatement: {
                  fieldToMatch: { uriPath: {} },
                  positionalConstraint: 'STARTS_WITH',
                  searchString: '/v1/auth/',
                  textTransformations: [
                    { priority: 0, type: 'LOWERCASE' },
                  ],
                },
              },
            },
          },
          visibilityConfig: {
            cloudWatchMetricsEnabled: true,
            metricName: `${namePrefix}-auth-rate`,
            sampledRequestsEnabled: true,
          },
        },
        // Broad per-IP rate limit across all paths.
        {
          name: 'GlobalRateLimit',
          priority: 1,
          action: { block: {} },
          statement: {
            rateBasedStatement: {
              limit: 2000, // requests per 5-min window, per source IP
              aggregateKeyType: 'IP',
            },
          },
          visibilityConfig: {
            cloudWatchMetricsEnabled: true,
            metricName: `${namePrefix}-global-rate`,
            sampledRequestsEnabled: true,
          },
        },
        // AWS managed rule groups. `none: {}` override keeps the group's own
        // rule actions (block) in force.
        {
          name: 'AWSManagedRulesCommonRuleSet',
          priority: 2,
          overrideAction: { none: {} },
          statement: {
            managedRuleGroupStatement: {
              vendorName: 'AWS',
              name: 'AWSManagedRulesCommonRuleSet',
              // SizeRestrictions_BODY blocks any request body > 8 KB. That
              // silently kills legitimate large outbox pushes at the edge
              // (CloudFront 403 before the request ever reaches the API), so
              // a finished workout of any real size never syncs. Demote it to
              // Count: the outbox route enforces its own 1 MB body cap and the
              // rate-based rules above still bound abuse. All other CRS rules
              // (SQLi/XSS/etc.) keep their default Block action.
              ruleActionOverrides: [
                {
                  name: 'SizeRestrictions_BODY',
                  actionToUse: { count: {} },
                },
              ],
            },
          },
          visibilityConfig: {
            cloudWatchMetricsEnabled: true,
            metricName: `${namePrefix}-common`,
            sampledRequestsEnabled: true,
          },
        },
        {
          name: 'AWSManagedRulesKnownBadInputsRuleSet',
          priority: 3,
          overrideAction: { none: {} },
          statement: {
            managedRuleGroupStatement: {
              vendorName: 'AWS',
              name: 'AWSManagedRulesKnownBadInputsRuleSet',
            },
          },
          visibilityConfig: {
            cloudWatchMetricsEnabled: true,
            metricName: `${namePrefix}-known-bad-inputs`,
            sampledRequestsEnabled: true,
          },
        },
        {
          name: 'AWSManagedRulesAmazonIpReputationList',
          priority: 4,
          overrideAction: { none: {} },
          statement: {
            managedRuleGroupStatement: {
              vendorName: 'AWS',
              name: 'AWSManagedRulesAmazonIpReputationList',
            },
          },
          visibilityConfig: {
            cloudWatchMetricsEnabled: true,
            metricName: `${namePrefix}-ip-reputation`,
            sampledRequestsEnabled: true,
          },
        },
      ],
    });
    this.webAclArn = webAcl.attrArn;

    new cdk.CfnOutput(this, 'WebAclArn', {
      value: this.webAclArn,
      description: 'CLOUDFRONT-scoped WAFv2 web ACL ARN (wired to the distribution)',
    });

    new cdk.CfnOutput(this, 'HostedZoneId', {
      value: this.hostedZone.hostedZoneId,
      description: `Hosted zone ID for ${envConfig.domainName}`,
    });

    new cdk.CfnOutput(this, 'HostedZoneNameServers', {
      value: cdk.Fn.join(',', this.hostedZone.hostedZoneNameServers ?? []),
      description: `Update the registrar (or parent zone) to delegate to these name servers`,
    });
  }
}
