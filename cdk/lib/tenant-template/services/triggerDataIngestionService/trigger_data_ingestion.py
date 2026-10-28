# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import json
import boto3
import os

from datetime import datetime
from assume_role_layer import assume_role
from aws_lambda_powertools import Logger, Tracer

from aws_lambda_powertools.event_handler import (APIGatewayRestResolver,
                                                CORSConfig)
from aws_lambda_powertools.logging import correlation_paths
from aws_lambda_powertools.event_handler.exceptions import (
    InternalServerError,
    NotFoundError,
)

tracer = Tracer()
logger = Logger()
cors_config = CORSConfig(allow_origin="*", max_age=300)
app = APIGatewayRestResolver(cors=cors_config)
assume_role_arn = os.environ['ASSUME_ROLE_ARN']

# log_event is off so the full invocation event is not written to CloudWatch.
# This function is invoked for an object event rather than through the API, so
# its event carries no authorizer context, but it does identify a tenant's
# bucket and key. The named fields below are logged instead of the whole event,
# which also keeps this consistent with rag_service and s3uploader.
@logger.inject_lambda_context(correlation_id_path=correlation_paths.API_GATEWAY_REST)
@tracer.capture_lambda_handler

def lambda_handler(event, context):
    try:
        # Extract kb_id,bucket, and key from the event

        knowledge_base_id = event['kb_id']
        datasource_id = event['datasource_id']
        bucket = event['bucket']
        key = event['key']
        tenant_id = key.split('/')[0]

        logger.debug(
            'Ingestion triggered',
            extra={
                'tenant_id': tenant_id,
                'knowledge_base_id': knowledge_base_id,
                'datasource_id': datasource_id,
            },
        )

        # ABAC: create a temporary session using the assume role arn which gives S3 Access to the tenant-specific prefix

        request_tags = [("KnowledgeBaseId", knowledge_base_id)]
        session_parameters = assume_role(access_role_arn=assume_role_arn, request_tags = request_tags, duration_sec = 900)

        session = boto3.Session(
            aws_access_key_id=session_parameters.aws_access_key_id,
            aws_secret_access_key=session_parameters.aws_secret_access_key,
            aws_session_token=session_parameters.aws_session_token
        )
        
        client = session.client('bedrock-agent')

        response = client.start_ingestion_job(
            dataSourceId=datasource_id,
            description='data source updated',
            knowledgeBaseId=knowledge_base_id
        )
        logger.info(response)
        
        
    except KeyError as e:
        # Naming the missing key rather than dumping the event. These handlers
        # run at ERROR level, which is on by default, so logging the event here
        # would put the tenant's bucket and key in CloudWatch on every failure
        # and undo what the happy path above is careful about.
        logger.error(f"KeyError: missing {e} in ingestion event")
        return {
            'statusCode': 400,
            'body': json.dumps('Bad Request: Missing required key')
        }
    except Exception as e:
        # event.get rather than the locals above: a KeyError earlier in the try
        # block can leave those unbound.
        logger.error(
            f"Unhandled exception: {e}",
            extra={
                'knowledge_base_id': event.get('kb_id'),
                'datasource_id': event.get('datasource_id'),
            },
        )
        return {
            'statusCode': 500,
            'body': json.dumps('Internal Server Error')
        }

    # Rest of your code
    return {
        'statusCode': 200,
        'body': json.dumps('Success')
    }