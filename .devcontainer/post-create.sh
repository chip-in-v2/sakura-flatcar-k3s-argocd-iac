#!/bin/bash
set -e

# ---------------------------------------------------------------
# TF_VAR_ 環境変数を ~/.bashrc に転記
# ---------------------------------------------------------------
cat << 'INNER_EOF' >> ~/.bashrc
# Export TF_VAR_ variables from Codespaces secrets
for var in DO_PAT SAKURA_ACCESS_TOKEN SAKURA_ACCESS_TOKEN_SECRET SAKURA_LABEL_PREFIX SAKURA_REGION SAKURA_SERVER_CPU SAKURA_SERVER_MEMORY SAKURA_SERVER_COMMITMENT SAKURA_SERVER_CPU_MODEL DOMAIN LE_ENVIRONMENT SAKURA_ISO_IMAGE_ID GH_ORGANIZATION GH_CLIENT_ID_GRAFANA GH_CLIENT_SECRET_GRAFANA GH_CLIENT_ID_ARGOCD GH_CLIENT_SECRET_ARGOCD; do
    if [ -n "${!var}" ]; then
        export TF_VAR_$(echo "$var" | tr '[:upper:]' '[:lower:]')="${!var}"
    fi
done
INNER_EOF

# ---------------------------------------------------------------
# butane インストール
# ---------------------------------------------------------------
BUTANE_VERSION="v0.21.0"
ARCH=$(uname -m)
BUTANE_URL="https://github.com/coreos/butane/releases/download/${BUTANE_VERSION}/butane-${ARCH}-unknown-linux-gnu"
echo "==> butane ${BUTANE_VERSION} をインストール中..."
curl -sfL "${BUTANE_URL}" -o /usr/local/bin/butane
chmod +x /usr/local/bin/butane
butane --version

# ---------------------------------------------------------------
# スクリプトに実行権限を付与
# ---------------------------------------------------------------
chmod +x /workspaces/sakura-flatcar-k3s-argocd-iac/scripts/butane-render.sh
chmod +x /workspaces/sakura-flatcar-k3s-argocd-iac/scripts/post-apply.sh
chmod +x /workspaces/sakura-flatcar-k3s-argocd-iac/ssh-config.sh

# ---------------------------------------------------------------
# .ssh ディレクトリを作成 (Terraform が秘密鍵を書き込む先)
# ---------------------------------------------------------------
mkdir -p /workspaces/sakura-flatcar-k3s-argocd-iac/.ssh
chmod 700 /workspaces/sakura-flatcar-k3s-argocd-iac/.ssh

echo "==> post-create.sh 完了。"
echo "    次のステップ: cd terraform && terraform init && terraform apply"
