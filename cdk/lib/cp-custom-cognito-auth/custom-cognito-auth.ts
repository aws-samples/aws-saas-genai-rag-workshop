// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

import * as sbt from "@cdklabs/sbt-aws";
import { Stack, CustomResource, Duration } from "aws-cdk-lib";
import * as cognito from "aws-cdk-lib/aws-cognito";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as python from "@aws-cdk/aws-lambda-python-alpha";
import { Effect, PolicyStatement } from "aws-cdk-lib/aws-iam";
import { Construct } from "constructs";
import * as path from "path";

// Parameter Store prefix holding the generated control plane admin password.
// Must match CONTROL_PLANE_PARAMETER_PREFIX in auth-custom-resource/index.py.
const CONTROL_PLANE_PARAMETER_PREFIX = "/saas-genai-workshop/control-plane";

export class CustomCognitoAuth extends sbt.CognitoAuth {
  private readonly customResourceFunction: lambda.IFunction;

  constructor(scope: Construct, id: string, props: sbt.CognitoAuthProps) {
    super(scope, id, props);

    // SBT's own control plane app client lists custom:userRole in its
    // writeAttributes, which lets a signed-in control plane user rewrite their
    // own role through Cognito's UpdateUserAttributes API. That is the same bug
    // class as the tenant app client fix in tenant-template/identity-provider.ts.
    //
    // Nothing in the control plane currently reads custom:userRole to make an
    // authorization decision, so this is defence in depth rather than an open
    // hole -- but the claim is self-writable today and the next thing to trust
    // it would inherit a privilege escalation. Every legitimate userRole write
    // goes through AdminUpdateUserAttributes/AdminCreateUser under the user
    // management service's own IAM role, so narrowing this costs nothing.
    //
    // CognitoAuth keeps only the client's id (this.userClientId), not the
    // construct, and takes no prop for writeAttributes, so there is no way to
    // configure this through the public API. findChild is deliberate over
    // tryFindChild: if a future SBT release renames the client, this should fail
    // the build loudly rather than silently stop applying the fix.
    const userPoolUserClient = this.node.findChild(
      "UserPoolUserClient"
    ) as cognito.UserPoolClient;
    const cfnUserPoolUserClient = userPoolUserClient.node
      .defaultChild as cognito.CfnUserPoolClient;
    cfnUserPoolUserClient.addPropertyOverride("WriteAttributes", ["email"]);

    // No token-validity override here, deliberately.
    //
    // scripts/sbt-aws.sh used to set id and access token validity to 3 with
    // update-user-pool-client on every `configure` and `refresh-tokens` run.
    // That call has been removed, because UpdateUserPoolClient is a full
    // replace and so it also reset every other property configured above.
    //
    // The validity is not carried over. Cognito's units default to hours, so
    // the script was setting a 3 hour lifetime, while Cognito's own default is
    // 60 minutes -- the script was lengthening token life threefold rather than
    // shortening it, on the control plane administrator's client, where a
    // leaked token is provider-level rather than tenant-level. Nothing in the
    // repository chose 3 deliberately: there was no comment explaining it and
    // it arrived with the rest of the script.
    //
    // So leaving it unset restores the shorter default. The operator cost is
    // small now that `refresh-tokens` reads the password from Parameter Store
    // and needs no prompt.

    // https://docs.powertools.aws.dev/lambda/python/2.31.0/#lambda-layer
    const lambdaPowertoolsLayer = lambda.LayerVersion.fromLayerVersionArn(
      this,
      "LambdaPowerToolsCustumAuth",
      `arn:aws:lambda:${
        Stack.of(this).region
      }:017000801446:layer:AWSLambdaPowertoolsPythonV2:59`
    );

    this.customResourceFunction = new python.PythonFunction(
      this,
      "customResourceFunction",
      {
        entry: path.join(__dirname, "auth-custom-resource"),
        runtime: lambda.Runtime.PYTHON_3_12,
        index: "index.py",
        handler: "handler",
        timeout: Duration.seconds(60),
        layers: [lambdaPowertoolsLayer],
        environment: {
          CONTROL_PLANE_PARAMETER_PREFIX: CONTROL_PLANE_PARAMETER_PREFIX,
        },
      }
    );
    this.userPool.grant(
      this.customResourceFunction,
      "cognito-idp:AdminCreateUser",
      "cognito-idp:AdminDeleteUser",
      "cognito-idp:AdminSetUserPassword"
    );

    // The admin password is generated at deploy time rather than hardcoded, so
    // it has to be written somewhere an operator can retrieve it from, and
    // removed again when the resource is deleted. Without the delete, a plain
    // stack teardown would leave the credential behind in Parameter Store.
    //
    // GetParameter is needed because this resource runs on stack updates too,
    // and reads back the stored password rather than rotating it.
    const stack = Stack.of(this);
    this.customResourceFunction.addToRolePolicy(
      new PolicyStatement({
        effect: Effect.ALLOW,
        actions: [
          "ssm:GetParameter",
          "ssm:PutParameter",
          "ssm:DeleteParameter",
        ],
        resources: [
          `arn:aws:ssm:${stack.region}:${stack.account}:parameter${CONTROL_PLANE_PARAMETER_PREFIX}/*`,
        ],
      })
    );
  }
  createAdminUser(
    scope: Construct,
    id: string,
    props: sbt.CreateAdminUserProps
  ) {
    new CustomResource(scope, `CustomAuthCustomResource-${id}`, {
      serviceToken: this.customResourceFunction.functionArn,
      properties: {
        UserPoolId: this.userPool.userPoolId,
        Name: props.name,
        Email: props.email,
        Role: props.role,
      },
    });
  }
}
