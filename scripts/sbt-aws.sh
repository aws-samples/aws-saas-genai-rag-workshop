#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

set -e

# Config values
CONFIG_FILE="${HOME}/.sbt-aws-config"

# Functions
help() {
  echo "Usage: $0 [--debug] <operation> [additional args]"
  echo "Operations:"
  echo "  configure <control_plane_stack> <user_email>"
  echo "  refresh-tokens"
  echo "  create-tenant"
  echo "  get-tenant-registration <tenant_registration_id>"
  echo "  get-all-tenant-registrations <limit> <next_token>"
  echo "  update-tenant-registration <tenant_registration_id> <key> <value>"
  echo "  delete-tenant-registration <tenant_registration_id>"
  echo "  get-tenant <tenant_id>"
  echo "  get-all-tenants <limit> <next_token>"
  echo "  update-token-limit <tenant_name> <input_tokens> <output_tokens>"
  echo "  create-user"
  echo "  get-user <user_id>"
  echo "  get-all-users <limit> <next_token>"
  echo "  update-user <user_id> <user_role> <user_email>"
  echo "  delete-user <user_id>"
  echo "  invoke <user_name> <password> <query> <requests>"
  echo "  upload-file <user_name> <password> <file_location>"
  echo "  execute-query <user_name> <password> <knowledge_base_query>"
  echo "  help"
}


generate_credentials() {
  if $DEBUG; then
    echo "Generating credentials..."
  fi

  USER="admin@example.com"
  PASSWORD="$1"
  CONTROL_PLANE_STACK_NAME="$2"

  CLIENT_ID=$(aws cloudformation describe-stacks \
    --stack-name "$CONTROL_PLANE_STACK_NAME" \
    --query "Stacks[0].Outputs[?contains(OutputKey,'ControlPlaneIdpClientId')].OutputValue" \
    --output text)
  USER_POOL_ID=$(aws cloudformation describe-stacks \
    --stack-name "$CONTROL_PLANE_STACK_NAME" \
    --query "Stacks[0].Outputs[?contains(OutputKey,'ControlPlaneIdpUserPoolId')].OutputValue" \
    --output text)

  if $DEBUG; then
    echo "CLIENT_ID: $CLIENT_ID"
    echo "USER_POOL_ID: $USER_POOL_ID"
    echo "USER: $USER"
  fi

  # required in order to initiate-auth
  aws cognito-idp update-user-pool-client \
    --user-pool-id "$USER_POOL_ID" \
    --client-id "$CLIENT_ID" \
    --id-token-validity 3 \
    --access-token-validity 3 \
    --explicit-auth-flows USER_PASSWORD_AUTH \
    --output text >/dev/null

  if $DEBUG; then
    echo "Updated user pool client for USER_PASSWORD_AUTH"
  fi

  # remove need for password reset
  aws cognito-idp admin-set-user-password \
    --user-pool-id "$USER_POOL_ID" \
    --username "$USER" \
    --password "$PASSWORD" \
    --permanent \
    --output text >/dev/null

  if $DEBUG; then
    echo "Set user password for $USER"
  fi

  # get credentials for user
  AUTHENTICATION_RESULT=$(aws cognito-idp initiate-auth \
    --auth-flow USER_PASSWORD_AUTH \
    --client-id "${CLIENT_ID}" \
    --auth-parameters "USERNAME='${USER}',PASSWORD='${PASSWORD}'" \
    --query 'AuthenticationResult')

  ACCESS_TOKEN=$(echo "$AUTHENTICATION_RESULT" | jq -r '.AccessToken')

  if $DEBUG; then
    echo "ACCESS_TOKEN: $ACCESS_TOKEN"
  fi

  export ACCESS_TOKEN
}

configure() {
  CONTROL_PLANE_STACK_NAME="$1"
  USER_EMAIL="$2"
  # EMAIL_USERNAME="$(echo $USER_EMAIL | cut -d "@" -f 1)"
  EMAIL_USERNAME="$2"
  EMAIL_DOMAIN="$(echo $USER_EMAIL | cut -d "@" -f 2)"

  if $DEBUG; then
    echo "Configuring with:"
    echo "CONTROL_PLANE_STACK_NAME: $CONTROL_PLANE_STACK_NAME"
    echo "EMAIL_USERNAME: $EMAIL_USERNAME"
    echo "EMAIL_DOMAIN: $EMAIL_DOMAIN"
  fi

  read -r -s -p "Enter admin password: " ADMIN_USER_PASSWORD
  echo

  generate_credentials "$ADMIN_USER_PASSWORD" "$CONTROL_PLANE_STACK_NAME"
  CONTROL_PLANE_API_ENDPOINT=$(aws cloudformation describe-stacks \
    --stack-name "$CONTROL_PLANE_STACK_NAME" \
    --query "Stacks[0].Outputs[?contains(OutputKey,'controlPlaneAPIEndpoint')].OutputValue" \
    --output text)

  if $DEBUG; then
    echo "CONTROL_PLANE_API_ENDPOINT: $CONTROL_PLANE_API_ENDPOINT"
  fi

  printf "CONTROL_PLANE_STACK_NAME=%s\nCONTROL_PLANE_API_ENDPOINT=%s\nADMIN_USER_PASSWORD=\'%s\'\nEMAIL_USERNAME=%s\nEMAIL_DOMAIN=%s\nACCESS_TOKEN=%s\n" \
    "$CONTROL_PLANE_STACK_NAME" "$CONTROL_PLANE_API_ENDPOINT" "$ADMIN_USER_PASSWORD" "$EMAIL_USERNAME" "$EMAIL_DOMAIN" "$ACCESS_TOKEN" >"$CONFIG_FILE"

  if $DEBUG; then
    echo "Configuration saved to $CONFIG_FILE"
  fi
  echo "Successfully configured SaaS admin credentials"
}

refresh_tokens() {
  source_config

  if $DEBUG; then
    echo "Refreshing tokens..."
  fi

  generate_credentials "$ADMIN_USER_PASSWORD" "$CONTROL_PLANE_STACK_NAME"
  CONTROL_PLANE_API_ENDPOINT=$(aws cloudformation describe-stacks \
    --stack-name "$CONTROL_PLANE_STACK_NAME" \
    --query "Stacks[0].Outputs[?contains(OutputKey,'controlPlaneAPIEndpoint')].OutputValue" \
    --output text)

  printf "CONTROL_PLANE_STACK_NAME=%s\nCONTROL_PLANE_API_ENDPOINT=%s\nADMIN_USER_PASSWORD=\'%s\'\nEMAIL_USERNAME=%s\nEMAIL_DOMAIN=%s\nACCESS_TOKEN=%s\nACCESS_TOKEN=%s\n" \
    "$CONTROL_PLANE_STACK_NAME" "$CONTROL_PLANE_API_ENDPOINT" "$ADMIN_USER_PASSWORD" "$EMAIL_USERNAME" "$EMAIL_DOMAIN" "$ACCESS_TOKEN" "$ACCESS_TOKEN" >"$CONFIG_FILE"

  if $DEBUG; then
    echo "Tokens refreshed and saved to $CONFIG_FILE"
  fi
}

source_config() {
  source "$CONFIG_FILE"
}

create_tenant() {
  TENANT_NAME="$1"
  TENANT_EMAIL="$TENANT_NAME@example.com"
  source_config
  
  if $DEBUG; then
    echo "Creating tenant with:"
    echo "TENANT_NAME: $TENANT_NAME"
    echo "TENANT_EMAIL: $TENANT_EMAIL"
  fi

  DATA=$(jq --null-input \
    --arg tenantName "$TENANT_NAME" \
    --arg tenantEmail "$TENANT_EMAIL" \
    '{
      "tenantData": {
        "tenantName": $tenantName,
        "email": $tenantEmail,
        "tier": "basic",
        "prices": [
          {
            "id": "price_123456789Example",
            "metricName": "productsSold"
          },
          {
            "id": "price_123456789AnotherExample",
            "metricName": "plusProductsSold"
          }
        ]
      },
      "tenantRegistrationData": {
        "registrationStatus": "In progress",
        "tenantRegistrationData1": "test"
      }
    }')

  RESPONSE=$(curl --request POST \
    --url "${CONTROL_PLANE_API_ENDPOINT}tenant-registrations" \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    --header 'content-type: application/json' \
    --data "$DATA" \
    --silent)

  if $DEBUG; then
    echo "Response: $RESPONSE"
  else
    echo "$RESPONSE"
  fi
}

get_tenant_registration() {
  source_config
  TENANT_REGISTRATION_ID="$1"

  if $DEBUG; then
    echo "Getting tenant registration with ID: $TENANT_REGISTRATION_ID"
  fi

  RESPONSE=$(curl --request GET \
    --url "${CONTROL_PLANE_API_ENDPOINT}tenant-registrations/$TENANT_REGISTRATION_ID" \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --silent)

  if $DEBUG; then
    echo "Response: $RESPONSE"
  else
    echo "$RESPONSE"
  fi
}

get_all_tenant_registrations() {
  source_config
  MY_LIMIT="${1:-10}"
  NEXT_TOKEN="${2:-}"

  if $DEBUG; then
    echo "Getting all tenant registrations"
  fi

  RESPONSE=$(curl -G --request GET \
    --url "${CONTROL_PLANE_API_ENDPOINT}tenant-registrations?limit=${MY_LIMIT}" \
    --data-urlencode "next_token=${NEXT_TOKEN}" \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --silent)

  if $DEBUG; then
    echo "Response: $RESPONSE"
  else
    echo "$RESPONSE"
  fi
}


update_tenant_registration() {
  source_config
  TENANT_REGISTRATION_ID="$1"
  KEY="$2"
  VALUE="$3"

  DATA=$(jq --null-input \
    --arg key "$KEY" \
    --arg value "$VALUE" \
    '{ "tenantRegistrationData": {($key): $value}, "tenantData": {($key): $value}}')

  if $DEBUG; then
    echo "Updating tenant registration with ID: $TENANT_REGISTRATION_ID with DATA: $DATA"
  fi

  RESPONSE=$(curl --request PATCH \
    --url "${CONTROL_PLANE_API_ENDPOINT}tenant-registrations/$TENANT_REGISTRATION_ID" \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header 'content-type: application/json' \
    --data "$DATA" \
    --silent)

  if $DEBUG; then
    echo "Response: $RESPONSE"
  else
    echo "$RESPONSE"
  fi
}

delete_tenant_registration() {
  source_config
  TENANT_REGISTRATION_ID="$1"

  if $DEBUG; then
    echo "Deleting tenant registration with ID: $TENANT_REGISTRATION_ID"
  fi

  RESPONSE=$(curl --request DELETE \
    --url "${CONTROL_PLANE_API_ENDPOINT}tenant-registrations/$TENANT_REGISTRATION_ID" \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header 'content-type: application/json' \
    --silent)

  if $DEBUG; then
    echo "Response: $RESPONSE"
  else
    echo "$RESPONSE"
  fi
}


get_tenant() {
  source_config
  TENANT_ID="$1"

  if $DEBUG; then
    echo "Getting tenant with ID: $TENANT_ID"
  fi

  RESPONSE=$(curl --request GET \
    --url "${CONTROL_PLANE_API_ENDPOINT}tenants/$TENANT_ID" \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --silent)

  if $DEBUG; then
    echo "Response: $RESPONSE"
  else
    echo "$RESPONSE"
  fi
}

get_all_tenants() {
  source_config

  if $DEBUG; then
    echo "Getting all tenants"
  fi

  MY_LIMIT="${1:-10}"
  NEXT_TOKEN="${2:-}"

  RESPONSE=$(curl -G --request GET \
    --url "${CONTROL_PLANE_API_ENDPOINT}tenants?limit=${MY_LIMIT}" \
    --data-urlencode "next_token=${NEXT_TOKEN}" \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --silent | jq)

  if $DEBUG; then
    echo "Response: $RESPONSE"
  else
    echo "$RESPONSE"
  fi
}

create_user() {
  source_config
  USER_NAME="user$RANDOM"
  USER_EMAIL="${EMAIL_USERNAME}+${USER_NAME}@${EMAIL_DOMAIN}"

  if $DEBUG; then
    echo "Creating user with:"
    echo "USER_NAME: $USER_NAME"
    echo "USER_EMAIL: $USER_EMAIL"
  fi

  DATA=$(jq --null-input \
    --arg userName "$USER_NAME" \
    --arg email "$USER_EMAIL" \
    '{
      "userName": $userName,
      "email": $email,
      "userRole": "basicUser"
    }')

  RESPONSE=$(curl --request POST \
    --url "${CONTROL_PLANE_API_ENDPOINT}users" \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header 'content-type: application/json' \
    --data "$DATA" \
    --silent)

  if $DEBUG; then
    echo "Response: $RESPONSE"
  else
    echo "$RESPONSE"
  fi
}

get_all_users() {
  source_config
  MY_LIMIT="${1:-10}"
  NEXT_TOKEN="${2:-}"

  if $DEBUG; then
    echo "Getting all users"
  fi

  RESPONSE=$(curl -G --request GET \
    --url "${CONTROL_PLANE_API_ENDPOINT}users?limit=${MY_LIMIT}" \
    --data-urlencode "next_token=${NEXT_TOKEN}" \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --silent)

  if $DEBUG; then
    echo "Response: $RESPONSE"
  else
    echo "$RESPONSE"
  fi
}

get_user() {
  source_config
  USER_ID="$1"

  if $DEBUG; then
    echo "Getting user with id: $USER_ID"
  fi

  RESPONSE=$(curl --request GET \
    --url "${CONTROL_PLANE_API_ENDPOINT}users/$USER_ID" \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --silent)

  if $DEBUG; then
    echo "Response: $RESPONSE"
  else
    echo "$RESPONSE"
  fi
}

update_user() {
  source_config
  USER_ID="$1"
  USER_ROLE="${2:-}"
  USER_EMAIL="${3:-}"

  DATA=$(jq --null-input \
    --arg userRole "$USER_ROLE" \
    --arg email "$USER_EMAIL" \
    '{
      userRole: $userRole,
      email: $email
    }' | jq 'with_entries(select(.value != null))')

  if $DEBUG; then
    echo "Updating user with ID: $USER_ID with DATA: $DATA"
  fi

  RESPONSE=$(curl --request PUT \
    --url "${CONTROL_PLANE_API_ENDPOINT}users/$USER_ID" \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header 'content-type: application/json' \
    --data "$DATA" \
    --silent)

  if $DEBUG; then
    echo "Response: $RESPONSE"
  else
    echo "$RESPONSE"
  fi
}

delete_user() {
  source_config
  USER_ID="$1"

  if $DEBUG; then
    echo "Deleting user with id: $USER_ID"
  fi

  RESPONSE=$(curl --request DELETE \
    --url "${CONTROL_PLANE_API_ENDPOINT}users/$USER_ID" \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --silent)

  if $DEBUG; then
    echo "Response: $RESPONSE"
  else
    echo "$RESPONSE"
  fi
}

update_token_limit() {
  source_config

  TENANT_NAME="$1"
  INPUT_TOKENS="$2"
  OUTPUT_TOKENS="$3"

  tenants=$(get_all_tenants)

  # Extract the tenantId for the matching tenantName
  TENANT_ID=$(echo "$tenants" | jq -r ".data[] | select(.tenantName==\"$TENANT_NAME\") | .tenantId")
  TENANT_REGISTRATION_ID=$(echo "$tenants" | jq -r ".data[] | select(.tenantName==\"$TENANT_NAME\") | .tenantRegistrationId")


  if [ -z "$TENANT_ID" ] || [ "$TENANT_ID" = "null" ]; then
    echo "Error: Could not find tenant ID for tenant name: $TENANT_NAME" >&2
    return 1
  fi

  # Fetch the current tenantConfig
  CURRENT_CONFIG=$(curl --silent --request GET \
    --url "${CONTROL_PLANE_API_ENDPOINT}tenants/$TENANT_ID" \
    --header "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.data.tenantConfig')

echo "config: $CURRENT_CONFIG"
  # Update only the tokens while preserving other fields
  UPDATED_CONFIG=$(echo $CURRENT_CONFIG | jq \
    --arg inputTokens "$INPUT_TOKENS" \
    --arg outputTokens "$OUTPUT_TOKENS" \
    '.inputTokens = $inputTokens | .outputTokens = $outputTokens')

echo "update: $UPDATED_CONFIG"
  # Construct the full update payload
  DATA=$(jq --null-input \
    --arg tenantConfig "$UPDATED_CONFIG" \
    '{"tenantConfig": $tenantConfig}')

  if $DEBUG; then
    echo "CURRENT CONFIG: $CURRENT_CONFIG"
    echo "UPDATED CONFIG: $UPDATED_CONFIG"
  fi

  # Send the PUT request
  RESPONSE=$(curl --request PATCH \
    --url "${CONTROL_PLANE_API_ENDPOINT}tenant-registrations/$TENANT_REGISTRATION_ID" \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header 'content-type: application/json' \
    --data "$DATA" \
    --write-out '%{http_code}' \
    --silent \
    --output /dev/null)

  if [ "$RESPONSE" -eq 200 ]; then
    echo "Tenant $TENANT_NAME updated to $INPUT_TOKENS input tokens and $OUTPUT_TOKENS output tokens"
  else
    echo "Error updating tenant $TENANT_NAME: HTTP status code $RESPONSE" >&2
  fi
}

upload_file() {
  
  USER="$1"
  PASSWORD="$2"
  FILE_LOCATION="$3"

  STACK_NAME="saas-genai-workshop-bootstrap-template"
  APP_CLIENT_ID_OUTPUT_PARAM_NAME="UserPoolClientId"
  API_GATEWAY_URL_OUTPUT_PARAM_NAME="ApiGatewayUrl"

  export SAAS_APP_CLIENT_ID=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='$APP_CLIENT_ID_OUTPUT_PARAM_NAME'].OutputValue" --output text)
  export API_GATEWAY_URL=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='$API_GATEWAY_URL_OUTPUT_PARAM_NAME'].OutputValue" --output text)

  AUTHENTICATION_RESULT=$(aws cognito-idp initiate-auth \
    --auth-flow USER_PASSWORD_AUTH \
    --client-id "${SAAS_APP_CLIENT_ID}" \
    --auth-parameters "USERNAME='${USER}',PASSWORD='${PASSWORD}'" \
    --query 'AuthenticationResult')

  ACCESS_TOKEN=$(echo "$AUTHENTICATION_RESULT" | jq -r '.AccessToken')
  ID_TOKEN=$(echo "$AUTHENTICATION_RESULT" | jq -r '.IdToken')

  TENANT_DATA=$(jq -n --arg content "$(cat "$FILE_LOCATION")" '{"fileContent": $content}')

  RESPONSE=$(curl --request POST \
    --url "${API_GATEWAY_URL}upload" \
    --header "Authorization: Bearer ${ID_TOKEN}" \
    --header 'content-type: application/json' \
    --data "$TENANT_DATA" \
    --silent)

  echo $RESPONSE

}

invoke() {
  
  USER="$1"
  PASSWORD="$2"
  QUERY="$3"
  REQUESTS="$4"

  STACK_NAME="saas-genai-workshop-bootstrap-template"
  APP_CLIENT_ID_OUTPUT_PARAM_NAME="UserPoolClientId"
  API_GATEWAY_URL_OUTPUT_PARAM_NAME="ApiGatewayUrl"
  

  export SAAS_APP_CLIENT_ID=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='$APP_CLIENT_ID_OUTPUT_PARAM_NAME'].OutputValue" --output text)
  export API_GATEWAY_URL=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='$API_GATEWAY_URL_OUTPUT_PARAM_NAME'].OutputValue" --output text)

  AUTHENTICATION_RESULT=$(aws cognito-idp initiate-auth \
    --auth-flow USER_PASSWORD_AUTH \
    --client-id "${SAAS_APP_CLIENT_ID}" \
    --auth-parameters "USERNAME='${USER}',PASSWORD='${PASSWORD}'" \
    --query 'AuthenticationResult')

  ACCESS_TOKEN=$(echo "$AUTHENTICATION_RESULT" | jq -r '.AccessToken')
  ID_TOKEN=$(echo "$AUTHENTICATION_RESULT" | jq -r '.IdToken')

  if $DEBUG; then
    echo "Creating tenant with:"
    echo "API GATEWAY URL: $API_GATEWAY_URL"
    echo "TENANT_EMAIL: $TENANT_EMAIL"
  fi

  echo "Sending request and waiting for response..."

  for i in $(seq 1 ${REQUESTS})
    do
      RESPONSE=$(curl -s -w '\n%{http_code}' -X POST \
      -H "Authorization: Bearer ${ID_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$QUERY" \
      "${API_GATEWAY_URL}invoke")

      BODY=$(echo "$RESPONSE" | sed '$d')
      HTTP_STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
      echo "Request $i - HTTP Status Code: $HTTP_STATUS_CODE, Output Text: $BODY" &
      sleep 12
    done
    wait
    echo "All done"

}

execute_query() {
  USER="$1"
  PASSWORD="$2"
  QUERY="$3"

  STACK_NAME="saas-genai-workshop-bootstrap-template"
  APP_CLIENT_ID_OUTPUT_PARAM_NAME="UserPoolClientId"
  API_GATEWAY_URL_OUTPUT_PARAM_NAME="ApiGatewayUrl"

  export SAAS_APP_CLIENT_ID=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='$APP_CLIENT_ID_OUTPUT_PARAM_NAME'].OutputValue" --output text)
  export API_GATEWAY_URL=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='$API_GATEWAY_URL_OUTPUT_PARAM_NAME'].OutputValue" --output text)

  AUTHENTICATION_RESULT=$(aws cognito-idp initiate-auth \
    --auth-flow USER_PASSWORD_AUTH \
    --client-id "${SAAS_APP_CLIENT_ID}" \
    --auth-parameters "USERNAME='${USER}',PASSWORD='${PASSWORD}'" \
    --query 'AuthenticationResult')

  ACCESS_TOKEN=$(echo "$AUTHENTICATION_RESULT" | jq -r '.AccessToken')
  ID_TOKEN=$(echo "$AUTHENTICATION_RESULT" | jq -r '.IdToken')

  echo "Sending request and waiting for response..."

  RESPONSE=$(curl --request POST \
    --url "${API_GATEWAY_URL}invoke" \
    --header "Authorization: Bearer ${ID_TOKEN}" \
    --header 'content-type: application/json' \
    --data "$QUERY" \
    --silent)

  echo -e "$RESPONSE" | tr '\n' '\n'

}

get_knowledge_base_id() {
  TENANT_NAME="$1"

  if [ -z "$TENANT_NAME" ]; then
    echo "Error: Tenant name not provided"
    return 1
  fi

  if $DEBUG; then
    echo "Getting Knowledge Base ID per tenant name"
  fi

  # Get all tenants
  tenants=$(get_all_tenants)
  # Extract the knowledgeBaseId for the given tenantName
  KB_ID=$(echo "$tenants" | jq -r ".data[] | select(.tenantName==\"$TENANT_NAME\") | .tenantConfig | fromjson | .knowledgeBaseId")
  
  if [ -z "$KB_ID" ]; then
    echo "Error: Tenant with name '$tenant_name' not found"
    return 1
  fi

  echo "Knowledge Base id for $TENANT_NAME is: $KB_ID"
}

# Main
DEBUG=false
if [ "$1" = "--debug" ]; then
  DEBUG=true
  shift
fi

if [ $# -eq 0 ]; then
  help
  exit 1
fi

case "$1" in
"configure")
  shift
  configure "$@"
  ;;

"refresh-tokens")
  refresh_tokens
  ;;

"create-tenant")
  if [ $# -ne 2 ]; then
    echo "Error: create-tenant requires tenant name"
    exit 1
  fi
  create_tenant "$2"
  ;;

"get-tenant-registration")
  if [ $# -ne 2 ]; then
    echo "Error: get-tenant-registration requires tenant registration id"
    exit 1
  fi
  get_tenant_registration "$2"
  ;;

"get-all-tenant-registrations")
  get_all_tenant_registrations "$2" "$3"
  ;;

"update-tenant-registration")
  if [ $# -ne 4 ]; then
    echo "Error: update-tenant-registration requires tenant registration id, key, and value"
    exit 1
  fi
  update_tenant_registration "$2" "$3" "$4"
  ;;

"delete-tenant-registration")
  if [ $# -ne 2 ]; then
    echo "Error: delete-tenant-registration requires tenant registration id"
    exit 1
  fi
  delete_tenant_registration "$2"
  ;;

"get-tenant")
  if [ $# -ne 2 ]; then
    echo "Error: get-tenant requires tenant id"
    exit 1
  fi
  get_tenant "$2"
  ;;

"get-all-tenants")
  get_all_tenants "$2" "$3"
  ;;

"get-knowledge-base-id")
  if [ $# -ne 2 ]; then
    echo "Error: get-knowledge-base-id requires tenant name"
    exit 1
  fi
  get_knowledge_base_id "$2"
  ;;

"update-token-limit")
  if [ $# -ne 4 ]; then
    echo "Error: update-tenant requires tenant name, input tokens, and output tokens"
    exit 1
  fi
  update_token_limit "$2" "$3" "$4"
  ;;

"upload-file")
  if [ $# -ne 4 ]; then
    echo "Error: update-file requires tenant username, password, and data"
    exit 1
  fi
  upload_file "$2" "$3" "$4"
  ;;

"invoke")
  if [ $# -ne 5 ]; then
    echo "Error: invoke requires tenant username, password, query, number of requests"
    exit 1
  fi
  invoke "$2" "$3" "$4" "$5"
  ;;

"execute-query")
  if [ $# -ne 4 ]; then
    echo "Error: execute-query requires tenant username, password, and query"
    exit 1
  fi
  execute_query "$2" "$3" "$4"
  ;;

"create-user")
  create_user
  ;;

"get-all-users")
  get_all_users "$2" "$3"
  ;;

"get-user")
  if [ $# -ne 2 ]; then
    echo "Error: get-user requires user id"
    exit 1
  fi
  get_user "$2"
  ;;

"update-user")
  if [ $# -ne 4 ]; then
    echo "Error: update-user requires user id and new (or same) user role and user email"
    exit 1
  fi
  update_user "$2" "$3" "$4"
  ;;

"delete-user")
  if [ $# -ne 2 ]; then
    echo "Error: delete-user requires user id"
    exit 1
  fi
  delete_user "$2"
  ;;

"help")
  help
  ;;

*)
  echo "Invalid operation: $1"
  help
  exit 1
  ;;
esac