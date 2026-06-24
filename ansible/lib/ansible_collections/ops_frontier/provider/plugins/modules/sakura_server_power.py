#!/usr/bin/python
# -*- coding: utf-8 -*-
"""sakura_server_power – サーバの電源を操作する Ansible モジュール。

FQCN: ops_frontier.provider.sakura_server_power
"""
from __future__ import absolute_import, division, print_function
__metaclass__ = type

DOCUMENTATION = r"""
module: sakura_server_power
short_description: さくらのクラウドのサーバの電源を操作する
description:
  - サーバの電源を ON/OFF し、状態が変化するまで待機する。
options:
  server_id:
    description: サーバ ID
    required: true
    type: str
  state:
    description: 目標電源状態
    required: true
    type: str
    choices: [on, off]
  wait:
    description: 状態変化を待機するか
    type: bool
    default: true
  timeout:
    description: 待機タイムアウト秒数
    type: int
    default: 300
  api_base:
    description: API エンドポイント
    required: true
    type: str
  token:
    description: アクセストークン
    required: true
    type: str
  secret:
    description: アクセストークンシークレット
    required: true
    type: str
    no_log: true
"""

EXAMPLES = r"""
- name: Power on server
  ops_frontier.provider.sakura_server_power:
    server_id: "123456789012"
    state: on
    api_base: "{{ sakura_api_base }}"
    token: "{{ sakura_access_token }}"
    secret: "{{ sakura_access_token_secret }}"

- name: Power off server
  ops_frontier.provider.sakura_server_power:
    server_id: "123456789012"
    state: off
    api_base: "{{ sakura_api_base }}"
    token: "{{ sakura_access_token }}"
    secret: "{{ sakura_access_token_secret }}"
"""

from ansible.module_utils.basic import AnsibleModule
from ansible_collections.ops_frontier.provider.plugins.module_utils.api import (
    sakura_api_request,
    get_server_detail,
    wait_for_instance_status,
)


def main():
    module = AnsibleModule(
        argument_spec=dict(
            server_id=dict(type="str", required=True),
            state=dict(type="str", required=True, choices=["on", "off"]),
            wait=dict(type="bool", default=True),
            timeout=dict(type="int", default=300),
            api_base=dict(type="str", required=True),
            token=dict(type="str", required=True, no_log=True),
            secret=dict(type="str", required=True, no_log=True),
        ),
        supports_check_mode=True,
    )

    server_id = module.params["server_id"]
    state = module.params["state"]
    wait = module.params["wait"]
    timeout = module.params["timeout"]
    api_base = module.params["api_base"]
    token = module.params["token"]
    secret = module.params["secret"]

    target_instance_status = "up" if state == "on" else "down"

    try:
        server = get_server_detail(server_id, api_base, token, secret)
        current_status = server["Instance"]["Status"]

        if current_status == target_instance_status:
            module.exit_json(changed=False, instance_status=current_status)

        if module.check_mode:
            module.exit_json(changed=True, instance_status=target_instance_status)

        if state == "on":
            sakura_api_request(
                "PUT",
                "{}/server/{}/power".format(api_base, server_id),
                token, secret, {}
            )
        else:
            sakura_api_request(
                "DELETE",
                "{}/server/{}/power".format(api_base, server_id),
                token, secret
            )

        if wait:
            server = wait_for_instance_status(
                server_id, target_instance_status,
                api_base, token, secret, timeout=timeout
            )

        module.exit_json(changed=True, instance_status=target_instance_status)

    except Exception as e:
        module.fail_json(msg=str(e))


if __name__ == "__main__":
    main()
