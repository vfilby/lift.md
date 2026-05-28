#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { ENVS, envPrefix } from './config';
import { LmwfEdgeStack } from './edge-stack';
import { LmwfValidatorStack } from './stack';

const app = new cdk.App();

const commonTags = {
  Project: 'LiftMark',
  Service: 'lmwf-validator',
};

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
  });
}
