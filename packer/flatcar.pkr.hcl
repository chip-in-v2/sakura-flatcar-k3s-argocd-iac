# packer/flatcar.pkr.hcl
# Flatcar Linux ISO からブートし、EC2 OEM でディスクにインストールして
# さくらのクラウドのカスタムアーカイブを作成する。
#
# EC2 OEM は http://169.254.169.254/latest/user-data から Ignition を読む。
# さくらのクラウドがこのエンドポイントを提供しない場合は openstack OEM を試すこと。
#
# 前提:
#   - Flatcar ISO がさくらのクラウドにアップロード済みであること
#   - packer init packer/ で sakuracloud プラグインをインストール済みであること
#
# 使用方法:
#   packer init packer/
#   packer build \
#     -var "zone=${SAKURA_REGION}" \
#     -var "iso_id=${SAKURA_ISO_IMAGE_ID}" \
#     packer/flatcar.pkr.hcl

packer {
  required_plugins {
    sakuracloud = {
      version = "v0.12.0"
      source  = "github.com/sacloud/sakuracloud"
    }
  }
}

variable "zone" {
  description = "さくらのクラウドのゾーン"
  default     = "is1c"
}

variable "iso_id" {
  description = "さくらのクラウドにアップロード済みの Flatcar ISO イメージ ID"
  type        = string
}

variable "flatcar_oem" {
  description = "インストールする OEM (ec2 または openstack)"
  default     = "ec2"
}

variable "flatcar_version_tag" {
  description = "アーカイブ名に付けるバージョンタグ"
  default     = "stable"
}

# ---------------------------------------------------------------
# Live ISO 用の一時 SSH キーペア
# Flatcar Live 環境は core ユーザで SSH 可能だが、
# Packer から鍵を注入するため user_data で Ignition を渡す。
# ---------------------------------------------------------------
locals {
  # Packer が生成する一時 SSH キーを Ignition で core ユーザに設定する
  # (この Ignition は Flatcar Live 環境上での設定: インストール後は無関係)
  packer_ignition = jsonencode({
    ignition = { version = "3.3.0" }
    passwd = {
      users = [{
        name              = "core"
        sshAuthorizedKeys = ["${var.packer_ssh_pubkey}"]
      }]
    }
  })
}

variable "packer_ssh_pubkey" {
  description = "Packer が Flatcar Live 環境への SSH に使う一時公開鍵"
  type        = string
  # 使用方法: packer build -var "packer_ssh_pubkey=$(cat ~/.ssh/id_ed25519.pub)" ...
}

# ---------------------------------------------------------------
# Sakura Cloud サーバソース
# ---------------------------------------------------------------
source "sakuracloud-server" "flatcar" {
  zone = var.zone

  # サーバスペック (インストール用の最小構成)
  core        = 2
  memory_size = 2

  # ディスク (Flatcar をインストールする先)
  disk_size      = 20
  disk_plan      = "ssd"
  disk_connector = "virtio"

  # Flatcar ISO からブート
  os_type = "custom"
  iso_id  = var.iso_id

  # Live 環境への SSH 設定 (Ignition で core に鍵を注入)
  user_data = local.packer_ignition

  communicator  = "ssh"
  ssh_username  = "core"
  ssh_timeout   = "10m"
  boot_wait     = "90s"  # ISO のブートに時間がかかるため長めに設定

  # 作成するアーカイブの設定
  archive_name        = "flatcar-${var.flatcar_oem}-oem-${var.flatcar_version_tag}"
  archive_description = "Flatcar Container Linux (${var.flatcar_oem} OEM) - built by Packer"
}

# ---------------------------------------------------------------
# ビルド
# ---------------------------------------------------------------
build {
  sources = ["source.sakuracloud-server.flatcar"]

  # Flatcar をディスクにインストール
  # -C ${var.flatcar_oem}: OEM を指定
  #   ec2        -> http://169.254.169.254/latest/user-data から Ignition を読む
  #   openstack  -> http://169.254.169.254/openstack/latest/user_data から読む
  provisioner "shell" {
    inline = [
      "echo '==> Flatcar を /dev/vda にインストール中 (OEM: ${var.flatcar_oem})'",
      "sudo flatcar-install -d /dev/vda -C ${var.flatcar_oem}",
      "echo '==> インストール完了'",
    ]
  }
}
