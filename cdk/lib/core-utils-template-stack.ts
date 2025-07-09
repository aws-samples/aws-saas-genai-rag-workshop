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

      // environmentVariablesToOutgoingEvent: ["tenantStatus", "tenantConfig"],
      environmentVariablesToOutgoingEvent: {tenantData:[
        'tenantS3Bucket',
        'tenantConfig',
        // 'tenantStatus',
        'prices', // added so we don't lose it for targets beyond provisioning (ex. billing)
        'tenantName', // added so we don't lose it for targets beyond provisioning (ex. billing)
        'email', // added so we don't lose it for targets beyond provisioning (ex. billing)
      ],
      tenantRegistrationData: ['registrationStatus'],
     },
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
