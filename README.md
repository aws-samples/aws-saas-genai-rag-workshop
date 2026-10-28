## SaaS GenAI RAG Workshop

Follow this link for detailed instructions to run this workshop: https://catalog.us-east-1.prod.workshops.aws/workshops/224f4cc0-cefb-4e29-95fa-365ad5a7ef28

## Retrieving user passwords

This workshop does not ship a known password. Every user it provisions gets a
randomly generated one, stored as an encrypted `SecureString` in AWS Systems
Manager Parameter Store, which only an IAM principal you authorize can read.

> If the workshop instructions ask you to sign in with a fixed password such as
> `SaaS123!`, use the commands below instead. A password committed to a public
> repository is a password published to everyone who deploys from it, so this
> workshop generates one per deployment.

Control plane administrator:

```bash
# The parameter name uses your admin email with characters outside
# [a-zA-Z0-9_.-] replaced by underscores, because Parameter Store names
# cannot contain '@'.
aws ssm get-parameters-by-path \
  --path "/saas-genai-workshop/control-plane" --recursive \
  --query 'Parameters[].Name' --output text

aws ssm get-parameter \
  --name "/saas-genai-workshop/control-plane/<admin_email>/password" \
  --with-decryption --query 'Parameter.Value' --output text
```

Tenant user:

```bash
# As above, <email> has any character outside [a-zA-Z0-9_.-] replaced by an
# underscore, so user@example.com is stored as user_example.com. Listing the
# path is the reliable way to find the exact name.
aws ssm get-parameters-by-path \
  --path "/saas-genai-workshop/tenant/<tenantId>/users" --recursive \
  --query 'Parameters[].Name' --output text

aws ssm get-parameter \
  --name "/saas-genai-workshop/tenant/<tenantId>/users/<email>/password" \
  --with-decryption --query 'Parameter.Value' --output text
```

To list everything that was provisioned for a tenant, including the tenant's API
key:

```bash
aws ssm get-parameters-by-path \
  --path "/saas-genai-workshop/tenant/<tenantId>" --recursive \
  --query 'Parameters[].Name' --output text
```

`scripts/cleanup.sh` deletes these parameters during teardown.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

### Tenant identity is assigned server side

Tenant isolation in this workshop depends on the `custom:tenantId` Cognito
attribute, which the API authorizer reads to decide which tenant's data a caller
may reach. That attribute is therefore **not** listed in the user pool client's
`writeAttributes`: anything in that list can be changed by a signed-in user with
nothing but their own access token, through Cognito's `UpdateUserAttributes`
API, without passing through the API or any authorization in it.

`custom:tenantId` and `custom:userRole` are set only through the admin-side
`AdminCreateUser` / `AdminUpdateUserAttributes` calls in
`cdk/lib/tenant-template/user-management/user_management_service.py`. If you
adapt this workshop, keep any attribute that feeds an authorization decision out
of `writeAttributes`, and audit your own app clients for the same pattern.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
