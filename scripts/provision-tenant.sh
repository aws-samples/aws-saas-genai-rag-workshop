#!/bin/bash -e

# Enable nocasematch option
shopt -s nocasematch

S3_TENANT_SOURCECODE_BUCKET_URL=$(aws cloudformation describe-stacks --stack-name saas-genai-workshop-bootstrap-template --query "Stacks[0].Outputs[?OutputKey=='TenantSourceCodeS3Bucket'].OutputValue" --output text)
export CDK_PARAM_CODE_REPOSITORY_NAME="saas-genai-workshop"

# Download the folder from S3 to local directory
echo "Downloading folder from s3://$S3_TENANT_SOURCECODE_BUCKET_URL to $CDK_PARAM_CODE_REPOSITORY_NAME..."
aws s3 cp "s3://$S3_TENANT_SOURCECODE_BUCKET_URL" "$CDK_PARAM_CODE_REPOSITORY_NAME" --recursive \
--exclude "cdk/cdk.out/*" --exclude "cdk/node_modules/*" --exclude ".git/*" --quiet
cd $CDK_PARAM_CODE_REPOSITORY_NAME/cdk

# Parse tenant details from the input message from step function
export CDK_PARAM_TENANT_ID=$(echo $tenantId | tr -d '"')
export CDK_PARAM_TENANT_NAME=$(echo $tenantName | tr -d '"')
export TENANT_ADMIN_EMAIL=$(echo $email | tr -d '"')

# Define variables
STACK_NAME="saas-genai-workshop-bootstrap-template"
USER_POOL_OUTPUT_PARAM_NAME="TenantUserpoolId"
APP_CLIENT_ID_OUTPUT_PARAM_NAME="UserPoolClientId"
API_GATEWAY_URL_OUTPUT_PARAM_NAME="ApiGatewayUrl"
API_GATEWAY_USAGE_PLAN_ID_OUTPUT_PARAM_NAME="ApiGatewayUsagePlan"
S3_PARAM_NAME="SaaSGenAIWorkshopS3Bucket"
INGESTION_LAMBDA_ARN_PARAM_NAME="SaaSGenAIWorkshopTriggerIngestionLambdaArn"
OSSC_ARN_PARAM_NAME="SaaSGenAIWorkshopOSSCollectionArn"
INPUT_TOKENS="10000"
OUTPUT_TOKENS="500"
# Parameter Store prefix for per-tenant secrets. Must match TENANT_PARAMETER_PREFIX
# on the authorizer Lambda and the IAM policies that scope access to this path.
export TENANT_PARAMETER_PREFIX="/saas-genai-workshop/tenant"


# Read tenant details from the cloudformation
export REGION=$(aws configure get region)
export SAAS_APP_USERPOOL_ID=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='$USER_POOL_OUTPUT_PARAM_NAME'].OutputValue" --output text)
export SAAS_APP_CLIENT_ID=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='$APP_CLIENT_ID_OUTPUT_PARAM_NAME'].OutputValue" --output text)
export API_GATEWAY_URL=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='$API_GATEWAY_URL_OUTPUT_PARAM_NAME'].OutputValue" --output text)
export API_GATEWAY_USAGE_PLAN_ID=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='$API_GATEWAY_USAGE_PLAN_ID_OUTPUT_PARAM_NAME'].OutputValue" --output text)
export S3_BUCKET=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='$S3_PARAM_NAME'].OutputValue" --output text)
export TRIGGER_PIPELINE_INGESTION_LAMBDA_ARN=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='$INGESTION_LAMBDA_ARN_PARAM_NAME'].OutputValue" --output text)
export OPENSEARCH_SERVERLESS_COLLECTION_ARN=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='$OSSC_ARN_PARAM_NAME'].OutputValue" --output text)

# Create Tenant API Key
generate_api_key() {
    local suffix=${1:-sbt}
    local uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
    echo "${uuid}-${suffix}"
}

TENANT_API_KEY=$(generate_api_key)

# Error handling function
check_error() {
    provision_script_name=$1
    exit_code=$2
    provision_output=$3
    if [[ "$exit_code" -ne 0 ]]; then
        echo "$provision_output"
        echo "ERROR: $provision_script_name failed. Exiting"
        exit 1
    fi
        echo "$provision_script_name completed successfully"
}

# Invoke tenant provisioning service
pip3 install -r lib/tenant-template/tenant-provisioning/requirements.txt

provision_name="Tenant Provisioning"
# TODO: Lab1 - Add tenant provisioning service


export KNOWLEDGE_BASE_NAME=$CDK_PARAM_TENANT_ID

# List all knowledge bases and filter the results based on the KnowledgeBase name
export KNOWLEDGE_BASE_ID=$(aws bedrock-agent list-knowledge-bases | jq -r '.[] | .[] | select(.name == $name) | .knowledgeBaseId' --arg name $KNOWLEDGE_BASE_NAME)

# Create tenant admin user
provision_name="Tenant Admin User Provisioning"
# TODO: Lab1 - Uncomment below lines - user management service
tenant_admin_output=$(python3 lib/tenant-template/user-management/user_management_service.py --tenant-id $CDK_PARAM_TENANT_ID --email $TENANT_ADMIN_EMAIL --user-role "TenantAdmin" 2>&1 >/dev/null && exit_code=$?) || exit_code=$?
check_error "$provision_name" $exit_code  "$tenant_admin_output" 

# Store the tenant API key in Parameter Store.
#
# The tenant config below is served by the control plane's /tenant-config
# endpoint, which is unauthenticated by design (it exists so a tenant's
# frontend can bootstrap itself before anyone has signed in). Only values that
# are safe to hand to an anonymous caller belong in it, so the API key is kept
# out of it and held here instead. The authorizer Lambda reads this parameter
# with its own IAM role.
# Checked explicitly rather than leaning on `set -e`. The authorizer reads this
# parameter on every request, so a tenant whose key never got stored is
# provisioned but completely unusable -- and the failure would otherwise be an
# unlabelled aws-cli error in the middle of a provisioning log. Name the step so
# it is obvious which one broke.
provision_name="Tenant API Key Storage"
if [[ -z "$TENANT_API_KEY" ]]; then
  echo "ERROR: $provision_name failed. TENANT_API_KEY is empty. Exiting"
  exit 1
fi
if ! ssm_output=$(aws ssm put-parameter \
  --name "$TENANT_PARAMETER_PREFIX/$CDK_PARAM_TENANT_ID/api-key" \
  --value "$TENANT_API_KEY" \
  --type SecureString \
  --overwrite \
  --no-cli-pager 2>&1 >/dev/null); then
  echo "$ssm_output"
  echo "ERROR: $provision_name failed. Exiting"
  exit 1
fi
echo "$provision_name completed successfully"
echo "Stored tenant API key at $TENANT_PARAMETER_PREFIX/$CDK_PARAM_TENANT_ID/api-key"

# Create JSON response of output parameters
export tenantConfig=$(jq --arg SAAS_APP_USERPOOL_ID "$SAAS_APP_USERPOOL_ID" \
  --arg SAAS_APP_CLIENT_ID "$SAAS_APP_CLIENT_ID" \
  --arg API_GATEWAY_URL "$API_GATEWAY_URL" \
  --arg CDK_PARAM_TENANT_NAME "$CDK_PARAM_TENANT_NAME" \
  --arg KNOWLEDGE_BASE_ID "$KNOWLEDGE_BASE_ID" \
  --arg INPUT_TOKENS "$INPUT_TOKENS" \
  --arg OUTPUT_TOKENS "$OUTPUT_TOKENS" \
  -n '{"tenantName":$CDK_PARAM_TENANT_NAME,"userPoolId":$SAAS_APP_USERPOOL_ID,"appClientId":$SAAS_APP_CLIENT_ID,"apiGatewayUrl":$API_GATEWAY_URL, "knowledgeBaseId":$KNOWLEDGE_BASE_ID, "inputTokens":$INPUT_TOKENS, "outputTokens":$OUTPUT_TOKENS}')
export tenantStatus="Complete"
