# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import os
import re
import secrets
import string

import boto3
import botocore
from crhelper import CfnResource
cognito = boto3.client('cognito-idp')
ssm = boto3.client('ssm')
helper = CfnResource()

CONTROL_PLANE_PARAMETER_PREFIX = os.environ.get(
    'CONTROL_PLANE_PARAMETER_PREFIX', '/saas-genai-workshop/control-plane')

SYMBOLS = '!@#$%^&*()-_=+'


def __generate_password(length=20):
    """Generate a random password that satisfies the Cognito password policy.

    This account is the control plane system administrator, so a literal
    password here would be a published credential for the most privileged
    account in every deployment of this public repository.
    """
    alphabet = string.ascii_letters + string.digits + SYMBOLS
    while True:
        password = ''.join(secrets.choice(alphabet) for _ in range(length))
        if (any(c.islower() for c in password)
                and any(c.isupper() for c in password)
                and any(c.isdigit() for c in password)
                and any(c in SYMBOLS for c in password)):
            return password


def __password_parameter_name(user_name):
    """Build the parameter name. Shared so create and delete cannot drift."""
    # Parameter Store names allow only a-zA-Z0-9_.-/ so the email needs folding.
    safe_user_name = re.sub(r'[^a-zA-Z0-9_.-]', '_', user_name)
    return f'{CONTROL_PLANE_PARAMETER_PREFIX}/{safe_user_name}/password'


def __read_stored_password(user_name):
    """Return the password already held for this user, or None if there is none."""
    try:
        parameter = ssm.get_parameter(
            Name=__password_parameter_name(user_name), WithDecryption=True)
        return parameter['Parameter']['Value']
    except ssm.exceptions.ParameterNotFound:
        return None


def __store_password(user_name, password):
    """Hold the generated password where only an IAM principal can read it."""
    parameter_name = __password_parameter_name(user_name)
    ssm.put_parameter(
        Name=parameter_name,
        Value=password,
        Type='SecureString',
        Overwrite=True
    )
    # Neither the value nor the name: the name embeds the administrator's email
    # address, and folding '@' to '_' does not stop it identifying the person --
    # the dot is permitted in a parameter name and is left as-is, so
    # 'admin@example.com' becomes 'admin_example.com'. README.md documents how to
    # look the parameter up.
    print('Stored control plane admin password in Parameter Store')
    return parameter_name


@helper.create
@helper.update
def do_action(event, _):
    """ Called as part of bootstrap template. 
        Inserts/Updates Settings table based upon the resources deployed inside bootstrap template
        We use these settings inside tenant template

    Args:
            event ([type]): [description]
            _ ([type]): [description]
    """
    # Setting email address as username
    user_name = event['ResourceProperties']['Email']
    email = event['ResourceProperties']['Email']
    user_role = event['ResourceProperties']['Role']
    user_pool_id = event['ResourceProperties']['UserPoolId']

    # Reuse the password already stored rather than minting a new one. This
    # handler runs on update as well as create, and rotating on every update
    # would silently invalidate a password an operator had retrieved and may be
    # using.
    #
    # When nothing is stored yet, generate and store before touching Cognito:
    # if the parameter write fails, nothing has been created, so the stack fails
    # cleanly. The other order can leave an admin user that exists with no
    # password anyone can discover, which a retry then skips because the
    # username already exists. Generating here also repairs that state if it
    # somehow arises.
    password = __read_stored_password(user_name)
    if password is None:
        password = __generate_password()
        __store_password(user_name, password)

    try:
        cognito.admin_create_user(
            Username=user_name,
            UserPoolId=user_pool_id,
            ForceAliasCreation=True,
            MessageAction='SUPPRESS',
            UserAttributes=[
                {
                    'Name': 'email',
                    'Value': email
                },
                {
                    'Name': 'email_verified',
                    'Value': 'true'
                },
                {
                    'Name': 'custom:userRole',
                    'Value': user_role
                }
            ]
        )
        # Not logging the create response: it echoes the user's attributes.
        print('created control plane admin user')
    except cognito.exceptions.UsernameExistsException:
        print('control plane admin user already exists')

    # Set the password whether the user was just created or already existed, so
    # the account and the stored parameter always agree. This is idempotent when
    # the password was read back above rather than generated, so an update does
    # not change what the operator already has.
    cognito.admin_set_user_password(
        UserPoolId=user_pool_id,
        Username=user_name,
        Password=password,
        Permanent=True
    )
    return user_name


@helper.delete
def do_delete(event, _):
    user_name = event["PhysicalResourceId"]
    user_pool_id = event['ResourceProperties']['UserPoolId']
    try:
        cognito.admin_delete_user(
            UserPoolId=user_pool_id,
            Username=user_name
        )
    except botocore.exceptions.ClientError as e:
        print(f'failed to delete: {e}')

    # Delete the stored password too. A plain stack delete does not run
    # cleanup.sh, so without this the generated credential outlives the
    # deployment it belonged to and sits in Parameter Store indefinitely.
    parameter_name = __password_parameter_name(user_name)
    try:
        ssm.delete_parameter(Name=parameter_name)
        # Not naming the parameter: it embeds the administrator's email.
        print('deleted the stored control plane admin password')
    except ssm.exceptions.ParameterNotFound:
        pass
    except botocore.exceptions.ClientError as e:
        print(f'failed to delete the stored admin password: {e}')


def handler(event, context):
    helper(event, context)
