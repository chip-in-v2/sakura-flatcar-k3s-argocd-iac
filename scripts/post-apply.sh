#!/bin/bash
# scripts/post-apply.sh
# terraform apply 後にクラスタが起動するのを待ち、
# rendered/ の Kubernetes マニフェストをすべて適用する。
#
# 使用方法: bash scripts/post-apply.sh
#
# 前提:
#   - terraform apply が完了していること
#   - SAKURA_ACCESS_TOKEN / SAKURA_ACCESS_TOKEN_SECRET 環境変数が設定されていること

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
RENDERED_DIR="${REPO_ROOT}/rendered"
KUBECONFIG_PATH="${HOME}/.kube/config-sakura-k3s"
PRIVATE_KEY="${REPO_ROOT}/.ssh/id_ed25519"

export KUBECONFIG="${KUBECONFIG_PATH}"

# ---------------------------------------------------------------
# Step 1: terraform apply で rendered/ が生成済みか確認
# ---------------------------------------------------------------
echo "==> [1/5] rendered/ ディレクトリを確認中..."
if [[ ! -d "${RENDERED_DIR}" ]]; then
  echo "ERROR: ${RENDERED_DIR} が見つかりません。先に 'terraform apply' を実行してください。" >&2
  exit 1
fi
for f in argocd-config.yaml cert-manager-issuers.yaml infra-apps.yaml grafana-oauth-secret.yaml bootstrap.yaml; do
  if [[ ! -f "${RENDERED_DIR}/${f}" ]]; then
    echo "ERROR: ${RENDERED_DIR}/${f} が見つかりません。terraform apply を再実行してください。" >&2
    exit 1
  fi
done
echo "    OK: すべてのレンダリング済みファイルを確認しました。"

# ---------------------------------------------------------------
# Step 2: sv1 の IP を terraform output から取得
# ---------------------------------------------------------------
echo "==> [2/5] terraform output から sv1 の IP を取得中..."
cd "${TF_DIR}"
SV1_IP=$(terraform output -json node_public_ips | python3 -c \
  "import sys,json; d=json.load(sys.stdin); sv1_key=[k for k in d.keys() if k.endswith('-sv1')][0]; print(d[sv1_key])")
echo "    sv1: ${SV1_IP}"

# ---------------------------------------------------------------
# Step 3: k3s が Ready になるまで待機 + kubeconfig 取得
# ---------------------------------------------------------------
echo "==> [3/5] k3s クラスタの起動を待機中..."
mkdir -p "${HOME}/.kube"

MAX_RETRY=60
RETRY=0
until ssh -i "${PRIVATE_KEY}" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    "core@${SV1_IP}" \
    "sudo kubectl get nodes --no-headers 2>/dev/null | grep -qE ' Ready'" 2>/dev/null; do
  RETRY=$((RETRY + 1))
  if [[ $RETRY -ge $MAX_RETRY ]]; then
    echo "ERROR: k3s が ${MAX_RETRY} 回試行しても Ready になりませんでした。" >&2
    exit 1
  fi
  echo "    待機中... (${RETRY}/${MAX_RETRY})"
  sleep 15
done
echo "    クラスタ Ready!"

# kubeconfig を取得
ssh -i "${PRIVATE_KEY}" -o StrictHostKeyChecking=no \
  "core@${SV1_IP}" "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/${SV1_IP}/g" \
  > "${KUBECONFIG_PATH}"
chmod 600 "${KUBECONFIG_PATH}"
echo "    kubeconfig を ${KUBECONFIG_PATH} に保存しました。"

# ---------------------------------------------------------------
# Step 4: namespace を作成してマニフェストを適用
# ---------------------------------------------------------------
echo "==> [4/5] Kubernetes マニフェストを適用中..."

kubectl create namespace argocd       --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace traefik      --dry-run=client -o yaml | kubectl apply -f -

# Grafana OAuth Secret (機密情報 - rendered/ から適用)
kubectl apply -f "${RENDERED_DIR}/grafana-oauth-secret.yaml"

# cert-manager ClusterIssuer + DigitalOcean Secret + ワイルドカード証明書
kubectl apply -f "${RENDERED_DIR}/cert-manager-issuers.yaml"

# ArgoCD の設定 (GitHub OAuth, RBAC, Ingress)
kubectl apply -f "${RENDERED_DIR}/argocd-config.yaml"

# ArgoCD App of Apps bootstrap
kubectl apply -f "${RENDERED_DIR}/bootstrap.yaml"

# インフラ Helm チャート群の ArgoCD Application 定義
kubectl apply -f "${RENDERED_DIR}/infra-apps.yaml"

echo "    完了!"

# ---------------------------------------------------------------
# Step 5: ArgoCD 初期パスワード表示
# ---------------------------------------------------------------
echo "==> [5/5] ArgoCD 初期管理者パスワードを取得中..."
sleep 5
ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "(まだ生成されていません)")

DOMAIN=$(terraform output -raw domain 2>/dev/null || echo "${DOMAIN:-<your-domain>}")

echo ""
echo "================================================================"
echo " セットアップ完了!"
echo "----------------------------------------------------------------"
echo " ArgoCD:  https://argocd.${DOMAIN}"
echo "           admin / ${ARGOCD_PWD}"
echo " Grafana: https://grafana.${DOMAIN}"
echo "           (GitHub OAuth でログイン)"
echo "================================================================"
echo ""
echo "KUBECONFIG を有効にするには:"
echo "  export KUBECONFIG=${KUBECONFIG_PATH}"
