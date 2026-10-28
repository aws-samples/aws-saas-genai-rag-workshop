// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

import { Construct } from "constructs";
import {
  RestApi,
  Cors,
  LogGroupLogDestination,
  MethodLoggingLevel,
  Period,
  ApiKeySourceType,
  UsagePlan,
} from "aws-cdk-lib/aws-apigateway";
import { LogGroup, RetentionDays } from "aws-cdk-lib/aws-logs";
import { Services } from "./services";
import { UsagePlans } from "./usage-plans";

interface ApiGatewayProps {}

export class ApiGateway extends Construct {
  public readonly restApi: RestApi;
  public readonly usagePlaneApiKey: any;
  public readonly usagePlanBasicTier: UsagePlan;

  constructor(scope: Construct, id: string, props: ApiGatewayProps) {
    super(scope, id);

    const apiLogGroup = new LogGroup(this, "SaaSGenAIWorkshopAPILogGroup", {
      retention: RetentionDays.ONE_WEEK,
    });

    const restApi = new RestApi(this, "SaaSGenAIWorkshopRestApi", {
      cloudWatchRole: true,
      apiKeySourceType: ApiKeySourceType.AUTHORIZER,
      defaultCorsPreflightOptions: {
        allowOrigins: Cors.ALL_ORIGINS,
      },
      deployOptions: {
        accessLogDestination: new LogGroupLogDestination(apiLogGroup),
        methodOptions: {
          "/*/*": {
            // Data tracing logs full request and response data. It is a
            // debugging aid rather than something to leave on: the authorizer
            // context flowing through this API carries temporary AWS
            // credentials. Error-level execution logging is kept.
            dataTraceEnabled: false,
            loggingLevel: MethodLoggingLevel.ERROR,
          },
        },
      },
    });

    this.restApi = restApi;

    const usagePlan = new UsagePlans(this, "usagePlan", {
      apiGateway: restApi,
    });

    this.usagePlanBasicTier = usagePlan.usagePlanBasicTier;
  }
}
