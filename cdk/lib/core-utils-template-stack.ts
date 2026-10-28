// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

import { Stack, StackProps } from "aws-cdk-lib";
import { Construct } from "constructs";
import { PolicyDocument } from "aws-cdk-lib/aws-iam";
import { Project } from "aws-cdk-lib/aws-codebuild";
import {
  CoreApplicationPlane,
  EventManager,
  ControlPlane,
  ProvisioningScriptJob,
  DeprovisioningScriptJob,
  TenantLifecycleScriptJobProps
} from "@cdklabs/sbt-aws";
import * as fs from "fs";
// The prefix constant is shared so this policy cannot drift from the path the
// provisioning script actually writes to. Only the prefix is shared -- the
// scopes below it deliberately differ, and the difference matters:
//
//   this policy (provisioning job)  <prefix>/*            Get + Put
//   services.ts (request authorizer) <prefix>/*/api-key    Get
//
// The provisioning job is the principal that creates both secrets, so it needs
// the whole subtree: user_management_service.py writes
// <prefix>/<tenantId>/users/<email>/password and reads it back to stay
// idempotent across re-provisioning. The authorizer only needs to read the API
// key on the request path, and an SSM wildcard spans '/', so granting it the
// subtree would hand every request the stored user passwords as well. Hence the
// narrower leaf there and the broader scope here.
import { TENANT_PARAMETER_PREFIX } from "./tenant-template/services";

interface CoreUtilsTemplateStackProps extends StackProps {
  readonly controlPlane: ControlPlane;
}

export class CoreUitlsTemplateStack extends Stack {
  public readonly codeBuildProject: Project;

  constructor(
    scope: Construct,
    id: string,
    props: CoreUtilsTemplateStackProps
  ) {
    super(scope, id, props);

    const provisioningScriptJobProps: TenantLifecycleScriptJobProps = {
      permissions: PolicyDocument.fromJson(
        JSON.parse(`
        {
          "Version": "2012-10-17",
          "Statement": [
              {
                  "Effect": "Allow",
                  "Action": [
                      "cloudformation:DescribeStacks",
                      "cognito-idp:AdminCreateUser",
                      "cognito-idp:AdminSetUserPassword",
                      "cognito-idp:AdminUpdateUserAttributes",
                      "cognito-idp:AdminGetUser",
                      "cognito-idp:CreateGroup",
                      "cognito-idp:AdminAddUserToGroup",
                      "cognito-idp:GetGroup",
                      "s3:PutObject",
                      "s3:GetObject",
                      "s3:ListBucket",
                      "lambda:AddPermission",
                      "events:PutRule",
                      "events:PutTargets",
                      "iam:CreateRole",
                      "iam:GetRole",
                      "iam:PutRolePolicy",
                      "iam:PassRole",
                      "bedrock:CreateKnowledgeBase",
                      "bedrock:CreateDataSource",
                      "bedrock:CreateKnowledgeBase",
                      "bedrock:InvokeModel",
                      "bedrock:ListKnowledgeBases",
                      "aoss:CreateAccessPolicy",
                      "aoss:BatchGetCollection",
                      "aoss:APIAccessAll",
                      "codecommit:GetRepository",
                      "codecommit:GitPull",
                      "apigateway:*"
                  ],
                  "Resource": "*"
              },
              {
                  "Effect": "Allow",
                  "Action": [
                      "ssm:GetParameter",
                      "ssm:PutParameter"
                  ],
                  "Resource": "arn:aws:ssm:${this.region}:${this.account}:parameter${TENANT_PARAMETER_PREFIX}/*"
              }
          ]
      }
  `)
      ),
      script: fs.readFileSync("../scripts/provision-tenant.sh", "utf8"),
      environmentStringVariablesFromIncomingEvent: [
        "tenantId",
        "tenantName",
        "email",
        "tier",
      ],
      environmentJSONVariablesFromIncomingEvent: ['prices'],

      environmentVariablesToOutgoingEvent: {
        tenantData:[
          'tenantS3Bucket',
          'tenantConfig',
          'prices', // added so we don't lose it for targets beyond provisioning (ex. billing)
          'tenantName', // added so we don't lose it for targets beyond provisioning (ex. billing)
          'email', // added so we don't lose it for targets beyond provisioning (ex. billing)
        ],
        tenantRegistrationData: ['registrationStatus'],
     },
     scriptEnvironmentVariables: {},
     eventManager: props.controlPlane.eventManager,
    };

    const provisioningScriptJob: ProvisioningScriptJob = new ProvisioningScriptJob(
      this,
      'provisioningScriptJob', 
      provisioningScriptJobProps
    );

    this.codeBuildProject = provisioningScriptJob.codebuildProject;

    // TODO: Lab1 - Add SBT core utils component
    new CoreApplicationPlane(this, "CoreApplicationPlane", {
      eventManager: props.controlPlane.eventManager,
      scriptJobs: [provisioningScriptJob],
    });
  }
}
