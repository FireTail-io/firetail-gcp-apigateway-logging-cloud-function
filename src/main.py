import json
import os
import time
from dataclasses import dataclass
from urllib.parse import urlparse

import ndjson
import requests
from dataclasses_json import dataclass_json
from dateutil import parser as date_parser
from google.api_core import retry
from google.cloud import pubsub_v1

REQUESTS_SESSION = requests.Session()

FIRETAIL_API = os.getenv(
    "FIRETAIL_API", "https://api.logging.eu-west-1.prod.firetail.app/aws/lb/bulk"
)
FIRETAIL_APP_TOKEN = os.environ["FIRETAIL_APP_TOKEN"]
PROJECT_ID = os.environ["PROJECT_ID"]  # "gcp-test-395910"
SUBSCRIPTION_ID = os.environ["SUBSCRIPTION_ID"]  # "firetail"
MAX_MESSAGES = os.getenv("MAX_MESSAGES", 10)


class FireTailFailedIngest(Exception):
    pass


class InvalidRequest(Exception):
    pass


class InvalidRawGCPLog(Exception):
    pass


def ship_logs(logs: list):
    if logs == []:
        return
    for i in range(0, len(logs), 100):
        response = REQUESTS_SESSION.post(
            url=FIRETAIL_API,
            headers={"x-ft-app-key": FIRETAIL_APP_TOKEN},
            data=ndjson.dumps(logs[i : i + 100]),
        )
        if response.status_code != 201:
            raise FireTailFailedIngest(response.text)
    return response.json()


def get_param_from_url(url):
    return [i.split("=") for i in url.split("?", 1)[-1].split("&")]


def get_resource_path(uri: str, backendPath: str):
    parsed_path = urlparse(uri).path
    if "?" not in backendPath:
        return parsed_path

    query_list = get_param_from_url(backendPath)
    path_parts = parsed_path.split("/")

    for i, (query_key, query_value) in enumerate(reversed(query_list)):
        if path_parts[-1 - i] != query_value:
            continue
        path_parts[-1 - i] = f"{{{query_key}}}"

    return "/".join(path_parts)


def calc_datecreated_time(datecreated_str: str) -> int:
    try:
        return int(date_parser.parse(datecreated_str).timestamp() * 1000)
    except Exception:
        return int(time.time() * 1000)


@dataclass_json
@dataclass
class FireTailMetadata:
    apiId: str
    apiConfig: str
    apiKey: str
    apiMethod: str
    backendRequestDuration: str
    backendRequestHostname: str
    backendRequestPath: str
    consumerNumber: str
    responseDetails: str
    logName: str
    resourceType: str
    requestPayload: bool
    responsePayload: bool

    @staticmethod
    def load_metadata(log: dict):
        return FireTailMetadata(
            apiId=log.get("jsonPayload", {}).get("api"),
            apiConfig=log.get("jsonPayload", {}).get("apiConfig"),
            apiKey=log.get("jsonPayload", {}).get("apiKey"),
            apiMethod=log.get("jsonPayload", {}).get("apiMethod"),
            backendRequestDuration=log.get("jsonPayload", {})
            .get("backendRequest", {})
            .get("duration", "0ms"),
            backendRequestHostname=log.get("jsonPayload", {})
            .get("backendRequest", {})
            .get(
                "hostname",
            ),
            backendRequestPath=log.get("jsonPayload", {})
            .get("backendRequest", {})
            .get("path", "/"),
            consumerNumber=log.get("jsonPayload", {}).get("consumerNumber"),
            responseDetails=log.get("jsonPayload", {}).get("responseDetails"),
            logName=log.get("logName"),
            resourceType=log.get("resource", {}).get(
                "type", "apigateway.googleapis.com/Gateway"
            ),
            requestPayload=False,
            responsePayload=False,
        )


@dataclass_json
@dataclass
class FireTailRequest:
    method: str
    httpProtocol: str
    uri: str
    resource: str
    ip: str
    headers: dict[str, list[str]]

    @staticmethod
    def load_request(log: dict):
        uri = log.get("httpRequest", {}).get("requestUrl")
        backendPath = (
            log.get("jsonPayload", {}).get("backendRequest", {}).get("path", "/")
        )
        resource = get_resource_path(uri, backendPath)
        return FireTailRequest(
            method=log.get("httpRequest", {}).get("requestMethod"),
            httpProtocol=log.get("httpRequest", {}).get("protocol"),
            uri=uri,
            resource=resource,
            headers={"User-Agent": [log.get("httpRequest", {}).get("userAgent")]},
            ip=log.get("httpRequest", {}).get("remoteIp"),
        )


@dataclass_json
@dataclass
class FireTailResponse:
    statusCode: int
    headers: dict[str, list[str]]

    @staticmethod
    def load_response(log: dict):
        return FireTailResponse(
            statusCode=log.get("httpRequest", {}).get("status"),
            headers={
                "Content-Length": [log.get("httpRequest", {}).get("responseSize", 0)]
            },
        )


@dataclass_json
@dataclass
class FireTailLog:
    version: str
    metadata: FireTailMetadata
    request: FireTailRequest
    response: FireTailResponse
    executionTime: int
    dateCreated: int

    @staticmethod
    def load_log(log: dict):
        execution_time = (
            log.get("jsonPayload", {}).get("backendRequest", {}).get("duration", "0ms")
        )
        try:
            execution_time = int(execution_time.replace("ms", ""))
        except:
            execution_time = 0
        return FireTailLog(
            version="1.0.0-alpha",
            metadata=FireTailMetadata.load_metadata(log),
            request=FireTailRequest.load_request(log),
            response=FireTailResponse.load_response(log),
            executionTime=execution_time,
            dateCreated=calc_datecreated_time(log["timestamp"]),
        )


def process_bulk_messages(subscriber, subscription_path, max_messages=3):
    # Wrap the subscriber in a 'with' block to automatically call close() to
    # close the underlying gRPC channel when done.
    with subscriber:
        # The subscriber pulls a specific number of messages. The actual
        # number of messages pulled may be smaller than max_messages.
        while True:
            time.sleep(2)
            response = subscriber.pull(
                request={
                    "subscription": subscription_path,
                    "max_messages": max_messages,
                },
                retry=retry.Retry(deadline=300),
            )

            if len(response.received_messages) == 0:
                continue

            ack_ids = []
            logs = []
            for received_message in response.received_messages:
                print(f"Received: {received_message.message.data}.")
                data = json.loads(received_message.message.data.decode())
                logs.append(FireTailLog.load_log(data))
                ack_ids.append(received_message.ack_id)
            ship_logs(logs)
            # Acknowledges the received messages so they will not be sent again.
            subscriber.acknowledge(
                request={"subscription": subscription_path, "ack_ids": ack_ids}
            )


if __name__ == "__main__":
    subscriber = pubsub_v1.SubscriberClient()
    subscription_path = subscriber.subscription_path(PROJECT_ID, SUBSCRIPTION_ID)

    process_bulk_messages(subscriber, subscription_path, MAX_MESSAGES)
