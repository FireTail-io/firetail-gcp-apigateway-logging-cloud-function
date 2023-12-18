import os
import sys

sys.path.insert(0, ".")
sys.path.insert(1, "src/")

from main import get_resource_path

os.environ['FIRETAIL_APP_TOKEN'] = "fake"
os.environ['PROJECT_ID'] = "fake"
os.environ['SUBSCRIPTION_ID'] = "fake"

def test_resource_path():
    result = get_resource_path("https://gatewat-s72dnn9.nw.gateway.dev/pets/1/37", "/?item2=37")
    assert result == "/pets/1/{item2}"


def test_resource_path_2():
    result = get_resource_path("https://gatewat-s72dnn9.nw.gateway.dev/pets/1/37", "/?hello=1&item2=37")
    assert result == "/pets/{hello}/{item2}"


def test_resource_path_3():
    result = get_resource_path("https://gatewat-s72dnn9.nw.gateway.dev/pets/1/37", "/?hello=1&item2=3")
    assert result == "/pets/{hello}/37"


def test_resource_path_4():
    result = get_resource_path("https://gatewat-s72dnn9.nw.gateway.dev/pets/1/37", "/")
    assert result == "/pets/1/37"
