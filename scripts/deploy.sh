
# Step 1: Upload the updated code to the S3 bucket which reads by the provision-tenant.sh
cd ~/saas-genai-workshop
aws s3 cp "$FOLDER_PATH" "s3://$S3_TENANT_SOURCECODE_BUCKET_URL" --recursive --exclude "cdk.out/*" --exclude "node_modules/*" --exclude ".git/*"

# Step 2: Deploys the tenant-template.stack

cd ~/saas-genai-workshop/cdk
npx cdk deploy saas-genai-workshop-bootstrap-template --require-approval never --concurrency 10 --asset-parallelism true