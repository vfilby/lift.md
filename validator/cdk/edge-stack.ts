import * as cdk from 'aws-cdk-lib';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as route53 from 'aws-cdk-lib/aws-route53';
import { Construct } from 'constructs';
import type { EnvConfig } from './config';

export interface LmwfEdgeStackProps extends cdk.StackProps {
  envConfig: EnvConfig;
}

/**
 * Edge stack — lives in us-east-1 (CloudFront cert region requirement).
 *
 * Owns the env's Route 53 hosted zone (zones are global but CDK needs them
 * created somewhere) and the CloudFront ACM cert. The main stack reads
 * both via cross-region references.
 */
export class LmwfEdgeStack extends cdk.Stack {
  public readonly hostedZone: route53.HostedZone;
  public readonly certificate: acm.Certificate;

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
