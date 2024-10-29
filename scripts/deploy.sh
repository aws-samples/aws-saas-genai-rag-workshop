# Check if stack name parameter is provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <STACK_NAME>"
    echo "Example: $0 my-stack-name"
    exit 1
fi

# Get the stack name from command line argument
STACK_NAME="$1"

# Step 2: Upload the updated code to the S3 bucket which reads by the provision-tenant.sh
S3_TENANT_SOURCECODE_BUCKET_URL=$(aws cloudformation describe-stacks --stack-name saas-genai-workshop-bootstrap-template --query "Stacks[0].Outputs[?OutputKey=='TenantSourceCodeS3Bucket'].OutputValue" --output text)
echo "S3 bucket url: $S3_TENANT_SOURCECODE_BUCKET_URL"

cd ..
aws s3 cp "." "s3://$S3_TENANT_SOURCECODE_BUCKET_URL" --recursive --exclude "cdk/cdk.out/*" --exclude "cdk/node_modules/*" --exclude ".git/*"

# Step 2: Deploys the tenant-template.stack

cd cdk
npx cdk deploy $STACK_NAME --require-approval never --concurrency 10 --asset-parallelism true

