#!/bin/bash
# Terraform external data source から Butane YAML を受け取り
# butane コマンドで Ignition JSON に変換して返す。
# Input:  {"content": "<butane yaml>"}
# Output: {"json": "<ignition json>"}

set -euo pipefail

INPUT=$(cat)
CONTENT=$(echo "$INPUT" | jq -r '.content')

if ! command -v butane &>/dev/null; then
  # butane が未インストールの場合は自動インストール
  BUTANE_VERSION="v0.21.0"
  ARCH=$(uname -m | sed 's/x86_64/x86_64/;s/aarch64/aarch64/')
  curl -sfL "https://github.com/coreos/butane/releases/download/${BUTANE_VERSION}/butane-${ARCH}-unknown-linux-gnu" \
    -o /usr/local/bin/butane
  chmod +x /usr/local/bin/butane
fi

JSON=$(echo "$CONTENT" | butane --pretty --strict 2>&1)

jq -n --arg json "$JSON" '{"json": $json}'
