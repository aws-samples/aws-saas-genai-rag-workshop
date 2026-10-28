// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

import { aws_cognito, StackProps, Duration } from "aws-cdk-lib";
import { Construct } from "constructs";
import { IdentityDetails } from "../interfaces/identity-details";

export class IdentityProvider extends Construct {
  public readonly tenantUserPool: aws_cognito.UserPool;
  public readonly tenantUserPoolClient: aws_cognito.UserPoolClient;
  public readonly identityDetails: IdentityDetails;
  constructor(scope: Construct, id: string, props?: StackProps) {
    super(scope, id);

    this.tenantUserPool = new aws_cognito.UserPool(this, "tenantUserPool", {
      autoVerify: { email: true },
      accountRecovery: aws_cognito.AccountRecovery.EMAIL_ONLY,
      standardAttributes: {
        email: {
          required: true,
          mutable: true,
        },
      },
      customAttributes: {
        tenantId: new aws_cognito.StringAttribute({
          mutable: true,
        }),
        userRole: new aws_cognito.StringAttribute({
          mutable: true,
        }),
      },
    });

    // Only email is writable by the signed-in user themselves.
    //
    // Any attribute listed here can be changed by a user with nothing but their
    // own access token, via Cognito's UpdateUserAttributes API, without going
    // anywhere near our API Gateway or Lambda functions. custom:tenantId is
    // exactly what tenant_authorizer.py reads to decide which tenant's data the
    // caller may reach, and it becomes the DynamoDB partition key the agent
    // action group uses, so listing it here would let any tenant user grant
    // themselves another tenant's identity. custom:userRole carries the same
    // kind of authorization meaning. Both are set only through the admin side
    // AdminCreateUser / AdminUpdateUserAttributes calls in
    // user-management/user_management_service.py, which runs with provisioning
    // credentials.
    //
    // The pool schema keeps these attributes mutable, which is deliberate:
    // mutable governs whether an attribute can be changed at all after the user
    // is created, so the admin-authorized re-provisioning path needs it.
    const writeAttributes = new aws_cognito.ClientAttributes().withStandardAttributes(
      { email: true }
    );

    this.tenantUserPoolClient = new aws_cognito.UserPoolClient(
      this,
      "tenantUserPoolClient",
      {
        userPool: this.tenantUserPool,
        generateSecret: false,
        accessTokenValidity: Duration.minutes(180),
        idTokenValidity: Duration.minutes(180),
        authFlows: {
          userPassword: true,
          adminUserPassword: false,
          userSrp: true,
          custom: false,
        },
        writeAttributes: writeAttributes,
        oAuth: {
          scopes: [
            aws_cognito.OAuthScope.EMAIL,
            aws_cognito.OAuthScope.OPENID,
            aws_cognito.OAuthScope.PROFILE,
          ],
          flows: {
            authorizationCodeGrant: true,
            implicitCodeGrant: true,
          },
        },
      }
    );

    this.identityDetails = {
      name: "Cognito",
      details: {
        userPoolId: this.tenantUserPool.userPoolId,
        appClientId: this.tenantUserPoolClient.userPoolClientId,
      },
    };
  }
}
