#!/usr/bin/python
# -*- coding: utf-8 -*-
"""sakura_packet_filter – パケットフィルタのルールを管理する Ansible モジュール。

FQCN: ops_frontier.provider.sakura_packet_filter
"""
from __future__ import absolute_import, division, print_function
__metaclass__ = type

DOCUMENTATION = r"""
module: sakura_packet_filter
short_description: さくらのクラウドのパケットフィルタルールを管理する (冪等)
description:
  - SSH または任意 TCP ポートの inbound/outbound 許可ルールを追加・削除する。
  - 既存の同種ルールを一旦除去してから追加するため冪等に動作する。
options:
  packet_filter_id:
    description: パケットフィルタ ID
    required: true
    type: str
  state:
    description: present でルール追加、absent でルール削除
    required: true
    type: str
    choices: [present, absent]
  rule_type:
    description: ルール種別 (ssh または tcp)
    type: str
    default: ssh
    choices: [ssh, tcp]
  port:
    description: TCP ポート番号 (rule_type=tcp の場合に必須)
    type: str
  source_network:
    description: "送信元ネットワーク (state=present の場合に必須、例: 1.2.3.4)"
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
- name: Allow SSH from current IP
  ops_frontier.provider.sakura_packet_filter:
    packet_filter_id: "123456789012"
    state: present
    rule_type: ssh
    source_network: "1.2.3.4"
    api_base: "{{ sakura_api_base }}"
    token: "{{ sakura_access_token }}"
    secret: "{{ sakura_access_token_secret }}"

- name: Remove SSH rules
  ops_frontier.provider.sakura_packet_filter:
    packet_filter_id: "123456789012"
    state: absent
    rule_type: ssh
    api_base: "{{ sakura_api_base }}"
    token: "{{ sakura_access_token }}"
    secret: "{{ sakura_access_token_secret }}"
"""

from ansible.module_utils.basic import AnsibleModule
from ansible_collections.ops_frontier.provider.plugins.module_utils.api import (
    sakura_api_request,
)


def _is_ssh_rule(expr):
    proto = expr.get("Protocol", "")
    dst = expr.get("DestinationPort", "")
    src = expr.get("SourcePort", "")
    return proto == "tcp" and (dst == "22" or src == "22")


def _is_tcp_port_rule(expr, port):
    proto = expr.get("Protocol", "")
    dst = expr.get("DestinationPort", "")
    src = expr.get("SourcePort", "")
    return proto == "tcp" and (dst == port or src == port)


def _insert_before_deny(expressions, new_rules):
    """deny-all ルールの直前に new_rules を挿入する。"""
    insert_idx = len(expressions)
    for i, e in enumerate(expressions):
        if e.get("Action") == "deny" or (
            e.get("Protocol") == "ip" and not e.get("Action")
        ):
            insert_idx = i
            break
    return expressions[:insert_idx] + new_rules + expressions[insert_idx:]


def main():
    module = AnsibleModule(
        argument_spec=dict(
            packet_filter_id=dict(type="str", required=True),
            state=dict(type="str", required=True, choices=["present", "absent"]),
            rule_type=dict(type="str", default="ssh", choices=["ssh", "tcp"]),
            port=dict(type="str"),
            source_network=dict(type="str"),
            api_base=dict(type="str", required=True),
            token=dict(type="str", required=True, no_log=True),
            secret=dict(type="str", required=True, no_log=True),
        ),
        required_if=[
            ("rule_type", "tcp", ["port"]),
            ("state", "present", ["source_network"]),
        ],
        supports_check_mode=True,
    )

    pf_id = module.params["packet_filter_id"]
    state = module.params["state"]
    rule_type = module.params["rule_type"]
    port = module.params["port"]
    source_network = module.params["source_network"]
    api_base = module.params["api_base"]
    token = module.params["token"]
    secret = module.params["secret"]

    pf_url = "{}/packetfilter/{}".format(api_base, pf_id)

    try:
        current = sakura_api_request("GET", pf_url, token, secret)
        expressions = list(current["PacketFilter"]["Expression"])

        # 既存の該当ルールを除去
        if rule_type == "ssh":
            filtered = [e for e in expressions if not _is_ssh_rule(e)]
        else:
            filtered = [e for e in expressions if not _is_tcp_port_rule(e, port)]

        changed = len(filtered) != len(expressions)

        if state == "absent":
            if not changed:
                module.exit_json(changed=False)
            if module.check_mode:
                module.exit_json(changed=True)
            current["PacketFilter"]["Expression"] = filtered
            sakura_api_request("PUT", pf_url, token, secret,
                                {"PacketFilter": current["PacketFilter"]})
            module.exit_json(changed=True)

        # state == present: ルール追加
        if rule_type == "ssh":
            new_rules = [
                {
                    "Protocol": "tcp",
                    "SourceNetwork": source_network,
                    "DestinationPort": "22",
                    "Action": "allow",
                    "Description": "SSH inbound from dev env (managed by ansible)",
                },
                {
                    "Protocol": "tcp",
                    "SourcePort": "22",
                    "Action": "allow",
                    "Description": "SSH outbound response (managed by ansible)",
                },
            ]
        else:
            new_rules = [
                {
                    "Protocol": "tcp",
                    "SourceNetwork": source_network,
                    "DestinationPort": port,
                    "Action": "allow",
                    "Description": "port {} inbound from dev env (managed by ansible)".format(port),
                },
                {
                    "Protocol": "tcp",
                    "SourcePort": port,
                    "Action": "allow",
                    "Description": "port {} outbound response (managed by ansible)".format(port),
                },
            ]

        new_expressions = _insert_before_deny(filtered, new_rules)
        # 実際に変更があるか確認 (冪等性)
        changed = new_expressions != expressions

        if module.check_mode:
            module.exit_json(changed=changed)

        current["PacketFilter"]["Expression"] = new_expressions
        sakura_api_request("PUT", pf_url, token, secret,
                            {"PacketFilter": current["PacketFilter"]})
        module.exit_json(changed=changed)

    except Exception as e:
        module.fail_json(msg=str(e))


if __name__ == "__main__":
    main()
