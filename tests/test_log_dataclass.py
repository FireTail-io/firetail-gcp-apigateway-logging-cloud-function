import json
import os
import sys

sys.path.insert(0, ".")
sys.path.insert(1, "src/")
current_dir = os.path.dirname(__file__)

os.environ["FIRETAIL_APP_TOKEN"] = "fake"
os.environ["PROJECT_ID"] = "fake"
os.environ["SUBSCRIPTION_ID"] = "fake"


def read_file(file_name):
    with open(file_name) as f:
        return json.loads(f.read())


LOG = os.path.join(current_dir, "examples/2_dynamic_paths.json")
from main import FireTailLog


def test_log_processed():
    log_file = read_file(LOG)
    result = FireTailLog.load_log(log_file)
    assert result.to_dict() == {
        "version": "1.0.0-alpha",
        "metadata": {
            "apiId": "//apigateway.googleapis.com/projects/61377165045/locations/global/apis/firetail-testing-api-gateway",
            "apiConfig": "//apigateway.googleapis.com/projects/61377165045/locations/global/apis/firetail-testing-api-gateway/configs/test",
            "apiKey": "",
            "apiMethod": "1.firetail_testing_api_gateway_022u7tyhkefhv_apigateway_gcp_test_395910_cloud_goog.Pet_id",
            "backendRequestDuration": "29ms",
            "backendRequestHostname": "backend-cluster-google.com:443",
            "backendRequestPath": "/?pet_id=1&pet2_id=67",
            "consumerNumber": "0",
            "responseDetails": "via_upstream",
            "logName": "projects/gcp-test-395910/logs/apigateway.googleapis.com%2Frequests",
            "resourceType": "apigateway.googleapis.com/Gateway",
            "requestPayload": False,
            "responsePayload": False,
        },
        "request": {
            "method": "POST",
            "httpProtocol": "HTTP/1.1",
            "uri": "https://gatewat-s72dnn9.nw.gateway.dev/pets/1/67",
            "resource": "/pets/{pet_id}/{pet2_id}",
            "ip": "109.77.144.121",
            "headers": {"User-Agent": ["PostmanRuntime/7.35.0"]},
        },
        "response": {"statusCode": 405, "headers": {"Content-Length": ["1613"]}},
        "executionTime": 29,
        "dateCreated": 1702587460111,
    }
