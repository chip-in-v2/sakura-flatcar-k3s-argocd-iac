#!/usr/bin/python
# -*- coding: utf-8 -*-
"""sakura_disk_swap – サーバのディスク順序を入れ替える Ansible モジュール。

FQCN: ops_frontier.provider.sakura_disk_swap
"""
from __future__ import absolute_import, division, print_function
__metaclass__ = type

DOCUMENTATION = r"""
module: sakura_disk_swap
short_description: さくらのクラウドのサーバのディスク順序を入れ替える
description:
  - サーバの 1番目と 2番目のディスクを入れ替える。
  - サーバは停止状態である必要がある。
options:
  server_id:
    description: サーバ ID
    required: true
    type: str
  disks:
    description: 現在のディスクリスト (sakura_server_info が返す disks フィールド)
    required: true
    type: list
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
- name: Swap disks (Ubuntu first)
  ops_frontier.provider.sakura_disk_swap:
    server_id: "{{ server_info.server.id }}"
    disks: "{{ server_info.server.disks }}"
    api_base: "{{ sakura_api_base }}"
    token: "{{ sakura_access_token }}"
    secret: "{{ sakura_access_token_secret }}"
"""

import time
from ansible.module_utils.basic import AnsibleModule
from ansible_collections.ops_frontier.provider.plugins.module_utils.api import (
    sakura_api_request,
)


def main():
    module = AnsibleModule(
        argument_spec=dict(
            server_id=dict(type="str", required=True),
            disks=dict(type="list", elements="dict", required=True),
            api_base=dict(type="str", required=True),
            token=dict(type="str", required=True, no_log=True),
            secret=dict(type="str", required=True, no_log=True),
        ),
        supports_check_mode=True,
    )

    server_id = module.params["server_id"]
    disks = module.params["disks"]
    api_base = module.params["api_base"]
    token = module.params["token"]
    secret = module.params["secret"]

    if len(disks) < 2:
        module.fail_json(
            msg="Server needs at least 2 disks, got {}".format(len(disks))
        )

    if module.check_mode:
        module.exit_json(changed=True)

    # 新しい順序: [1, 0, 2, 3, ...]
    new_order = [disks[1], disks[0]] + disks[2:]

    try:
        # 全ディスクを切断
        for disk in disks:
            sakura_api_request(
                "DELETE",
                "{}/disk/{}/to/server".format(api_base, disk["id"]),
                token, secret
            )
            time.sleep(1)

        # 新順序で再接続
        for disk in new_order:
            sakura_api_request(
                "PUT",
                "{}/disk/{}/to/server/{}".format(api_base, disk["id"], server_id),
                token, secret, {}
            )
            time.sleep(1)

        # 反映待機
        time.sleep(5)

        module.exit_json(
            changed=True,
            new_disk_order=[d["id"] for d in new_order]
        )

    except Exception as e:
        module.fail_json(msg=str(e))


if __name__ == "__main__":
    main()
