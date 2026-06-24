"""さくらのクラウド API 共通ユーティリティ。"""
from __future__ import absolute_import, division, print_function
__metaclass__ = type

import base64
import json
import time

try:
    import urllib.request as urllib_request
    import urllib.error as urllib_error
except ImportError:
    import urllib2 as urllib_request
    import urllib2 as urllib_error


def get_api_base(region):
    return "https://secure.sakura.ad.jp/cloud/zone/{}/api/cloud/1.1".format(region)


def sakura_api_request(method, url, token, secret, payload=None,
                       retries=10, retry_interval=10):
    """さくらのクラウド API へリクエストを送り、レスポンス dict を返す。

    HTTP 423 (Locked) 時は retries 回までリトライする。
    """
    credentials = base64.b64encode(
        "{}:{}".format(token, secret).encode()
    ).decode()
    headers = {"Authorization": "Basic {}".format(credentials)}
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"

    for attempt in range(retries + 1):
        req = urllib_request.Request(url, data=data, headers=headers,
                                     method=method)
        try:
            with urllib_request.urlopen(req, timeout=60) as resp:
                body = resp.read()
                return json.loads(body) if body else {}
        except urllib_error.HTTPError as e:
            if e.code == 423 and attempt < retries:
                time.sleep(retry_interval)
                continue
            body = e.read().decode(errors="replace")
            raise RuntimeError(
                "API error: {} {} → HTTP {}\n{}".format(method, url, e.code, body)
            )
    raise RuntimeError(
        "API error: {} {} → max retries reached".format(method, url)
    )


def get_server_by_name(name, api_base, token, secret):
    """名前でサーバを検索して返す。見つからなければ None。"""
    resp = sakura_api_request("GET", "{}/server".format(api_base), token, secret)
    for server in resp.get("Servers", []):
        if server["Name"] == name:
            return server
    return None


def get_server_detail(server_id, api_base, token, secret):
    resp = sakura_api_request(
        "GET", "{}/server/{}".format(api_base, server_id), token, secret
    )
    return resp["Server"]


def wait_for_instance_status(server_id, target_status, api_base, token, secret,
                              timeout=300):
    """Instance.Status が target_status になるまで待機する。"""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        server = get_server_detail(server_id, api_base, token, secret)
        if server["Instance"]["Status"] == target_status:
            return server
        time.sleep(10)
    raise TimeoutError(
        "Server {}: status '{}' not reached within {}s".format(
            server_id, target_status, timeout
        )
    )
