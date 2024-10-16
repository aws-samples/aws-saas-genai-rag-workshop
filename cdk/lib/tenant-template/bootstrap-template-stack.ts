// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import {
  RemovalPolicy,
  Stack,
  StackProps,
  CfnOutput,
  Aspects,
} from "aws-cdk-lib";
import { Construct } from "constructs";
import { Role, ServicePrincipal, ManagedPolicy } from "aws-cdk-lib/aws-iam";
import * as path from "path";
import * as python from "@aws-cdk/aws-lambda-python-alpha";
import * as lambda from "aws-cdk-lib/aws-lambda";

import { IdentityProvider } from "./identity-provider";
import { opensearchserverless } from "@cdklabs/generative-ai-cdk-constructs";
import * as aoss from "aws-cdk-lib/aws-opensearchserverless";
import { Bucket } from "aws-cdk-lib/aws-s3";
import { ApiGateway } from "./api-gateway";
import { Services } from "./services";
import { BedrockCustom } from "./bedrock";
import { CoreUitlsTemplateStack } from "../core-utils-template-stack";
import { CostPerTenant } from "./cost-per-tenant";
import { TenantTokenUsage } from "./tenant-token-usage";
import { DestroyPolicySetter } from "../destory-policy-setter";
import { CurAthena } from "./cur-athena";
import { CostUsageReportUpload } from "./cur-report-upload";

interface BootstrapTemplateStackProps extends StackProps {
  readonly coreUtilsStack: CoreUitlsTemplateStack;
  readonly controlPlaneApiGwUrl: string;
}

export class BootstrapTemplateStack extends Stack {
  constructor(
    scope: Construct,
    id: string,
    props: BootstrapTemplateStackProps
  ) {
    super(scope, id, props);

    const curPrefix = "CostUsageReport";
    const curDatabaseName = "costexplorerdb";
    // *****************
    //  Layers
    // *****************

    // https://docs.powertools.aws.dev/lambda/python/2.31.0/#lambda-layer
    const lambdaPowerToolsLayerARN = `arn:aws:lambda:${
      Stack.of(this).region
    }:017000801446:layer:AWSLambdaPowertoolsPythonV2:59`;
    const lambdaPowerToolsLayer = lambda.LayerVersion.fromLayerVersionArn(
      this,
      "LambdaPowerTools",
      lambdaPowerToolsLayerARN
    );

    const utilsLayer = new python.PythonLayerVersion(this, "UtilsLayer", {
      entry: path.join(__dirname, "services/layers/"),
      compatibleRuntimes: [lambda.Runtime.PYTHON_3_12],
    });

    const identityProvider = new IdentityProvider(this, "IdentityProvider");
    const app_client_id =
      identityProvider.tenantUserPoolClient.userPoolClientId;
    const userPoolID = identityProvider.tenantUserPool.userPoolId;

    const tenantTokenUsage = new TenantTokenUsage(this, "TenantTokenUsage", {
      lambdaPowerToolsLayer: lambdaPowerToolsLayer,
    });

    // TODO: Lab1 - Add pooled resources

    const collection = new opensearchserverless.VectorCollection(
      this,
      "SaaSGenAIWorkshopVectorCollection"
    );

    const s3Bucket = new Bucket(this, "SaaSGenAIWorkshopBucket", {
      autoDeleteObjects: true,
      removalPolicy: RemovalPolicy.DESTROY,
      eventBridgeEnabled: true,
    });

    const api = new ApiGateway(this, "SaaSGenAIWorkshopRestApi", {});

    const services = new Services(this, "SaaSGenAIWorkshopServices", {
      appClientID: app_client_id,
      userPoolID: userPoolID,
      s3Bucket: s3Bucket,
      tenantTokenUsageTable: tenantTokenUsage.tenantTokenUsageTable,
      restApi: api.restApi,
      controlPlaneApiGwUrl: props.controlPlaneApiGwUrl,
      lambdaPowerToolsLayer: lambdaPowerToolsLayer,
      utilsLayer: utilsLayer,
    });

    const coreUtilsStack = props.coreUtilsStack;

    // Access the codeBuildProject instance from the coreUtilsStack
    const codeBuildProject = coreUtilsStack.codeBuildProject;

    const dataAccessPolicy = new aoss.CfnAccessPolicy(
      this,
      "dataAccessPolicy",
      {
        name: `${collection.collectionName}`,
        description: `Data access policy for: ${collection.collectionName}`,
        type: "data",
        policy: JSON.stringify([
          {
            Rules: [
              {
                Resource: [`index/${collection.collectionName}/*`],
                Permission: [
                  "aoss:CreateIndex",
                  "aoss:DeleteIndex",
                  "aoss:UpdateIndex",
                  "aoss:DescribeIndex",
                  "aoss:ReadDocument",
                  "aoss:WriteDocument",
                ],
                ResourceType: "index",
              },
            ],
            Principal: [
              // Manual CodeBuild IAM Role implementation until SBT components provide this role.
              // As a temporary fix(unitl we have SBT fix), we are adding a dummy role so that we can deploy this data access policy.
              // Once workshop is deployed, you need to get CodeBuild project IAM role, add it here and then redeploy.
              // temporaryFixRole.roleArn,
              codeBuildProject.role?.roleArn,
            ],
            Description: "saas-genai-data-access-rule",
          },
        ]),
      }
    );

    new CfnOutput(this, "SaaSGenAIWorkshopOSSDataAccessPolicy", {
      value: dataAccessPolicy.name,
    });

    const curS3Bucket = new Bucket(this, "SaaSGenAICURWorkshopBucket", {
      autoDeleteObjects: true,
      removalPolicy: RemovalPolicy.DESTROY,
    });

    const sourceCodeS3Bucket = new Bucket(this, "TenantSourceCodeBucket", {
      autoDeleteObjects: true,
      removalPolicy: RemovalPolicy.DESTROY,
    });

    const bedrockCustom = new BedrockCustom(this, "BedrockCustom");

    const costPerTenant = new CostPerTenant(this, "CostPerTenant", {
      lambdaPowerToolsLayer: lambdaPowerToolsLayer,
      utilsLayer: utilsLayer,
      modelInvocationLogGroupName: bedrockCustom.modelInvocationLogGroupName,
      curDatabaseName: curDatabaseName,
      tableName: curPrefix.toLowerCase(),
      athenaOutputBucketName: curS3Bucket.bucketName,
    });

    const costUsageReportUpload = new CostUsageReportUpload(
      this,
      "CostUsageReportUpload",
      {
        curBucketName: curS3Bucket.bucketName,
        folderName: curPrefix,
      }
    );

    const curAthena = new CurAthena(this, "CurAthena", {
      curBucketName: curS3Bucket.bucketName,
      folderName: curPrefix,
      databaseName: curDatabaseName,
    });

    curAthena.node.addDependency(costUsageReportUpload);

    new CfnOutput(this, "TenantUserpoolId", {
      value: identityProvider.tenantUserPool.userPoolId,
    });

    new CfnOutput(this, "UserPoolClientId", {
      value: identityProvider.tenantUserPoolClient.userPoolClientId,
    });

    new CfnOutput(this, "ApiGatewayUrl", {
      value: api.restApi.url,
    });

    new CfnOutput(this, "ApiGatewayUsagePlan", {
      value: api.usagePlanBasicTier.usagePlanId,
    });

    new CfnOutput(this, "SaaSGenAIWorkshopS3Bucket", {
      value: s3Bucket.bucketName,
    });
    new CfnOutput(this, "SaaSGenAIWorkshopOSSCollectionArn", {
      value: collection.collectionArn,
    });

    new CfnOutput(this, "SaaSGenAIWorkshopTriggerIngestionLambdaArn", {
      value: services.triggerDataIngestionService.functionArn,
    });

    new CfnOutput(this, "TenantSourceCodeS3Bucket", {
      value: sourceCodeS3Bucket.bucketName,
    });

    new CfnOutput(this, "BedrockModelInvocationLogGroupName", {
      value: bedrockCustom.modelInvocationLogGroupName,
    });

    Aspects.of(this).add(new DestroyPolicySetter());
  }
}
