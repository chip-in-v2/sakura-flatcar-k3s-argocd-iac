#!/usr/bin/python
# -*- coding: utf-8 -*-
"""sakura_server_info – サーバ情報を取得する Ansible モジュール。

FQCN: ops_frontier.provider.sakura_server_info
"""
from __future__ import absolute_import, division, print_function
__metaclass__ = type

DOCUMENTATION = r"""
module: sakura_server_info
short_description: さくらのクラウドのサーバ情報を取得する
description:
  - 名前でサーバを検索し、ID・状態・ディスク一覧を返す。
options:
  name:
    description: サーバ名
    required: true
    type: str
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
- name: Get server info
  ops_frontier.provider.sakura_server_info:
    name: chip-inx-sv1
    api_base: "https://secure.sakura.ad.jp/cloud/zone/is1c/api/cloud/1.1"
    token: "{{ sakura_access_token }}"
    secret: "{{ sakura_access_token_secret }}"
  register: server_info
"""

RETURN = r"""
server:
  description: サーバ情報
  returned: always
  type: dict
  contains:
    id:
      description: サーバ ID
      type: str
    name:
      description: サーバ名
      type: str
    instance_status:
      description: 電源状態 (up / down)
      type: str
    disks:
      description: 接続ディスクのリスト (ID と Name)
      type: list
"""

from ansible.module_utils.basic import AnsibleModule
from ansible_collections.ops_frontier.provider.plugins.module_utils.api import (
    get_server_by_name,
)


def main():
    module = AnsibleModule(
        argument_spec=dict(
            name=dict(type="str", required=True),
            api_base=dict(type="str", required=True),
            token=dict(type="str", required=True, no_log=True),
            secret=dict(type="str", required=True, no_log=True),
        ),
        supports_check_mode=True,
    )

    name = module.params["name"]
    api_base = module.params["api_base"]
    token = module.params["token"]
    secret = module.params["secret"]

    try:
        server = get_server_by_name(name, api_base, token, secret)
    except Exception as e:
        module.fail_json(msg=str(e))

    if server is None:
        module.fail_json(msg="Server '{}' not found".format(name))

    result = {
        "id": server["ID"],
        "name": server["Name"],
        "instance_status": server["Instance"]["Status"],
        "disks": [
            {"id": d["ID"], "name": d.get("Name", "")}
            for d in server.get("Disks", [])
        ],
    }
    module.exit_json(changed=False, server=result)


if __name__ == "__main__":
    main()
