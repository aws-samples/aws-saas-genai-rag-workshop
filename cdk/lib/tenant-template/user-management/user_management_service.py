# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import boto3
import os
import argparse
import re
import secrets
import string

SAAS_APP_USERPOOL_ID=os.environ['SAAS_APP_USERPOOL_ID']

# Must match TENANT_PARAMETER_PREFIX in provision-tenant.sh and the IAM policies
# that scope access to this path.
TENANT_PARAMETER_PREFIX = os.environ.get(
    'TENANT_PARAMETER_PREFIX', '/saas-genai-workshop/tenant')

cognito = boto3.client('cognito-idp')
ssm = boto3.client('ssm')

# Named once and used in both the alphabet and the complexity check below, so
# the two cannot drift apart and leave the check validating a category the
# alphabet no longer contains.
SYMBOLS = '!@#$%^&*()-_=+'


def __generate_password(length=20):
    """Generate a random password that satisfies the Cognito password policy.

    A sample must never ship a known password: this repository is public, so a
    literal here would be a published credential for every deployment of it.
    """
    alphabet = string.ascii_letters + string.digits + SYMBOLS
    while True:
        password = ''.join(secrets.choice(alphabet) for _ in range(length))
        if (any(c.islower() for c in password)
                and any(c.isupper() for c in password)
                and any(c.isdigit() for c in password)
                and any(c in SYMBOLS for c in password)):
            return password


def __password_parameter_name(tenant_id, username):
    # Parameter Store names allow only a-zA-Z0-9_.-/ so the email needs folding.
    safe_username = re.sub(r'[^a-zA-Z0-9_.-]', '_', username)
    return f'{TENANT_PARAMETER_PREFIX}/{tenant_id}/users/{safe_username}/password'


def __read_stored_password(tenant_id, username):
    """Return the password already held for this user, or None if there is none."""
    try:
        parameter = ssm.get_parameter(
            Name=__password_parameter_name(tenant_id, username),
            WithDecryption=True
        )
        return parameter['Parameter']['Value']
    except ssm.exceptions.ParameterNotFound:
        return None


def __store_password(tenant_id, username, password):
    """Hold the generated password where only an IAM principal can read it."""
    parameter_name = __password_parameter_name(tenant_id, username)
    ssm.put_parameter(
        Name=parameter_name,
        Value=password,
        Type='SecureString',
        Overwrite=True
    )
    # Neither the value nor the name: the name embeds the user's email address,
    # and folding '@' and '.' to '_' does not stop it identifying the person.
    # README.md documents how to look the parameter up.
    print(f'Stored password for a user of tenant {tenant_id} in Parameter Store')
    return parameter_name


def create_user(tenant_id, email, user_role):
    username=email

    # Reuse the password already stored for this user rather than minting a new
    # one, and set it on both paths below. This matches what the control plane
    # custom resource does, and the two halves of the reasoning pull in opposite
    # directions:
    #
    #  - Generating only when creating a new user would leave anyone who already
    #    exists -- a re-provisioned tenant, or a user created before this
    #    workshop generated passwords -- with no stored password at all, so the
    #    retrieval documented in README.md would return nothing for them.
    #  - Generating on every run would silently rotate the password out from
    #    under an operator who had already retrieved it and was using it.
    #
    # Reading back satisfies both: a re-provision is a no-op for anyone who
    # already has a stored password, and anyone who does not gets one.
    temporary_password = __read_stored_password(tenant_id, username)
    if temporary_password is None:
        temporary_password = __generate_password()
        __store_password(tenant_id, username, temporary_password)

    admin_user_exists = __admin_user_exists(SAAS_APP_USERPOOL_ID,username)
    if not admin_user_exists:
        response = cognito.admin_create_user(
                Username=username,
                UserPoolId=SAAS_APP_USERPOOL_ID,
                ForceAliasCreation=True,
                TemporaryPassword=temporary_password,
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
                        'Name': 'custom:tenantId',
                        'Value': tenant_id 
                    },
                    {
                        'Name': 'custom:userRole',
                        'Value': user_role 
                    }
                ],
            )
            
        
    else:
        response = cognito.admin_update_user_attributes(
                UserPoolId=SAAS_APP_USERPOOL_ID,
                Username=username,
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
                        'Name': 'custom:tenantId',
                        'Value': tenant_id 
                    },
                    {
                        'Name': 'custom:userRole',
                        'Value': user_role 
                    }
                ]
            )

    # Whether the user was just created or already existed, leave the account on
    # the password stored above so the documented retrieval always matches.
    __set_user_password(SAAS_APP_USERPOOL_ID, username, temporary_password)

    group_exists = __user_group_exists(SAAS_APP_USERPOOL_ID, tenant_id)
    if not group_exists:
        __create_user_group(SAAS_APP_USERPOOL_ID, tenant_id)

    __add_user_to_group(SAAS_APP_USERPOOL_ID, username, tenant_id)
    return response

def __admin_user_exists(SAAS_APP_USERPOOL_ID,username):
    try:
        response=cognito.admin_get_user(
            UserPoolId=SAAS_APP_USERPOOL_ID,
            Username=username)
        return True
    except Exception as e:
        return False

def __set_user_password(user_pool_id, username, password):
    response = cognito.admin_set_user_password(
        UserPoolId=user_pool_id,
        Username=username,
        Password=password,
        Permanent=True
    )
    return response

def __create_user_group(user_pool_id, group_name):
        response = cognito.create_group(
            GroupName=group_name,
            UserPoolId=user_pool_id,
            Precedence=0
        )
        return response


def __add_user_to_group(user_pool_id, user_name, group_name):
        response = cognito.admin_add_user_to_group(
            UserPoolId=user_pool_id,
            Username=user_name,
            GroupName=group_name
        )
        return response

def __user_group_exists(user_pool_id, group_name):        
        try:
            response=cognito.get_group(
                UserPoolId=user_pool_id, 
                GroupName=group_name)
            return True
        except Exception as e:
            return False
        
if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description='Managing tenant users')
    parser.add_argument('--tenant-id', type=str, help='tenant-id', required=True)
    parser.add_argument('--email', type=str, help='email', required=True)
    parser.add_argument('--user-role', type=str, help='user role', required=True)
    
    args = parser.parse_args()
    create_user(**vars(args))
