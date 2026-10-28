// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0

import * as cdk from "aws-cdk-lib";
import { Template, Match } from "aws-cdk-lib/assertions";
import { IdentityProvider } from "../lib/tenant-template/identity-provider";

/*
 * Any attribute listed in a user pool client's WriteAttributes can be changed by
 * the signed-in user themselves, using nothing but their own access token and
 * Cognito's UpdateUserAttributes API. That path never reaches our API Gateway or
 * Lambda functions, so no amount of authorization in the application can
 * constrain it.
 *
 * custom:tenantId is read by tenant_authorizer.py to decide which tenant's
 * configuration and credentials the caller receives, and it becomes the
 * DynamoDB partition key used by the agent action group, so it must not be
 * self-service writable. custom:userRole carries the same kind of authorization
 * meaning.
 */
describe("tenant user pool client attribute permissions", () => {
  const template = () => {
    const stack = new cdk.Stack();
    new IdentityProvider(stack, "TestIdentityProvider");
    return Template.fromStack(stack);
  };

  test("only email is writable by the user themselves", () => {
    template().hasResourceProperties("AWS::Cognito::UserPoolClient", {
      WriteAttributes: Match.arrayEquals(["email"]),
    });
  });

  test("no authorization attribute is writable by the user themselves", () => {
    const client = Object.values(
      template().findResources("AWS::Cognito::UserPoolClient")
    )[0];
    const writeAttributes: string[] = client.Properties.WriteAttributes;

    for (const attribute of ["custom:tenantId", "custom:userRole"]) {
      expect(writeAttributes).not.toContain(attribute);
    }
  });

  /*
   * The attributes stay mutable on the pool schema on purpose. Mutability
   * governs whether an attribute can be changed at all once the user exists,
   * so the admin-authorized path in user_management_service.py
   * (admin_update_user_attributes) depends on it. Narrowing WriteAttributes is
   * what stops the end user; clearing mutable would only break provisioning.
   */
  test("tenant attributes remain mutable for the admin provisioning path", () => {
    const pool = Object.values(
      template().findResources("AWS::Cognito::UserPool")
    )[0];
    const schema: { Name: string; Mutable?: boolean }[] =
      pool.Properties.Schema;

    for (const name of ["tenantId", "userRole"]) {
      expect(schema.find((entry) => entry.Name === name)?.Mutable).toBe(true);
    }
  });
});
