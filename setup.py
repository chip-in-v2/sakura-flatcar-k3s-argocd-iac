#!/usr/bin/env python3
"""
SETUP.md に従い、Flatcar Container Linux + k3s クラスタを構築するスクリプト。

使用方法:
  ./setup.py build-infra      ネットワークとサーバを terraform で構築します
  ./setup.py boot             Flatcar Linux をインストールして起動します
  ./setup.py install-charts   YAML をレンダリングし ArgoCD ブートストラップを適用します
  ./setup.py deny-ssh         パケットフィルタで ssh のアクセスを禁止します
  ./setup.py destroy          ネットワークとサーバを terraform で削除します
"""

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

# ---------------------------------------------------------------------------
# 定数
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TERRAFORM_DIR = os.path.join(SCRIPT_DIR, "terraform")
BUTANE_TPL = os.path.join(SCRIPT_DIR, "butane", "node.yaml.tpl")
SSH_KEY_PATH = os.path.join(SCRIPT_DIR, ".ssh", "id_ed25519")
RENDERED_DIR = os.path.join(SCRIPT_DIR, "rendered")
ARGOCD_MANIFESTS_DIR = os.path.join(SCRIPT_DIR, "argocd", "manifests")
ARGOCD_APPS_DIR = os.path.join(SCRIPT_DIR, "argocd", "apps")
ARGOCD_BOOTSTRAP_YAML = os.path.join(SCRIPT_DIR, "argocd", "bootstrap.yaml")

_SSH_CONFIG_BEGIN = "# BEGIN sakura-flatcar-k3s managed section"
_SSH_CONFIG_END   = "# END sakura-flatcar-k3s managed section"

UBUNTU_SSH_USER  = "ubuntu"
FLATCAR_SSH_USER = "core"

SSH_OPTS = [
    "-i", SSH_KEY_PATH,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "ConnectTimeout=10",
    "-o", "BatchMode=yes",
]

BUTANE_VERSION = "v0.21.0"
FLATCAR_INSTALL_URL = (
    "https://raw.githubusercontent.com/flatcar/init/flatcar-master/bin/flatcar-install"
)

# ---------------------------------------------------------------------------
# 環境変数 / 認証情報
# ---------------------------------------------------------------------------


def get_sakura_env() -> tuple[str, str, str]:
    """さくらのクラウド認証情報と区域を環境変数から取得する。"""
    token = (
        os.environ.get("SAKURA_ACCESS_TOKEN")
        or os.environ.get("TF_VAR_sakura_access_token", "")
    )
    secret = (
        os.environ.get("SAKURA_ACCESS_TOKEN_SECRET")
        or os.environ.get("TF_VAR_sakura_access_token_secret", "")
    )
    region = (
        os.environ.get("SAKURA_REGION")
        or os.environ.get("TF_VAR_sakura_region", "is1c")
    )
    if not token or not secret:
        raise EnvironmentError(
            "SAKURA_ACCESS_TOKEN / SAKURA_ACCESS_TOKEN_SECRET が設定されていません。"
        )
    return token, secret, region


def get_api_base(region: str) -> str:
    return f"https://secure.sakura.ad.jp/cloud/zone/{region}/api/cloud/1.1"


# ---------------------------------------------------------------------------
# さくらのクラウド API
# ---------------------------------------------------------------------------


def _sakura_api_request(
    method: str,
    url: str,
    token: str,
    secret: str,
    payload: dict | None = None,
    retries: int = 10,
    retry_interval: int = 10,
) -> dict:
    """さくらのクラウド API へリクエストを送信し、レスポンスを返す。

    HTTP 423 (Locked) の場合は retries 回までリトライする。
    """
    credentials = base64.b64encode(f"{token}:{secret}".encode()).decode()
    headers = {"Authorization": f"Basic {credentials}"}
    data: bytes | None = None
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"

    for attempt in range(retries + 1):
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = resp.read()
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as e:
            if e.code == 423 and attempt < retries:
                print(f"  API 423 Locked: {retry_interval} 秒後にリトライします... ({attempt + 1}/{retries})")
                time.sleep(retry_interval)
                continue
            body = e.read().decode(errors="replace")
            raise RuntimeError(
                f"API エラー: {method} {url} → HTTP {e.code}\n{body}"
            ) from e
    raise RuntimeError(f"API エラー: {method} {url} → リトライ上限に達しました")


def _get_server_by_name(
    name: str, api_base: str, token: str, secret: str
) -> dict:
    """名前でサーバを検索して返す。"""
    resp = _sakura_api_request("GET", f"{api_base}/server", token, secret)
    for server in resp.get("Servers", []):
        if server["Name"] == name:
            return server
    raise ValueError(f"サーバ '{name}' が見つかりません")


def _get_server_detail(
    server_id: str, api_base: str, token: str, secret: str
) -> dict:
    resp = _sakura_api_request("GET", f"{api_base}/server/{server_id}", token, secret)
    return resp["Server"]


def _power_on_server(
    server_id: str, api_base: str, token: str, secret: str
) -> None:
    _sakura_api_request("PUT", f"{api_base}/server/{server_id}/power", token, secret, {})


def _power_off_server(
    server_id: str, api_base: str, token: str, secret: str
) -> None:
    _sakura_api_request("DELETE", f"{api_base}/server/{server_id}/power", token, secret)


def _wait_for_server_instance_status(
    server_id: str,
    target_status: str,
    api_base: str,
    token: str,
    secret: str,
    timeout: int = 300,
) -> None:
    """サーバの Instance.Status が target_status になるまで待機する。"""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        server = _get_server_detail(server_id, api_base, token, secret)
        status = server["Instance"]["Status"]
        if status == target_status:
            return
        print(f"    サーバ {server['Name']}: ステータス={status}, 待機中...")
        time.sleep(10)
    raise TimeoutError(
        f"サーバ {server_id}: ステータス '{target_status}' への移行が"
        f"タイムアウトしました ({timeout}秒)"
    )


def _swap_server_disk_order(
    server: dict,
    api_base: str,
    token: str,
    secret: str,
) -> None:
    """サーバの 1番目と 2番目のディスクを入れ替える。

    サーバは停止状態である必要があります。
    先頭のディスクが /dev/vda (ブートディスク) になります。
    """
    disks = server.get("Disks", [])
    if len(disks) < 2:
        raise ValueError(
            f"サーバ '{server['Name']}': ディスクが 2 つ未満です ({len(disks)} 個)"
        )

    server_id = server["ID"]
    # 新しい順序: [disks[1], disks[0], disks[2:]]
    new_order = [disks[1], disks[0]] + disks[2:]
    new_ids = [d["ID"] for d in new_order]
    print(f"    ディスク順序を変更: {[d['ID'] for d in disks]} → {new_ids}")

    # 全ディスクを切断
    for disk in disks:
        _sakura_api_request(
            "DELETE",
            f"{api_base}/disk/{disk['ID']}/to/server",
            token,
            secret,
        )
        time.sleep(1)

    # 指定した順序で再接続
    for disk in new_order:
        _sakura_api_request(
            "PUT",
            f"{api_base}/disk/{disk['ID']}/to/server/{server_id}",
            token,
            secret,
            {},
        )
        time.sleep(1)

    # ディスク操作の反映を待機
    time.sleep(5)


# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------


def _terraform_apply() -> None:
    print("==> terraform apply を実行中...")
    subprocess.run(["terraform", "apply"], cwd=TERRAFORM_DIR, check=True)


def _terraform_destroy() -> None:
    print("==> terraform destroy を実行中...")
    subprocess.run(["terraform", "destroy"], cwd=TERRAFORM_DIR, check=True)


def _get_terraform_output() -> dict:
    """terraform output -json を実行して辞書で返す。"""
    result = subprocess.run(
        ["terraform", "output", "-json"],
        cwd=TERRAFORM_DIR,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


# ---------------------------------------------------------------------------
# グローバル IP
# ---------------------------------------------------------------------------


def _get_my_global_ip() -> str:
    """実行環境のグローバル IP を取得する。"""
    with urllib.request.urlopen("https://checkip.amazonaws.com", timeout=10) as resp:
        return resp.read().decode().strip()


# ---------------------------------------------------------------------------
# パケットフィルタ
# ---------------------------------------------------------------------------


def _is_ssh_rule(expr: dict) -> bool:
    proto    = expr.get("Protocol", "")
    dst_port = expr.get("DestinationPort", "")
    src_port = expr.get("SourcePort", "")
    return proto == "tcp" and (dst_port == "22" or src_port == "22")


def _is_tcp_port_rule(expr: dict, port: str) -> bool:
    proto    = expr.get("Protocol", "")
    dst_port = expr.get("DestinationPort", "")
    src_port = expr.get("SourcePort", "")
    return proto == "tcp" and (dst_port == port or src_port == port)


def _add_ssh_packet_filter_rules(
    packet_filter_id: str,
    my_ip: str,
    api_base: str,
    token: str,
    secret: str,
) -> None:
    """パケットフィルタに SSH 許可ルールを追加する (冪等)。"""
    pf_url = f"{api_base}/packetfilter/{packet_filter_id}"

    current = _sakura_api_request("GET", pf_url, token, secret)
    expressions: list[dict] = current["PacketFilter"]["Expression"]

    # 既存の SSH ルールを除去
    expressions = [e for e in expressions if not _is_ssh_rule(e)]

    inbound_rule = {
        "Protocol": "tcp",
        "SourceNetwork": my_ip,
        "DestinationPort": "22",
        "Action": "allow",
        "Description": "SSH inbound from dev env (managed by setup.py)",
    }
    outbound_rule = {
        "Protocol": "tcp",
        "SourcePort": "22",
        "Action": "allow",
        "Description": "SSH outbound response (managed by setup.py)",
    }

    # deny-all ルールの直前に挿入
    insert_idx = len(expressions)
    for i, e in enumerate(expressions):
        if e.get("Action") == "deny" or (
            e.get("Protocol") == "ip" and not e.get("Action")
        ):
            insert_idx = i
            break

    expressions = expressions[:insert_idx] + [inbound_rule, outbound_rule] + expressions[insert_idx:]

    current["PacketFilter"]["Expression"] = expressions
    payload = {"PacketFilter": current["PacketFilter"]}
    _sakura_api_request("PUT", pf_url, token, secret, payload)
    print(f"==> パケットフィルタに SSH 許可ルールを追加しました (送信元 IP: {my_ip})")


def _remove_ssh_packet_filter_rules(
    packet_filter_id: str,
    api_base: str,
    token: str,
    secret: str,
) -> None:
    """パケットフィルタから SSH ルールを削除する。"""
    pf_url = f"{api_base}/packetfilter/{packet_filter_id}"

    current = _sakura_api_request("GET", pf_url, token, secret)
    expressions: list[dict] = current["PacketFilter"]["Expression"]

    filtered = [e for e in expressions if not _is_ssh_rule(e)]
    if len(filtered) == len(expressions):
        print("==> 削除対象の SSH ルールが見つかりませんでした")
        return

    current["PacketFilter"]["Expression"] = filtered
    payload = {"PacketFilter": current["PacketFilter"]}
    _sakura_api_request("PUT", pf_url, token, secret, payload)
    print(f"==> パケットフィルタから SSH ルールを削除しました")


def _add_tcp_packet_filter_rule(
    packet_filter_id: str,
    port: str,
    my_ip: str,
    api_base: str,
    token: str,
    secret: str,
    label: str = "",
) -> None:
    """パケットフィルタに TCP ポートの許可ルールを追加する (冪等)。"""
    pf_url = f"{api_base}/packetfilter/{packet_filter_id}"
    desc = label or f"port {port}"

    current = _sakura_api_request("GET", pf_url, token, secret)
    expressions: list[dict] = current["PacketFilter"]["Expression"]

    # 既存の同ポートルールを除去
    expressions = [e for e in expressions if not _is_tcp_port_rule(e, port)]

    inbound_rule = {
        "Protocol": "tcp",
        "SourceNetwork": my_ip,
        "DestinationPort": port,
        "Action": "allow",
        "Description": f"{desc} inbound from dev env (managed by setup.py)",
    }
    outbound_rule = {
        "Protocol": "tcp",
        "SourcePort": port,
        "Action": "allow",
        "Description": f"{desc} outbound response (managed by setup.py)",
    }

    insert_idx = len(expressions)
    for i, e in enumerate(expressions):
        if e.get("Action") == "deny" or (
            e.get("Protocol") == "ip" and not e.get("Action")
        ):
            insert_idx = i
            break

    expressions = expressions[:insert_idx] + [inbound_rule, outbound_rule] + expressions[insert_idx:]
    current["PacketFilter"]["Expression"] = expressions
    payload = {"PacketFilter": current["PacketFilter"]}
    _sakura_api_request("PUT", pf_url, token, secret, payload)
    print(f"==> パケットフィルタに {desc} 許可ルールを追加しました (送信元 IP: {my_ip})")


def _remove_tcp_packet_filter_rule(
    packet_filter_id: str,
    port: str,
    api_base: str,
    token: str,
    secret: str,
    label: str = "",
) -> None:
    """パケットフィルタから TCP ポートのルールを削除する。"""
    pf_url = f"{api_base}/packetfilter/{packet_filter_id}"
    desc = label or f"port {port}"

    current = _sakura_api_request("GET", pf_url, token, secret)
    expressions: list[dict] = current["PacketFilter"]["Expression"]

    filtered = [e for e in expressions if not _is_tcp_port_rule(e, port)]
    if len(filtered) == len(expressions):
        print(f"==> 削除対象の {desc} ルールが見つかりませんでした")
        return

    current["PacketFilter"]["Expression"] = filtered
    payload = {"PacketFilter": current["PacketFilter"]}
    _sakura_api_request("PUT", pf_url, token, secret, payload)
    print(f"==> パケットフィルタから {desc} ルールを削除しました")


# ---------------------------------------------------------------------------
# SSH ヘルパー
# ---------------------------------------------------------------------------


def _wait_for_ssh(ip: str, user: str, timeout: int = 300) -> None:
    """SSH 接続が確立できるまで最大 timeout 秒待機する。"""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(
            ["ssh", *SSH_OPTS, f"{user}@{ip}", "true"],
            capture_output=True,
        )
        if result.returncode == 0:
            return
        time.sleep(5)
    raise TimeoutError(f"{ip}: SSH 接続がタイムアウトしました ({timeout} 秒)")


def _wait_for_any_ssh(ip: str, timeout: int = 600) -> str:
    """Ubuntu または Flatcar への SSH が確立できるまで待機し、OS 名を返す。"""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        os_name = _detect_running_os(ip)
        if os_name:
            return os_name
        time.sleep(10)
    raise TimeoutError(f"{ip}: SSH 接続がタイムアウトしました ({timeout} 秒)")


def _detect_running_os(ip: str) -> str | None:
    """サーバで動作している OS を検出する。

    Returns:
        "ubuntu", "flatcar", または None (接続不可 / OS 不明)
    """
    for user in [UBUNTU_SSH_USER, FLATCAR_SSH_USER]:
        try:
            r = subprocess.run(
                ["ssh", *SSH_OPTS, f"{user}@{ip}", "cat /etc/os-release"],
                capture_output=True,
                text=True,
                timeout=20,
            )
        except subprocess.TimeoutExpired:
            continue
        if r.returncode == 0:
            if "ID=ubuntu" in r.stdout:
                return "ubuntu"
            if "ID=flatcar" in r.stdout:
                return "flatcar"
    return None


# ---------------------------------------------------------------------------
# ~/.ssh/config 管理
# ---------------------------------------------------------------------------


def _setup_ssh_config(node_public_ips: dict[str, str]) -> None:
    """~/.ssh/config にサーバの SSH 接続設定を追加・更新する。"""
    ssh_config_path = os.path.expanduser("~/.ssh/config")
    os.makedirs(os.path.expanduser("~/.ssh"), mode=0o700, exist_ok=True)

    existing = ""
    if os.path.exists(ssh_config_path):
        with open(ssh_config_path) as f:
            existing = f.read()

    start_idx = existing.find(_SSH_CONFIG_BEGIN)
    end_idx   = existing.find(_SSH_CONFIG_END)
    if start_idx != -1 and end_idx != -1:
        before = existing[:start_idx]
        after  = existing[end_idx + len(_SSH_CONFIG_END):]
        if after.startswith("\n"):
            after = after[1:]
    else:
        before = existing
        after  = ""

    lines = [_SSH_CONFIG_BEGIN]
    for node_name in sorted(node_public_ips):
        ip = node_public_ips[node_name]
        lines.append(
            f"Host {node_name}\n"
            f"    HostName {ip}\n"
            f"    User {FLATCAR_SSH_USER}\n"
            f"    IdentityFile {SSH_KEY_PATH}\n"
            f"    StrictHostKeyChecking no\n"
            f"    UserKnownHostsFile /dev/null"
        )
    lines.append(_SSH_CONFIG_END)

    managed_block = "\n\n".join(lines) + "\n"
    new_content = before.rstrip("\n") + "\n\n" + managed_block + after

    with open(ssh_config_path, "w") as f:
        f.write(new_content)
    os.chmod(ssh_config_path, 0o600)
    print(f"==> ~/.ssh/config を更新しました")


# ---------------------------------------------------------------------------
# ツールのインストール確認
# ---------------------------------------------------------------------------


def _ensure_butane() -> None:
    """butane が未インストールの場合はダウンロードしてインストールする。"""
    if subprocess.run(["which", "butane"], capture_output=True).returncode == 0:
        return

    print("==> butane をインストール中...")
    arch = subprocess.check_output(["uname", "-m"], text=True).strip()
    url = (
        f"https://github.com/coreos/butane/releases/download/{BUTANE_VERSION}/"
        f"butane-{arch}-unknown-linux-gnu"
    )
    subprocess.run(
        ["sudo", "bash", "-c", f"curl -fsSL '{url}' -o /usr/local/bin/butane && chmod +x /usr/local/bin/butane"],
        check=True,
    )
    print("==> butane インストール完了")


def _install_flatcar_install_on_server(ip: str) -> None:
    """Ubuntu サーバに flatcar-install と依存パッケージをインストールする。"""
    print(f"  {ip}: 依存パッケージ・flatcar-install をインストール中...")
    cmd = " && ".join([
        "echo nameserver 8.8.8.8 | sudo tee /etc/resolv.conf > /dev/null",
        "sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq",
        "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y bzip2 wget curl",
        f"curl -fsSLO '{FLATCAR_INSTALL_URL}'",
        "sudo install -o root -g root -m 0755 flatcar-install /usr/local/bin/",
        "rm -f flatcar-install",
    ])
    r = subprocess.run(
        ["ssh", "-T", *SSH_OPTS,
         "-o", "ServerAliveInterval=30",
         f"{UBUNTU_SSH_USER}@{ip}", cmd],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        print(f"  警告: インストールに失敗しました\n  {r.stderr.strip()}")
    else:
        print(f"  {ip}: インストール完了")


# ---------------------------------------------------------------------------
# Butane テンプレートレンダリング
# ---------------------------------------------------------------------------


def _render_terraform_template(template: str, vars: dict) -> str:  # noqa: A002
    """Terraform templatefile の簡易レンダラー。

    サポート構文:
      - ${var_name}
      - %{ if var_name ~}...%{ else ~}...%{ endif ~}
      - %{ if var_name ~}...%{ endif ~}
    """
    result = template

    # if / else / endif (else あり)
    result = re.sub(
        r'%\{[ \t]*if[ \t]+(\w+)[ \t]*~?[ \t]*\}[ \t]*\n?'
        r'(.*?)'
        r'%\{[ \t]*else[ \t]*~?[ \t]*\}[ \t]*\n?'
        r'(.*?)'
        r'%\{[ \t]*endif[ \t]*~?[ \t]*\}[ \t]*\n?',
        lambda m: (m.group(2) if vars.get(m.group(1)) else m.group(3)),
        result,
        flags=re.DOTALL,
    )

    # if / endif (else なし)
    result = re.sub(
        r'%\{[ \t]*if[ \t]+(\w+)[ \t]*~?[ \t]*\}[ \t]*\n?'
        r'(.*?)'
        r'%\{[ \t]*endif[ \t]*~?[ \t]*\}[ \t]*\n?',
        lambda m: (m.group(2) if vars.get(m.group(1)) else ""),
        result,
        flags=re.DOTALL,
    )

    # ${var_name}
    def _replace_var(m: re.Match) -> str:
        name = m.group(1)
        if name not in vars:
            raise KeyError(f"テンプレート変数 '{name}' が見つかりません")
        return str(vars[name])

    result = re.sub(r'\$\{(\w+)\}', _replace_var, result)
    return result


def _render_ignition(node_name: str, node_index: int, outputs: dict) -> str:
    """butane テンプレートから Ignition JSON を生成して返す。"""
    _ensure_butane()

    with open(BUTANE_TPL) as f:
        template = f.read()

    node_names   = sorted(outputs["node_public_ips"]["value"].keys())
    lb_ip        = outputs["node_public_ips"]["value"][node_name]
    internal_ip  = outputs["node_private_ips"]["value"][node_name]
    init_ip      = outputs["node_private_ips"]["value"][node_names[0]]
    domain       = outputs["domain"]["value"]

    tpl_vars = {
        "hostname":       node_name,
        "cluster_token":  outputs["k3s_cluster_token"]["value"],
        "server_is_init": node_index == 0,
        "init_ip":        init_ip,
        "internal_ip":    internal_ip,
        "lb_ip":          lb_ip,
        "lb_netmask":     str(outputs["lb_netmask"]["value"]),
        "lb_gateway":     outputs["lb_gateway"]["value"],
        "lb_vip_ip":      outputs["lb_global_ip"]["value"],
        "ssh_public_key": outputs["ssh_public_key_openssh"]["value"].strip(),
        "domain":         domain,
    }

    rendered_yaml = _render_terraform_template(template, tpl_vars)

    result = subprocess.run(
        ["butane", "--pretty", "--strict"],
        input=rendered_yaml,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


# ---------------------------------------------------------------------------
# Flatcar インストール (Ubuntu から /dev/vdb へ)
# ---------------------------------------------------------------------------


def _install_flatcar_to_target_disk(ip: str, ignition_json: str) -> None:
    """Ubuntu 上で flatcar-install を実行して /dev/vdb に Flatcar をインストールする。"""
    print(f"  {ip}: Ignition ファイルを転送中...")

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".ign", prefix="node-", delete=False
    ) as f:
        f.write(ignition_json)
        tmp_ign = f.name

    try:
        subprocess.run(
            ["scp", *SSH_OPTS, tmp_ign, f"{UBUNTU_SSH_USER}@{ip}:/tmp/node.ign"],
            check=True,
        )

        print(f"  {ip}: flatcar-install を実行中 (時間がかかります)...")

        # udevadm settle のタイムアウト問題に対処するパッチを適用してからインストール
        install_cmd = (
            "exec </dev/null"
            " && echo nameserver 8.8.8.8 | sudo tee /etc/resolv.conf > /dev/null"
            " && sudo sed -i"
            "   's/udevadm settle/udevadm settle --timeout=30/g'"
            "   /usr/local/bin/flatcar-install"
            " && sudo flatcar-install -d /dev/vdb -i /tmp/node.ign"
        )

        subprocess.run(
            [
                "ssh", "-T", *SSH_OPTS,
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=10",
                f"{UBUNTU_SSH_USER}@{ip}",
                install_cmd,
            ],
            stdin=subprocess.DEVNULL,
            check=True,
        )
        print(f"  {ip}: Flatcar インストール完了")
    finally:
        os.unlink(tmp_ign)


# ---------------------------------------------------------------------------
# サブコマンド: build-infra
# ---------------------------------------------------------------------------


def cmd_build_infra() -> None:
    print("=" * 60)
    print("build-infra: インフラを構築します")
    print("=" * 60)

    # 1. terraform apply
    _terraform_apply()

    # 2. Terraform outputs を取得
    outputs = _get_terraform_output()
    node_public_ips: dict[str, str] = outputs["node_public_ips"]["value"]
    packet_filter_id: str           = outputs["packet_filter_id"]["value"]

    token, secret, region = get_sakura_env()
    api_base = get_api_base(region)

    # 3. 開発環境のグローバル IP を取得してパケットフィルタに SSH ルールを追加
    print("==> 開発環境のグローバル IP を取得中...")
    my_ip = _get_my_global_ip()
    print(f"==> グローバル IP: {my_ip}")
    _add_ssh_packet_filter_rules(packet_filter_id, my_ip, api_base, token, secret)

    # 4. ~/.ssh/config を設定
    _setup_ssh_config(node_public_ips)

    # 5. SSH 接続を待機して flatcar-install をインストール
    print("==> SSH 接続を待機中...")
    for node_name in sorted(node_public_ips):
        ip = node_public_ips[node_name]
        print(f"  {node_name} ({ip}): SSH 待機中...")
        _wait_for_ssh(ip, UBUNTU_SSH_USER)
        print(f"  {node_name}: SSH 接続確立")
        _install_flatcar_install_on_server(ip)

    print()
    print("=" * 60)
    print("build-infra 完了")
    print("=" * 60)


# ---------------------------------------------------------------------------
# サブコマンド: boot
# ---------------------------------------------------------------------------


def cmd_boot() -> None:
    print("=" * 60)
    print("boot: Flatcar Linux をインストールして起動します")
    print("=" * 60)

    outputs = _get_terraform_output()
    node_public_ips: dict[str, str] = outputs["node_public_ips"]["value"]
    node_names = sorted(node_public_ips.keys())
    packet_filter_id: str = outputs["packet_filter_id"]["value"]

    token, secret, region = get_sakura_env()
    api_base = get_api_base(region)

    # SSH パケットフィルタを現在のグローバル IP で更新 (Codespaces 再起動で IP が変わるため)
    print("==> 開発環境のグローバル IP を取得中...")
    my_ip = _get_my_global_ip()
    print(f"==> グローバル IP: {my_ip}")
    _add_ssh_packet_filter_rules(packet_filter_id, my_ip, api_base, token, secret)

    for i, node_name in enumerate(node_names):
        ip = node_public_ips[node_name]
        print()
        print(f"--- {node_name} ({ip}) ---")

        server    = _get_server_by_name(node_name, api_base, token, secret)
        server_id = server["ID"]

        # サーバが停止中の場合は起動する
        instance_status = server["Instance"]["Status"]
        if instance_status == "down":
            print(f"  サーバが停止中。起動します...")
            _power_on_server(server_id, api_base, token, secret)
            _wait_for_server_instance_status(server_id, "up", api_base, token, secret)

        # 1. 現在起動しているOSを確認
        print(f"  起動中の OS を検出中...")
        current_os = _wait_for_any_ssh(ip)
        print(f"  現在の OS: {current_os}")

        if current_os == "flatcar":
            # Flatcar が起動中 → Ubuntu から起動し直す
            print(f"  Flatcar が起動中。Ubuntu で再起動します...")

            _power_off_server(server_id, api_base, token, secret)
            _wait_for_server_instance_status(server_id, "down", api_base, token, secret)
            print(f"  シャットダウン完了")

            # ディスク情報を再取得してブートストラップディスクが先頭になるよう入れ替え
            server = _get_server_by_name(node_name, api_base, token, secret)
            _swap_server_disk_order(server, api_base, token, secret)
            print(f"  ディスク順序を入れ替えました (Ubuntu が先頭)")

            _power_on_server(server_id, api_base, token, secret)
            _wait_for_server_instance_status(server_id, "up", api_base, token, secret)
            print(f"  サーバ起動中... SSH を待機します")
            _wait_for_ssh(ip, UBUNTU_SSH_USER)
            print(f"  Ubuntu 起動確認")

        elif current_os != "ubuntu":
            print(f"  エラー: Ubuntu への接続に失敗しました。このサーバをスキップします。")
            continue

        # 2. Ignition ファイルを生成
        print(f"  Ignition ファイルを生成中...")
        ignition_json = _render_ignition(node_name, i, outputs)
        print(f"  Ignition ファイル生成完了")

        # 3. flatcar-install を実行して /dev/vdb にインストール
        _install_flatcar_to_target_disk(ip, ignition_json)

        # 4. シャットダウン
        print(f"  シャットダウン中...")
        _power_off_server(server_id, api_base, token, secret)
        _wait_for_server_instance_status(server_id, "down", api_base, token, secret)
        print(f"  シャットダウン完了")

        # 5. ディスク順序を入れ替え (ターゲットディスク = Flatcar を先頭に)
        server = _get_server_by_name(node_name, api_base, token, secret)
        _swap_server_disk_order(server, api_base, token, secret)
        print(f"  ディスク順序を入れ替えました (Flatcar が先頭)")

        # 6. サーバを起動
        _power_on_server(server_id, api_base, token, secret)
        _wait_for_server_instance_status(server_id, "up", api_base, token, secret)
        print(f"  サーバ起動中...")

        # 7. Flatcar の起動を確認
        print(f"  Flatcar の起動を確認中...")
        _wait_for_ssh(ip, FLATCAR_SSH_USER, timeout=600)
        print(f"  {node_name}: Flatcar Container Linux 起動確認")

    print()
    print("=" * 60)
    print("boot 完了")
    print("=" * 60)


# ---------------------------------------------------------------------------
# テンプレート変数 (install-charts)
# ---------------------------------------------------------------------------


def _get_chart_vars() -> dict:
    """チャートテンプレートのレンダリングに必要な変数を環境変数から取得する。"""

    def _require(name: str) -> str:
        v = os.environ.get(name) or os.environ.get(f"TF_VAR_{name.lower()}", "")
        if not v:
            raise EnvironmentError(f"環境変数 {name} が設定されていません。")
        return v

    def _optional(name: str, default: str) -> str:
        return os.environ.get(name) or os.environ.get(f"TF_VAR_{name.lower()}", default)

    return {
        "domain":                   _require("DOMAIN"),
        "do_pat":                   _require("DO_PAT"),
        "le_environment":           _optional("LE_ENVIRONMENT", "production"),
        "gh_organization":          _optional("GH_ORGANIZATION", "chip-in-v2"),
        "gh_client_id_argocd":      _require("GH_CLIENT_ID_ARGOCD"),
        "gh_client_secret_argocd":  _require("GH_CLIENT_SECRET_ARGOCD"),
        "gh_client_id_grafana":     _require("GH_CLIENT_ID_GRAFANA"),
        "gh_client_secret_grafana": _require("GH_CLIENT_SECRET_GRAFANA"),
    }


def _render_chart_templates(vars: dict) -> None:  # noqa: A002
    """マニフェストテンプレートを rendered/ にレンダリングする。"""
    os.makedirs(RENDERED_DIR, mode=0o700, exist_ok=True)

    templates = [
        (os.path.join(ARGOCD_MANIFESTS_DIR, "argocd-config.yaml.tpl"),      "argocd-config.yaml",      0o600),
        (os.path.join(ARGOCD_MANIFESTS_DIR, "argocd-ingress.yaml.tpl"),     "argocd-ingress.yaml",     0o600),
        (os.path.join(ARGOCD_MANIFESTS_DIR, "cert-manager-issuers.yaml.tpl"), "cert-manager-issuers.yaml", 0o600),
        (os.path.join(ARGOCD_MANIFESTS_DIR, "grafana-oauth-secret.yaml.tpl"), "grafana-oauth-secret.yaml", 0o600),
        (os.path.join(ARGOCD_APPS_DIR,      "infra-apps.yaml.tpl"),           "infra-apps.yaml",           0o640),
    ]

    for tpl_path, out_name, mode in templates:
        with open(tpl_path) as f:
            template = f.read()
        rendered = _render_terraform_template(template, vars)
        out_path = os.path.join(RENDERED_DIR, out_name)
        with open(out_path, "w") as f:
            f.write(rendered)
        os.chmod(out_path, mode)
        print(f"  レンダリング完了: {out_name}")

    # bootstrap.yaml は変数置換なしでコピー
    out_path = os.path.join(RENDERED_DIR, "bootstrap.yaml")
    shutil.copy2(ARGOCD_BOOTSTRAP_YAML, out_path)
    os.chmod(out_path, 0o640)
    print(f"  コピー完了: bootstrap.yaml")


def _kubectl_apply_remote(ip: str, manifest_path: str, retries: int = 5, retry_interval: int = 15) -> None:
    """SSH 経由でリモートサーバに kubectl apply を実行する。

    Webhook 未準備などの一時的なエラーに対し retries 回までリトライする。
    """
    with open(manifest_path, "rb") as f:
        content = f.read()
    name = os.path.basename(manifest_path)
    for attempt in range(retries + 1):
        result = subprocess.run(
            ["ssh", *SSH_OPTS, f"{FLATCAR_SSH_USER}@{ip}",
             "sudo kubectl apply -f -"],
            input=content,
        )
        if result.returncode == 0:
            print(f"  適用完了: {name}")
            return
        if attempt < retries:
            print(f"  kubectl apply 失敗 ({name}): {retry_interval} 秒後にリトライします... ({attempt + 1}/{retries})")
            time.sleep(retry_interval)
        else:
            raise subprocess.CalledProcessError(result.returncode, result.args)


def _kubectl_rollout_restart_remote(ip: str, resource: str, namespace: str) -> None:
    """SSH 経由でリモートサーバの指定リソースを rollout restart し、Ready を待機する。"""
    subprocess.run(
        ["ssh", *SSH_OPTS, f"{FLATCAR_SSH_USER}@{ip}",
         f"sudo kubectl rollout restart {resource} -n {namespace}"
         f" && sudo kubectl rollout status {resource} -n {namespace} --timeout=120s"],
        check=True,
    )
    print(f"  rollout restart 完了: {resource} ({namespace})")


def _wait_for_cert_manager_remote(ip: str, timeout: int = 600) -> None:
    """SSH 経由でリモートサーバの cert-manager が Ready になるまで待機する。"""
    script = r"""#!/bin/bash
set -e
TIMEOUT=$1
DEADLINE=$(( $(date +%s) + TIMEOUT ))

echo "  cert-manager namespace の作成を待機中..."
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    sudo kubectl get namespace cert-manager 2>/dev/null && break
    sleep 10
done
[ "$(date +%s)" -lt "$DEADLINE" ] || { echo "タイムアウト: cert-manager namespace" >&2; exit 1; }

echo "  cert-manager Deployment の作成を待機中..."
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    sudo kubectl get deployment cert-manager -n cert-manager 2>/dev/null && break
    sleep 10
done
[ "$(date +%s)" -lt "$DEADLINE" ] || { echo "タイムアウト: cert-manager Deployment" >&2; exit 1; }

echo "  cert-manager Deployment の Ready を待機中..."
REMAINING=$(( DEADLINE - $(date +%s) ))
sudo kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout="${REMAINING}s"

echo "  cert-manager CRD の登録を待機中..."
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    sudo kubectl get crd clusterissuers.cert-manager.io 2>/dev/null && break
    sleep 10
done
[ "$(date +%s)" -lt "$DEADLINE" ] || { echo "タイムアウト: cert-manager CRD" >&2; exit 1; }

echo "  cert-manager-webhook Deployment の Ready を待機中..."
REMAINING=$(( DEADLINE - $(date +%s) ))
sudo kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout="${REMAINING}s"

echo "  cert-manager-webhook エンドポイントの Ready を待機中..."
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    IP=$(sudo kubectl get endpoints cert-manager-webhook -n cert-manager \
        -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
    [ -n "$IP" ] && break
    sleep 5
done
[ "$(date +%s)" -lt "$DEADLINE" ] || { echo "タイムアウト: cert-manager-webhook エンドポイント" >&2; exit 1; }

echo "  cert-manager Ready"
"""
    subprocess.run(
        ["ssh", *SSH_OPTS, f"{FLATCAR_SSH_USER}@{ip}", f"bash -s -- {timeout}"],
        input=script.encode(),
        check=True,
    )


def _wait_for_traefik_remote(ip: str, timeout: int = 600) -> None:
    """SSH 経由でリモートサーバの Traefik CRD が Ready になるまで待機する。"""
    script = r"""#!/bin/bash
set -e
TIMEOUT=$1
DEADLINE=$(( $(date +%s) + TIMEOUT ))

echo "  Traefik CRD の登録を待機中..."
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    sudo kubectl get crd tlsstores.traefik.io 2>/dev/null && break
    sleep 10
done
[ "$(date +%s)" -lt "$DEADLINE" ] || { echo "タイムアウト: Traefik CRD" >&2; exit 1; }

echo "  Traefik Deployment の Ready を待機中..."
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    sudo kubectl get deployment traefik -n traefik 2>/dev/null && break
    sleep 10
done
[ "$(date +%s)" -lt "$DEADLINE" ] || { echo "タイムアウト: Traefik Deployment" >&2; exit 1; }

REMAINING=$(( DEADLINE - $(date +%s) ))
sudo kubectl wait --for=condition=available deployment/traefik -n traefik --timeout="${REMAINING}s"

echo "  Traefik Ready"
"""
    subprocess.run(
        ["ssh", *SSH_OPTS, f"{FLATCAR_SSH_USER}@{ip}", f"bash -s -- {timeout}"],
        input=script.encode(),
        check=True,
    )


# ---------------------------------------------------------------------------
# サブコマンド: install-charts
# ---------------------------------------------------------------------------


def cmd_install_charts() -> None:
    print("=" * 60)
    print("install-charts: YAML レンダリングと ArgoCD ブートストラップを行います")
    print("=" * 60)

    # 1. Terraform outputs からサーバ IP を取得
    outputs = _get_terraform_output()
    node_public_ips: dict[str, str] = outputs["node_public_ips"]["value"]
    sv1_name = sorted(node_public_ips.keys())[0]
    sv1_ip   = node_public_ips[sv1_name]
    packet_filter_id: str = outputs["packet_filter_id"]["value"]

    # 2. テンプレート変数を環境変数から収集
    print("==> テンプレート変数を環境変数から取得中...")
    chart_vars = _get_chart_vars()

    # 3. YAML テンプレートを rendered/ にレンダリング
    print("==> YAML テンプレートをレンダリング中...")
    _render_chart_templates(chart_vars)

    # 4. SSH / k8s API パケットフィルタを現在のグローバル IP で更新 (Codespaces 再起動で IP が変わるため)
    token, secret, region = get_sakura_env()
    api_base = get_api_base(region)
    print("==> 開発環境のグローバル IP を取得中...")
    my_ip = _get_my_global_ip()
    print(f"==> グローバル IP: {my_ip}")
    _add_ssh_packet_filter_rules(packet_filter_id, my_ip, api_base, token, secret)

    # 5. ArgoCD ブートストラップマニフェストを SSH 経由で適用
    print("==> マニフェストを SSH 経由で kubectl apply 中...")
    _kubectl_apply_remote(sv1_ip, os.path.join(RENDERED_DIR, "bootstrap.yaml"))
    _kubectl_apply_remote(sv1_ip, os.path.join(RENDERED_DIR, "infra-apps.yaml"))
    _kubectl_apply_remote(sv1_ip, os.path.join(RENDERED_DIR, "argocd-config.yaml"))
    print("==> argocd-server を再起動して設定を反映中...")
    _kubectl_rollout_restart_remote(sv1_ip, "deployment/argocd-server", "argocd")
    print("==> cert-manager が Ready になるまで待機中 (ArgoCD がデプロイ中)...")
    _wait_for_cert_manager_remote(sv1_ip)
    _kubectl_apply_remote(sv1_ip, os.path.join(RENDERED_DIR, "cert-manager-issuers.yaml"))
    _kubectl_apply_remote(sv1_ip, os.path.join(RENDERED_DIR, "grafana-oauth-secret.yaml"))
    print("==> Traefik CRD が Ready になるまで待機中 (ArgoCD がデプロイ中)...")
    _wait_for_traefik_remote(sv1_ip)
    _kubectl_apply_remote(sv1_ip, os.path.join(RENDERED_DIR, "argocd-ingress.yaml"))

    print()
    print("=" * 60)
    print("install-charts 完了")
    print("ArgoCD が cert-manager / traefik / tetragon 等を自動デプロイします。")
    print("=" * 60)


# ---------------------------------------------------------------------------
# サブコマンド: deny-ssh
# ---------------------------------------------------------------------------


def cmd_deny_ssh() -> None:
    print("=" * 60)
    print("deny-ssh: SSH アクセスを禁止します")
    print("=" * 60)

    outputs = _get_terraform_output()
    packet_filter_id: str = outputs["packet_filter_id"]["value"]

    token, secret, region = get_sakura_env()
    api_base = get_api_base(region)

    _remove_ssh_packet_filter_rules(packet_filter_id, api_base, token, secret)

    print()
    print("=" * 60)
    print("deny-ssh 完了")
    print("=" * 60)


# ---------------------------------------------------------------------------
# サブコマンド: destroy
# ---------------------------------------------------------------------------


def cmd_destroy() -> None:
    print("=" * 60)
    print("destroy: インフラを削除します")
    print("=" * 60)

    _terraform_destroy()

    print()
    print("=" * 60)
    print("destroy 完了")
    print("=" * 60)


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Flatcar Container Linux + k3s クラスタ管理ツール",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "サブコマンド:\n"
            "  build-infra      ネットワークとサーバを terraform で構築します\n"
            "  boot             Flatcar Linux をインストールして起動します\n"
            "  install-charts   YAML をレンダリングし ArgoCD ブートストラップを適用します\n"
            "  deny-ssh         パケットフィルタで ssh のアクセスを禁止します\n"
            "  destroy          ネットワークとサーバを terraform で削除します\n"
        ),
    )

    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("build-infra",     help="インフラを構築します")
    subparsers.add_parser("boot",            help="Flatcar Linux をインストールして起動します")
    subparsers.add_parser("install-charts",  help="YAML をレンダリングし ArgoCD ブートストラップを適用します")
    subparsers.add_parser("deny-ssh",        help="SSH アクセスを禁止します")
    subparsers.add_parser("destroy",         help="インフラを削除します")

    args = parser.parse_args()

    dispatch = {
        "build-infra":    cmd_build_infra,
        "boot":           cmd_boot,
        "install-charts": cmd_install_charts,
        "deny-ssh":       cmd_deny_ssh,
        "destroy":        cmd_destroy,
    }
    dispatch[args.command]()


if __name__ == "__main__":
    main()
