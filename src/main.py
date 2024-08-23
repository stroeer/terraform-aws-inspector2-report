import boto3
from botocore.client import Config
from botocore.exceptions import ClientError

from datetime import date, datetime

import json
from json import JSONEncoder

import logging
import os

bucket = os.getenv('BUCKET_NAME', 'costoptimizationdata232827378724')
prefix = os.getenv('PREFIX', 'inspector-cve-reports')
role_name = os.getenv('ROLE_NAME', 'SecurityAudit')
crawler = os.getenv('CRAWLER_NAME', 'cve-crawler')
regions = os.getenv('REGIONS', 'eu-west-1,eu-central-1,eu-north-1,us-east-1').split(',')
output_folder = '/tmp' if os.getenv("AWS_LAMBDA_FUNCTION_NAME", '') else 'reports'
# Configure logging
LOG_FORMAT = os.getenv('LOG_FORMAT', 'json' if os.getenv("AWS_LAMBDA_FUNCTION_NAME", '') else 'text')  # Set 'json' for structured logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

if LOG_FORMAT == 'json':
    handler = logging.StreamHandler()
    formatter = logging.Formatter(json.dumps({
        "timestamp": "%(asctime)s",
        "level": "%(levelname)s",
        "message": "%(message)s"
    }))
    handler.setFormatter(formatter)
    logger.addHandler(handler)
else:
    logging.basicConfig(format='%(asctime)s - %(levelname)s - %(message)s')

def get_all_account_ids():
    org_client = boto3.client('organizations')
    paginator = org_client.get_paginator('list_accounts')
    root_account = org_client.describe_organization()['Organization']['MasterAccountId']
    account_ids = []
    for page in paginator.paginate():
        for account in page['Accounts']:
            if account['Id'] != root_account:
                account_ids.append(account['Id'])
    logger.info(f"Found {account_ids} accounts in the organization")
    return account_ids, root_account


def get_inspector_findings(client, resource_id):
    findings = []
    paginator = client.get_paginator('list_findings')
    for page in paginator.paginate(
            filterCriteria={
                'resourceId': [{'comparison': 'PREFIX', 'value': resource_id}],
                'findingStatus': [{'comparison': 'EQUALS', 'value': 'ACTIVE'}],
                'severity': [{'comparison': 'EQUALS', 'value': 'CRITICAL'}, {'comparison': 'EQUALS', 'value': 'HIGH'},
                             {'comparison': 'EQUALS', 'value': 'MEDIUM'}]
            }
    ):
        findings.extend(page['findings'])
    return findings


def get_ec2_instances(client):
    ec2_instances = client.describe_instances()
    instances = {}
    for reservation in ec2_instances['Reservations']:
        for instance in reservation['Instances']:
            instances[instance['InstanceId']] = {
                'instanceId': instance.get('InstanceId'),
                'instanceType': instance.get('InstanceType'),
                'launchTime': instance.get('LaunchTime'),
                'state': instance.get('State', {}).get('Name')
            }
    return instances


def get_lambda_functions(client):
    functions = client.list_functions()['Functions']
    lambdas = {}
    for function in functions:
        lambdas[function['FunctionArn']] = {
            'functionName': function.get('FunctionName'),
            'runtime': function.get('Runtime'),
            'lastModified': function.get('LastModified')
        }
    return lambdas


def get_ecr_images(client):
    repositories = client.describe_repositories()['repositories']
    images = {}
    for repo in repositories:
        image_details = client.describe_images(repositoryName=repo['repositoryName'])['imageDetails']
        tagged_images = {
            'production': None,
            'latest': None,
            'staging': None
        }
        other_images = []
        for image in image_details:
            if 'imageTags' in image:
                if 'production' in image['imageTags'] or 'prod' in image['imageTags']:
                    tagged_images['production'] = { "arn": f"{repo['repositoryArn']}/{image['imageDigest']}", "image_details": image }
                elif 'latest' in image['imageTags']:
                    tagged_images['latest'] = { "arn": f"{repo['repositoryArn']}/{image['imageDigest']}", "image_details": image }
                elif 'staging' in image['imageTags']:
                    tagged_images['staging'] = { "arn": f"{repo['repositoryArn']}/{image['imageDigest']}", "image_details": image }
            else:
                other_images.append(image)

        # Append the found tagged images
        for tag in ['production', 'latest', 'staging']:
            if tagged_images[tag]:
                images[tagged_images[tag]["arn"]] = tagged_images[tag]["image_details"]

        # If no tagged images were found, append the last pushed images
        if not any(tagged_images.values()) and other_images:
            sorted_images = sorted(other_images, key=lambda x: x['imagePushedAt'], reverse=True)
            for image in sorted_images[:2]:  # Change the number of images if needed
                images[f"{repo['repositoryArn']}/{image['imageDigest']}"] = image

    logger.info(f"Found {images} images in ECR repositories")
    return images


def upload_to_s3(account_id, payer_id, f_name):
    if os.path.getsize(f_name) == 0:
        logger.info(f"File {f_name} is empty, skipping upload to S3")
        return
    d = datetime.now()
    day = d.strftime("%d")
    month = d.strftime("%m")
    year = d.strftime("%Y")
    _date = d.strftime("%d%m%Y-%H%M%S")
    path = f"{prefix}/{prefix}-data/payer_id={payer_id}/year={year}/month={month}/day={day}/{prefix}-{account_id}-{_date}.json"
    try:
        s3 = boto3.client("s3", config=Config(s3={"addressing_style": "path"}))
        s3.upload_file(f_name, bucket, path )
        logger.info(f"Data for {account_id} uploaded to s3 - {path}")
    except Exception as e:
        logger.error(f"Error uploading data to S3: {e}")

def assume_role(account_id, role_name="SecurityAudit"):
    sts_client = boto3.client('sts')
    assumed_role = sts_client.assume_role(
        RoleArn=f"arn:aws:iam::{account_id}:role/{role_name}",
        RoleSessionName="InspectorCVEReport"
    )
    credentials = assumed_role['Credentials']
    return boto3.Session(
        aws_access_key_id=credentials['AccessKeyId'],
        aws_secret_access_key=credentials['SecretAccessKey'],
        aws_session_token=credentials['SessionToken']
    )

def _json_serial(obj):
    if isinstance(obj, (datetime, date)): return obj.isoformat()
    return JSONEncoder.default(obj)

def flatten_data(y):
    out = {}

    def flatten(x, name=''):
        if type(x) is dict:
            for a in x:
                flatten(x[a], name + a + '_')
        elif type(x) is list:
            i = 0
            for a in x:
                flatten(a, name + str(i) + '_')
                i += 1
        else:
            out[name[:-1]] = x

    flatten(y)
    return out


def read_inspector(account_id, f_name):
    session = assume_role(account_id)
    with open(f_name, "w") as file:
        for region in regions:
            logger.info(f"Processing region {region}, account {account_id}")
            inspector_client = session.client('inspector2', region_name=region)
            ec2_client = session.client('ec2', region_name=region)
            lambda_client = session.client('lambda', region_name=region)
            ecr_client = session.client('ecr', region_name=region)

            # Collect metadata
            ec2_instances = get_ec2_instances(ec2_client)
            lambda_functions = get_lambda_functions(lambda_client)
            ecr_images = get_ecr_images(ecr_client)

            # Collect and enrich findings for EC2 instances
            for ec2_id, ec2_metadata in ec2_instances.items():
                findings = get_inspector_findings(inspector_client, ec2_id)
                for finding in findings:
                    finding['resource_metadata'] = ec2_metadata
                    file.write(json.dumps(flatten_data(finding), default=_json_serial) + "\n")

            for function_arn, function in lambda_functions.items():
                findings = get_inspector_findings(inspector_client, function_arn)
                for finding in findings:
                    finding['resource_metadata'] = function
                    file.write(json.dumps(flatten_data(finding), default=_json_serial) + "\n")
            for image_digest, image in ecr_images.items():
                findings = get_inspector_findings(inspector_client, image_digest)
                for finding in findings:
                    finding['resource_metadata'] = image
                    file.write(json.dumps(flatten_data(finding), default=_json_serial) + "\n")

def lambda_handler(event, context):
    account_ids, root_account = get_all_account_ids()
    filter_account_ids = event.get('account_ids', [])
    if filter_account_ids:
        account_ids = [account_id for account_id in account_ids if account_id in filter_account_ids]

    logger.info(f"Fetching Inspector findings for accounts: {account_ids}")
    for account_id in account_ids:
        logger.info(f"Processing account {account_id}")
        try:
            f_name = f"{output_folder}/inspector_findings_{account_id}_report.json"
            read_inspector(account_id, f_name)
            upload_to_s3(account_id, root_account, f_name)
        except Exception as e:
            logger.error(f"Error processing account {account_id}: {e}")

    boto3.client('glue').start_crawler(Name=crawler)

if __name__ == '__main__':
    lambda_handler({"account_ids": []}, None)
