import base64
import json
import os
import time
from dataclasses import dataclass
from urllib.parse import unquote_plus, urlparse

import functions_framework
import ndjson
import requests
from dataclasses_json import dataclass_json
from dateutil import parser as date_parser

REQUESTS_SESSION = requests.Session()
FIRETAIL_API = os.getenv(
    "FIRETAIL_API", "https://api.logging.eu-west-1.prod.firetail.app/aws/lb/bulk"
)
FIRETAIL_APP_TOKEN = os.getenv("FIRETAIL_APP_TOKEN")


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
    gatewayId: str | None = None
    location: str | None = None
    resourceContainer: str | None = None

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
            backendRequestPath=unquote_plus(
                log.get("jsonPayload", {}).get("backendRequest", {}).get("path", "/")
            ),
            consumerNumber=log.get("jsonPayload", {}).get("consumerNumber"),
            responseDetails=log.get("jsonPayload", {}).get("responseDetails"),
            logName=log.get("logName", ""),
            resourceType=log.get("resource", {}).get(
                "type", "apigateway.googleapis.com/Gateway"
            ),
            requestPayload=False,
            responsePayload=False,
            gatewayId=log.get("resource", {}).get("labels", {}).get("gateway_id"),
            location=log.get("resource", {}).get("labels", {}).get("location"),
            resourceContainer=log.get("resource", {})
            .get("labels", {})
            .get("resource_container"),
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
        uri = unquote_plus(log.get("httpRequest", {}).get("requestUrl"))
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


@functions_framework.cloud_event
def subscribe(cloud_event):
    log = json.loads(
        base64.b64decode(cloud_event.data["message"]["data"]).decode("utf-8")
    )
    ship_logs([FireTailLog.load_log(log).to_dict()])
