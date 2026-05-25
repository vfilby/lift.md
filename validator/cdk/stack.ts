import * as cdk from 'aws-cdk-lib';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as apigw from 'aws-cdk-lib/aws-apigatewayv2';
import * as integrations from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as route53targets from 'aws-cdk-lib/aws-route53-targets';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as ses from 'aws-cdk-lib/aws-ses';
import { Construct } from 'constructs';
import * as path from 'path';
import type { EnvConfig } from './config';
import { TABLES, type AttributeType, type TableSchema } from '../src/infra/tables';

function toDdbAttributeType(t: AttributeType): dynamodb.AttributeType {
  switch (t) {
    case 'S': return dynamodb.AttributeType.STRING;
    case 'N': return dynamodb.AttributeType.NUMBER;
    case 'B': return dynamodb.AttributeType.BINARY;
  }
}

function createTable(
  scope: Construct,
  schema: TableSchema,
  env: EnvConfig,
): dynamodb.Table {
  const realName = `lmwf-${env.name}-${schema.logicalName}`;

  const table = new dynamodb.Table(scope, `Table-${schema.logicalName}`, {
    tableName: realName,
    partitionKey: {
      name: schema.partitionKey.name,
      type: toDdbAttributeType(schema.partitionKey.type),
    },
    sortKey: schema.sortKey
      ? { name: schema.sortKey.name, type: toDdbAttributeType(schema.sortKey.type) }
      : undefined,
    billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
    encryption: dynamodb.TableEncryption.AWS_MANAGED,
    pointInTimeRecoverySpecification: schema.pointInTimeRecovery
      ? { pointInTimeRecoveryEnabled: true }
      : undefined,
    // Keep data on accidental cdk destroy — never silently dropped.
    removalPolicy: cdk.RemovalPolicy.RETAIN,
  });

  for (const gsi of schema.globalSecondaryIndexes ?? []) {
    table.addGlobalSecondaryIndex({
      indexName: gsi.indexName,
      partitionKey: {
        name: gsi.partitionKey.name,
        type: toDdbAttributeType(gsi.partitionKey.type),
      },
      sortKey: gsi.sortKey
        ? { name: gsi.sortKey.name, type: toDdbAttributeType(gsi.sortKey.type) }
        : undefined,
      projectionType:
        gsi.projection === 'KEYS_ONLY'
          ? dynamodb.ProjectionType.KEYS_ONLY
          : dynamodb.ProjectionType.ALL,
    });
  }

  return table;
}

export interface LmwfValidatorStackProps extends cdk.StackProps {
  envConfig: EnvConfig;
  hostedZone: route53.IHostedZone;
  cloudFrontCertificate: acm.ICertificate;
}

export class LmwfValidatorStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: LmwfValidatorStackProps) {
    super(scope, id, props);

    const { envConfig, hostedZone, cloudFrontCertificate } = props;
    const env = envConfig; // shorthand for the rest of this constructor
    const domainName = env.domainName;

    // ── DynamoDB tables ──
    const tables: Record<string, dynamodb.Table> = {};
    const tableEnv: Record<string, string> = {};
    for (const schema of Object.values(TABLES)) {
      const table = createTable(this, schema, env);
      tables[schema.logicalName] = table;
      tableEnv[`DDB_TABLE_${schema.logicalName.toUpperCase()}`] = table.tableName;
    }

    // ── SES email identity ──
    // Validates the env's apex domain for sending. DKIM/SPF records are
    // auto-published into the hosted zone — `dkimSigning: true` (default)
    // creates the three CNAME records the verification flow needs.
    //
    // We intentionally stay in the SES sandbox for v1: outbound mail only
    // to verified recipients. Promotion to production access is a manual
    // AWS Support ticket — out of scope for IaC.
    const emailIdentity = new ses.EmailIdentity(this, 'EmailIdentity', {
      identity: ses.Identity.publicHostedZone(hostedZone),
      // dkimSigning defaults to true with publicHostedZone — listed
      // explicitly for visibility.
      dkimSigning: true,
    });

    // ── JWT signing secret ──
    // Auto-generated 64-char hex string, rotated manually for now. The
    // value is read at deploy time and injected into the Lambda env;
    // appears as plaintext inside the resolved CloudFormation template
    // but only IAM-authorized principals can read the Lambda config, so
    // the exposure is the same as any other Lambda env var. Acceptable
    // for v1 — revisit if/when we need automated rotation.
    const jwtSigningSecret = new secretsmanager.Secret(this, 'JwtSigningKey', {
      secretName: `lmwf-${env.name}-jwt-signing-key`,
      description: `JWT (HS256) signing key for the ${env.name} validator Lambda`,
      generateSecretString: {
        passwordLength: 64,
        excludePunctuation: true,
        includeSpace: false,
        // Hex-ish alphabet keeps the secret URL-safe and easy to paste
        // into local .env files when debugging.
        excludeCharacters: 'ghijklmnopqrstuvwxyzGHIJKLMNOPQRSTUVWXYZ',
      },
    });

    // ── SMTP credentials (manually managed) ──
    // SES SMTP requires an IAM user converted to SMTP credentials —
    // CDK has no construct for this. The secret must exist before deploy:
    //
    //   SES Console → SMTP settings → Create SMTP credentials, then:
    //   aws secretsmanager create-secret --name lmwf-<env>-smtp-credentials \
    //     --secret-string '{"user":"...","pass":"..."}'
    //
    // We reference the secret by name and read the JSON fields into Lambda
    // env. If the secret is missing at deploy time, CFN will fail with a
    // clear error.
    const smtpSecret = secretsmanager.Secret.fromSecretNameV2(
      this,
      'SmtpCredentials',
      `lmwf-${env.name}-smtp-credentials`,
    );

    // ── Lambda ──
    const validatorLogGroup = new logs.LogGroup(this, 'ValidatorLogGroup', {
      retention: logs.RetentionDays.TWO_WEEKS,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const validatorFn = new lambda.Function(this, 'ValidatorFunction', {
      runtime: lambda.Runtime.NODEJS_22_X,
      architecture: lambda.Architecture.ARM_64,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '..', 'dist')),
      memorySize: 256,
      timeout: cdk.Duration.seconds(10),
      description: `LMWF Validator (${env.name}) — validates LiftMark Workout Format markdown`,
      environment: {
        NODE_ENV: 'production',
        LMWF_ENV: env.name,
        STRIPE_MODE: env.stripeMode,
        // Deploy metadata surfaced via /version endpoint and the
        // X-Validator-Version response header. See
        // spec/services/lmwf-validator.md → Version.
        BUILD_COMMIT: this.node.tryGetContext('buildCommit') ?? 'unknown',
        BUILD_TIMESTAMP:
          this.node.tryGetContext('buildTimestamp') ?? 'unknown',
        ...tableEnv,
        // JWT secret resolved at deploy time from Secrets Manager.
        JWT_SECRET: cdk.SecretValue.secretsManager(jwtSigningSecret.secretArn).unsafeUnwrap(),
        // SMTP — SES STARTTLS endpoint + creds resolved at deploy time
        // from the manually-managed smtpSecret above.
        SMTP_HOST: `email-smtp.${this.region}.amazonaws.com`,
        SMTP_PORT: '587',
        SMTP_FROM: `noreply@${env.domainName}`,
        SMTP_USER: cdk.SecretValue.secretsManager(smtpSecret.secretArn, {
          jsonField: 'user',
        }).unsafeUnwrap(),
        SMTP_PASS: cdk.SecretValue.secretsManager(smtpSecret.secretArn, {
          jsonField: 'pass',
        }).unsafeUnwrap(),
      },
      logGroup: validatorLogGroup,
    });

    // Keep the email identity around so CFN doesn't garbage-collect the
    // verification records before the Lambda first sends.
    validatorFn.node.addDependency(emailIdentity);

    for (const table of Object.values(tables)) {
      table.grantReadWriteData(validatorFn);
    }

    // ── HTTP API ──
    const httpApi = new apigw.HttpApi(this, 'ValidatorApi', {
      apiName: `lmwf-validator-${env.name}`,
      description: `LMWF Validator API (${env.name}) — CloudFront origin`,
      corsPreflight: {
        allowOrigins: ['*'],
        allowMethods: [apigw.CorsHttpMethod.POST, apigw.CorsHttpMethod.OPTIONS],
        allowHeaders: ['Content-Type', 'Authorization'],
        maxAge: cdk.Duration.hours(24),
      },
    });

    const cfnStage = httpApi.defaultStage?.node.defaultChild as apigw.CfnStage;
    if (cfnStage) {
      cfnStage.defaultRouteSettings = {
        throttlingBurstLimit: 10,
        throttlingRateLimit: 5,
      };
    }

    const validatorIntegration = new integrations.HttpLambdaIntegration(
      'ValidatorIntegration',
      validatorFn,
    );

    httpApi.addRoutes({
      path: '/validate',
      methods: [apigw.HttpMethod.POST],
      integration: validatorIntegration,
    });

    httpApi.addRoutes({
      path: '/version',
      methods: [apigw.HttpMethod.GET],
      integration: validatorIntegration,
    });

    // All new auth/PAT/workout routes — Hono routes inside Lambda.
    httpApi.addRoutes({
      path: '/v1/{proxy+}',
      methods: [apigw.HttpMethod.ANY],
      integration: validatorIntegration,
    });

    const apiHostname = `${httpApi.httpApiId}.execute-api.${this.region}.amazonaws.com`;

    // ── S3 site bucket ──
    const siteBucket = new s3.Bucket(this, 'SiteBucket', {
      bucketName: `liftmark-${env.name}-site-${this.account}`,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      versioned: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // ── CloudFront ──
    const urlRewriteFunction = new cloudfront.Function(this, 'UrlRewriteFn', {
      code: cloudfront.FunctionCode.fromInline(`
function handler(event) {
  var request = event.request;
  var uri = request.uri;
  if (uri.endsWith('/')) {
    request.uri = uri + 'index.html';
  } else {
    var last = uri.split('/').pop();
    if (last.indexOf('.') === -1) {
      request.uri = uri + '/index.html';
    }
  }
  return request;
}
      `),
      comment: 'Rewrite /foo and /foo/ to /foo/index.html',
    });

    const s3Origin = origins.S3BucketOrigin.withOriginAccessControl(siteBucket);
    const apiOrigin = new origins.HttpOrigin(apiHostname, {
      protocolPolicy: cloudfront.OriginProtocolPolicy.HTTPS_ONLY,
    });

    // Prod CloudFront answers for both the apex (liftmark.app) and the
    // legacy workoutformat.liftmark.app subdomain. Wildcard SAN on the cert
    // (`*.liftmark.app`) already covers it.
    const cfDomainNames =
      env.name === 'prod'
        ? [domainName, `workoutformat.${domainName}`]
        : [domainName];

    const distribution = new cloudfront.Distribution(this, 'SiteDistribution', {
      defaultRootObject: 'index.html',
      domainNames: cfDomainNames,
      certificate: cloudFrontCertificate,
      priceClass: cloudfront.PriceClass.PRICE_CLASS_100,
      httpVersion: cloudfront.HttpVersion.HTTP2_AND_3,
      minimumProtocolVersion: cloudfront.SecurityPolicyProtocol.TLS_V1_2_2021,
      comment: `LMWF ${env.name} — ${domainName} (S3 static + /validate origin)`,
      defaultBehavior: {
        origin: s3Origin,
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        cachePolicy:
          env.name === 'beta'
            ? cloudfront.CachePolicy.CACHING_DISABLED
            : cloudfront.CachePolicy.CACHING_OPTIMIZED,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD_OPTIONS,
        compress: true,
        functionAssociations: [{
          eventType: cloudfront.FunctionEventType.VIEWER_REQUEST,
          function: urlRewriteFunction,
        }],
      },
      additionalBehaviors: {
        '/validate': {
          origin: apiOrigin,
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
          cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
          originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
          allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
          compress: false,
        },
        '/v1/*': {
          origin: apiOrigin,
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
          cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
          originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
          allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
          compress: true,
        },
        '/version': {
          origin: apiOrigin,
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
          cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
          originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
          allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
          compress: true,
        },
      },
    });

    // ── DNS: env's apex → CloudFront ──
    new route53.ARecord(this, 'ValidatorAliasRecord', {
      zone: hostedZone,
      // Apex record — recordName intentionally omitted.
      target: route53.RecordTarget.fromAlias(
        new route53targets.CloudFrontTarget(distribution),
      ),
    });
    new route53.AaaaRecord(this, 'ValidatorAliasRecordIpv6', {
      zone: hostedZone,
      target: route53.RecordTarget.fromAlias(
        new route53targets.CloudFrontTarget(distribution),
      ),
    });

    // Prod-only: apex zone owns the brand. Delegate beta as a subdomain and
    // keep the legacy workoutformat.liftmark.app subdomain pointing at the
    // current prod CloudFront so existing callers (iOS, docs, links) keep
    // resolving after the registrar cuts NS over to the new apex HZ.
    if (env.name === 'prod') {
      // NS delegation for beta.liftmark.app → beta-account HZ name servers.
      // Hardcoded because cross-account HZ lookup needs extra IAM and the
      // beta NS set is stable (only changes if the beta HZ is destroyed).
      new route53.NsRecord(this, 'BetaSubdomainDelegation', {
        zone: hostedZone,
        recordName: 'beta',
        values: [
          'ns-991.awsdns-59.net.',
          'ns-56.awsdns-07.com.',
          'ns-1444.awsdns-52.org.',
          'ns-1938.awsdns-50.co.uk.',
        ],
        ttl: cdk.Duration.minutes(5),
      });

      // workoutformat.liftmark.app → same CloudFront as the apex. The legacy
      // subdomain becomes a permanent alias for the new prod stack; old prod
      // CloudFront/Lambda in account 341556346945 can be decommissioned once
      // this is live.
      new route53.ARecord(this, 'WorkoutFormatAliasRecord', {
        zone: hostedZone,
        recordName: 'workoutformat',
        target: route53.RecordTarget.fromAlias(
          new route53targets.CloudFrontTarget(distribution),
        ),
      });
      new route53.AaaaRecord(this, 'WorkoutFormatAliasRecordIpv6', {
        zone: hostedZone,
        recordName: 'workoutformat',
        target: route53.RecordTarget.fromAlias(
          new route53targets.CloudFrontTarget(distribution),
        ),
      });
    }

    // ── CloudWatch alarms ──
    new cloudwatch.Alarm(this, 'LambdaErrorAlarm', {
      metric: validatorFn.metricErrors({ period: cdk.Duration.minutes(5) }),
      threshold: 5,
      evaluationPeriods: 1,
      alarmDescription: `[${env.name}] Lambda error count > 5 in 5 minutes`,
    });

    new cloudwatch.Alarm(this, 'LambdaDurationAlarm', {
      metric: validatorFn.metricDuration({ period: cdk.Duration.minutes(5), statistic: 'p99' }),
      threshold: 5000,
      evaluationPeriods: 1,
      alarmDescription: `[${env.name}] Lambda p99 latency > 5s (timeout is 10s)`,
    });

    new cloudwatch.Alarm(this, 'LambdaThrottleAlarm', {
      metric: validatorFn.metricThrottles({ period: cdk.Duration.minutes(5) }),
      threshold: 1,
      evaluationPeriods: 1,
      alarmDescription: `[${env.name}] Lambda throttles detected`,
    });

    new cloudwatch.Alarm(this, 'ApiGateway5xxAlarm', {
      metric: new cloudwatch.Metric({
        namespace: 'AWS/ApiGateway',
        metricName: '5xx',
        dimensionsMap: { ApiId: httpApi.httpApiId },
        period: cdk.Duration.minutes(5),
        statistic: 'Sum',
      }),
      threshold: 5,
      evaluationPeriods: 1,
      alarmDescription: `[${env.name}] API Gateway 5xx count > 5 in 5 minutes`,
    });

    // ── Outputs ──
    new cdk.CfnOutput(this, 'SiteUrl', {
      value: `https://${domainName}`,
      description: 'Public site URL (served via CloudFront)',
    });

    new cdk.CfnOutput(this, 'ValidateEndpoint', {
      value: `https://${domainName}/validate`,
      description: 'URL for the LMWF validation endpoint',
    });

    new cdk.CfnOutput(this, 'SiteBucketName', {
      value: siteBucket.bucketName,
      description: 'S3 bucket for static site assets',
    });

    new cdk.CfnOutput(this, 'DistributionId', {
      value: distribution.distributionId,
      description: 'CloudFront distribution ID (for cache invalidation)',
    });

    new cdk.CfnOutput(this, 'FunctionName', {
      value: validatorFn.functionName,
    });
  }
}
