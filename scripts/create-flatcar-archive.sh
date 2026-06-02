#!/bin/bash
# scripts/create-flatcar-archive.sh
# Flatcar Linux のベアメタル raw イメージをダウンロードし、
# さくらのクラウドにカスタムアーカイブとして登録する。
#
# 使用方法: bash scripts/create-flatcar-archive.sh [version]
#   version: Flatcar のバージョン番号 (例: 3975.2.2)。省略時は current (最新 stable)
#
# 必要な環境変数:
#   SAKURA_ACCESS_TOKEN, SAKURA_ACCESS_TOKEN_SECRET
#   SAKURA_REGION (省略時: is1c)
#
# 出力:
#   成功時にアーカイブ ID を表示する。
#   TF_VAR_sakura_flatcar_archive_id に設定して terraform apply を実行すること。
#
# 注意:
#   - イメージは .cache/ にキャッシュされる (.gitignore 対象)
#   - 既に同名のアーカイブが存在する場合はスキップする
#   - アップロードには数分かかる (イメージサイズ ~8GB)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CACHE_DIR="${REPO_ROOT}/.cache"

FLATCAR_VERSION="${1:-current}"
ZONE="${SAKURA_REGION:-is1c}"
SAKURA_TOKEN="${SAKURA_ACCESS_TOKEN}"
SAKURA_SECRET="${SAKURA_ACCESS_TOKEN_SECRET}"
API_BASE="https://secure.sakura.ad.jp/cloud/zone/${ZONE}/api/cloud/1.1"

IMAGE_URL="https://stable.release.flatcar-linux.net/amd64-usr/${FLATCAR_VERSION}/flatcar_production_openstack_image.img.bz2"
IMAGE_PATH="${CACHE_DIR}/flatcar-openstack-${FLATCAR_VERSION}.img"
ARCHIVE_NAME="flatcar-openstack-${FLATCAR_VERSION}"

# ---------------------------------------------------------------
# 既存アーカイブの確認 (冪等性)
# ---------------------------------------------------------------
echo "==> 既存アーカイブを確認中..."
EXISTING=$(curl -sf -u "${SAKURA_TOKEN}:${SAKURA_SECRET}" \
  "${API_BASE}/archive?Count=100" \
  | jq -r --arg name "${ARCHIVE_NAME}" '.Archives[] | select(.Name == $name) | .ID' \
  | head -1)

if [[ -n "${EXISTING}" ]]; then
  echo "==> アーカイブ '${ARCHIVE_NAME}' は既に存在します。"
  echo ""
  echo "アーカイブ ID: ${EXISTING}"
  echo ""
  echo "以下の環境変数を設定してください:"
  echo "  export TF_VAR_sakura_flatcar_archive_id=${EXISTING}"
  exit 0
fi

# ---------------------------------------------------------------
# イメージのダウンロード (キャッシュあればスキップ)
# ---------------------------------------------------------------
mkdir -p "${CACHE_DIR}"

if [[ ! -f "${IMAGE_PATH}" ]]; then
  echo "==> Flatcar ${FLATCAR_VERSION} イメージをダウンロード中..."
  echo "    URL: ${IMAGE_URL}"
  # bunzip2 しながらキャッシュに保存
  curl -L --progress-bar "${IMAGE_URL}" | bunzip2 > "${IMAGE_PATH}"
  echo "==> ダウンロード完了: ${IMAGE_PATH}"
else
  echo "==> キャッシュ済みイメージを使用: ${IMAGE_PATH}"
fi

IMAGE_SIZE_MB=$(( $(wc -c < "${IMAGE_PATH}") / 1024 / 1024 ))
echo "==> イメージサイズ: ${IMAGE_SIZE_MB} MB"

# さくらのクラウドのアーカイブサイズは 20GB 単位 (最小 20GB)
ARCHIVE_SIZE_MB=20480

# ---------------------------------------------------------------
# アーカイブエントリを作成して FTP クレデンシャルを取得
# ---------------------------------------------------------------
echo "==> さくらのクラウドにアーカイブエントリを作成中..."
CREATE_RESP=$(curl -sf -X POST \
  -u "${SAKURA_TOKEN}:${SAKURA_SECRET}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg name "${ARCHIVE_NAME}" \
    --argjson size "${ARCHIVE_SIZE_MB}" \
    '{Archive:{Name:$name,SizeMB:$size,Description:"Flatcar Container Linux OpenStack OEM - managed by create-flatcar-archive.sh"}}')" \
  "${API_BASE}/archive")

ARCHIVE_ID=$(echo "${CREATE_RESP}" | jq -r '.Archive.ID')
FTP_HOST=$(echo "${CREATE_RESP}" | jq -r '.FTPServer.HostName')
FTP_USER=$(echo "${CREATE_RESP}" | jq -r '.FTPServer.User')
FTP_PASS=$(echo "${CREATE_RESP}" | jq -r '.FTPServer.Password')
echo "==> アーカイブ ID: ${ARCHIVE_ID}"

echo "==> FTP サーバ: ${FTP_HOST}"

# ---------------------------------------------------------------
# イメージを FTP アップロード
# ---------------------------------------------------------------
echo "==> イメージをアップロード中 (数分かかります)..."
curl --progress-bar \
  --ssl --ftp-pasv \
  --upload-file "${IMAGE_PATH}" \
  --user "${FTP_USER}:${FTP_PASS}" \
  "ftp://${FTP_HOST}/"

echo ""
echo "==> アップロード完了。"

# ---------------------------------------------------------------
# FTP を閉じてアーカイブを確定
# ---------------------------------------------------------------
echo "==> アーカイブを確定中..."
curl -sf -X DELETE \
  -u "${SAKURA_TOKEN}:${SAKURA_SECRET}" \
  "${API_BASE}/archive/${ARCHIVE_ID}/ftp" >/dev/null

# アーカイブが Ready になるまで待機
echo "==> アーカイブの準備完了を待機中..."
for i in $(seq 1 30); do
  STATUS=$(curl -sf -u "${SAKURA_TOKEN}:${SAKURA_SECRET}" \
    "${API_BASE}/archive/${ARCHIVE_ID}" \
    | jq -r '.Archive.Availability')
  if [[ "${STATUS}" == "available" ]]; then
    echo "==> アーカイブが利用可能になりました。"
    break
  fi
  echo "    待機中... (${i}/30) status=${STATUS}"
  sleep 10
done

echo ""
echo "================================================================"
echo " Flatcar アーカイブ登録完了!"
echo "----------------------------------------------------------------"
echo " アーカイブ名: ${ARCHIVE_NAME}"
echo " アーカイブ ID: ${ARCHIVE_ID}"
echo "================================================================"
echo ""
echo "以下の環境変数を設定してから terraform apply を実行してください:"
echo "  export TF_VAR_sakura_flatcar_archive_id=${ARCHIVE_ID}"
echo ""
echo "Codespaces を使用している場合は SAKURA_FLATCAR_ARCHIVE_ID シークレットに"
echo "  ${ARCHIVE_ID}"
echo "を設定してください。"
