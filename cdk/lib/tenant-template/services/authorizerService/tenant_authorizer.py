# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import urllib.request
import urllib.error
import json
import os
import boto3
import time
import re
import authorizer_layer

from jose import jwk, jwt
from jose.utils import base64url_decode
from aws_lambda_powertools import Logger, Tracer
from collections import namedtuple
from assume_role_layer import assume_role


region = os.environ['AWS_REGION']
userpool_id = os.environ['USER_POOL_ID']
appclient_id = os.environ['APP_CLIENT_ID']
assume_role_arn = os.environ['ASSUME_ROLE_ARN']
control_plane_gw_url = os.environ['CP_API_GW_URL']

tenant_token_usage_role_arn = os.environ["TENANT_TOKEN_USAGE_ROLE_ARN"]
tenant_token_usage_table = os.environ["TENANT_TOKEN_USAGE_DYNAMODB_TABLE"]

# Prefix of the Parameter Store path holding each tenant's API Gateway key.
tenant_parameter_prefix = os.environ.get(
    "TENANT_PARAMETER_PREFIX", "/saas-genai-workshop/tenant"
)

ssm = boto3.client('ssm')

# Applied to every outbound HTTP call this authorizer makes. It runs in front of
# every request, so a hung dependency must become a fast deny rather than a
# stalled invocation.
HTTP_TIMEOUT_SECONDS = 5

logger = Logger()

def lambda_handler(event, context):
    method_arn = event["methodArn"]

    # get JWT token after Bearer from authorization
    #
    # These deny rather than raise. A raised exception in a request authorizer
    # surfaces as a 500, and an absent or malformed Authorization header is the
    # most ordinary failure this function sees, not an internal error. Every
    # other failure below returns an explicit deny, so these do too.
    if 'authorizationToken' in event:
        token_str = event['authorizationToken']
    elif 'Authorization' in (event.get('headers') or {}):
        token_str = event['headers']['Authorization']
    else:
        logger.error('Request carries no authorization token')
        return authorizer_layer.create_auth_denied_policy(method_arn)

    # Exactly two parts: a bare "Bearer" used to raise IndexError below, and a
    # JWT never contains a space, so anything else is malformed.
    token = token_str.split(" ")
    if len(token) != 2 or token[0] != 'Bearer':
        logger.error('Authorization header is not of the form "Bearer <token>"')
        return authorizer_layer.create_auth_denied_policy(method_arn)
    jwt_bearer_token = token[1]

    # No unverified decode here. It used to decode the claims before any
    # validation, which raised JWTError on a malformed token and surfaced as a
    # 5xx rather than a deny. Its result was never used, and validateJWT below
    # already rejects an undecodable token and returns False, which denies. So
    # the token is only ever decoded as part of validating it.

    # get keys for tenant user pool to validate
    keys_url = 'https://cognito-idp.{}.amazonaws.com/{}/.well-known/jwks.json'.format(region, userpool_id)
    try:
        # Timeout, and fail closed. Without a timeout a stalled connection does
        # not raise: it blocks until the Lambda's own 60s limit and returns a
        # 5xx instead of the deny this is supposed to produce.
        with urllib.request.urlopen(keys_url, timeout=HTTP_TIMEOUT_SECONDS) as f:
            response = f.read()
        keys = json.loads(response.decode('utf-8'))['keys']
    except (urllib.error.URLError, TimeoutError, UnicodeDecodeError,
            json.JSONDecodeError, KeyError) as e:
        logger.error(f'Unable to read the user pool signing keys: {type(e).__name__}')
        return authorizer_layer.create_auth_denied_policy(method_arn)

    # authenticate against cognito user pool using the key
    response = authorizer_layer.validateJWT(jwt_bearer_token, appclient_id, keys)

    # get authenticated claims
    if (response == False):
        logger.error('Unauthorized')
        return authorizer_layer.create_auth_denied_policy(method_arn)
    else:
        # A token can be validly signed by this pool and still carry no tenant
        # id — a user created outside the provisioning path has no such claim.
        # Reading it directly would raise KeyError and surface as a 5xx instead
        # of the deny every other failure in this handler returns.
        tenant_id = response.get("custom:tenantId")
        if not tenant_id:
            logger.error('Token carries no tenantId claim')
            return authorizer_layer.create_auth_denied_policy(method_arn)

        response_url = urllib.request.Request(control_plane_gw_url + f'tenant-config?tenantId={tenant_id}')
        try:
            # The request itself is inside the try, not just the parsing. An
            # unknown or not-yet-provisioned tenant makes the control plane
            # answer 404, which urlopen raises as HTTPError — the most likely
            # failure here, and the one a spoofed tenantId would produce.
            # Leaving it outside would turn that into an unhandled Lambda error
            # instead of the deny this is meant to return.
            with urllib.request.urlopen(response_url, timeout=HTTP_TIMEOUT_SECONDS) as f:
                response_data = f.read()
            response_text = response_data.decode('utf-8')
            response_json = json.loads(response_text)
            tenant_name=response_json['tenantName']
            knowledge_base_id = response_json["knowledgeBaseId"]
            input_tokens = response_json["inputTokens"]
            output_tokens = response_json["outputTokens"]
        except (urllib.error.URLError, TimeoutError, UnicodeDecodeError,
                json.JSONDecodeError, KeyError) as e:
            # Fail closed. Without a tenant config there is nothing to scope
            # this caller to, so denying is the only safe outcome.
            # URLError is HTTPError's base class, so this covers both. A read
            # timeout can surface as a bare TimeoutError rather than wrapped in
            # URLError, so both are caught.
            logger.error(f'Unable to read tenant config: {type(e).__name__}')
            return authorizer_layer.create_auth_denied_policy(method_arn)

        # The API key is a credential, so it is deliberately NOT part of the
        # tenant config: /tenant-config is served to anonymous callers. It is
        # read here from Parameter Store using this function's own IAM role.
        api_key = __get_tenant_api_key(tenant_id)
        if api_key is None:
            logger.error('Unable to read the tenant API key')
            return authorizer_layer.create_auth_denied_policy(method_arn)

        # TODO: Lab3 - Enable tenant token usage 
        
        # assume role
        # ABAC: create a temporary session using the assume role arn 
        # which gives S3 Access to the tenant-specific prefix and specific knowledge base
        
        request_tags = [("KnowledgeBaseId", knowledge_base_id), ("TenantID", tenant_id)]
        session_parameters = assume_role(access_role_arn = assume_role_arn, request_tags = request_tags, duration_sec = 900)
        
        print("Role Assumed!")

        authorization_success_policy = authorizer_layer.create_auth_success_policy(method_arn, 
            tenant_id,
            tenant_name, 
            knowledge_base_id, 
            session_parameters.aws_access_key_id,
            session_parameters.aws_secret_access_key,
            session_parameters.aws_session_token,
            api_key
        )
        
        # Deliberately not logging the policy: it carries the temporary AWS
        # credentials just minted for this caller plus the tenant API key.
        logger.info("Authorization succeeded")
        return authorization_success_policy


def __get_tenant_api_key(tenant_id):
    """Read this tenant's API Gateway key from Parameter Store.

    Returns None when the parameter cannot be read, so the caller can deny.
    """
    parameter_name = f'{tenant_parameter_prefix}/{tenant_id}/api-key'
    try:
        parameter = ssm.get_parameter(Name=parameter_name, WithDecryption=True)
        return parameter['Parameter']['Value']
    except Exception as e:
        # Logging the parameter name but never the value.
        logger.error(f"Error reading {parameter_name}: {type(e).__name__}")
        return None



def __is_tenant_token_limit_exceeded(tenant_id, input_tokens, output_tokens):
    # check if tenant has enough tokens
    try:
        input_tokens=int(input_tokens)
        output_tokens=int(output_tokens)
        table = __get_dynamodb_table(tenant_id)
        response = table.get_item(
            Key={
                'TenantId': tenant_id
            }
        )
        if 'Item' in response:
            current_input_tokens = response['Item']['TotalInputTokens']
            current_output_tokens = response['Item']['TotalOutputTokens']
        else:
            current_input_tokens = 0
            current_output_tokens = 0

        if (current_input_tokens > input_tokens ) or (current_output_tokens > output_tokens ):
            logger.error('Tenant token limit exceeded')
            return True

    except Exception as e:
        logger.error(f"Error validating tenant token usage limit: {e}")
        return True    
    
    return False

def __get_dynamodb_table(tenant_id):
    request_tags = [("TenantID", tenant_id)]
    session_parameters = assume_role(access_role_arn=tenant_token_usage_role_arn, request_tags = request_tags, duration_sec=900)
    dynamodb = boto3.resource('dynamodb', aws_access_key_id=session_parameters.aws_access_key_id,
            aws_secret_access_key=session_parameters.aws_secret_access_key,
            aws_session_token=session_parameters.aws_session_token)
    return dynamodb.Table(tenant_token_usage_table)