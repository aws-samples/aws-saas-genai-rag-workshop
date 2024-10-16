import boto3
from opensearchpy import OpenSearch, RequestsHttpConnection
from requests_aws4auth import AWS4Auth

# AWS configuration
region = 'us-west-2'  # Replace with your AWS region
service = 'aoss'
credentials = boto3.Session().get_credentials()
awsauth = AWS4Auth(credentials.access_key, credentials.secret_key, region, service, session_token=credentials.token)

# OpenSearch Serverless configuration
host = ''  # Replace with your collection endpoint
port = 443

# Create the OpenSearch client
client = OpenSearch(
    hosts=[{'host': host, 'port': port}],
    http_auth=awsauth,
    use_ssl=True,
    verify_certs=True,
    connection_class=RequestsHttpConnection
)

def get_index_sizes():
    
    
    # Get all indexes in the collection
    indices = client.cat.indices(format='json')
    
    print(indices)
    
    ## Print index name and data size
    for index in indices:
        index_name = index['index']
        store_size = index['store.size']
        print(f"Index: {index_name}, Data Size: {store_size}")

if __name__ == "__main__":
    get_index_sizes()