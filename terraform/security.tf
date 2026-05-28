# ---------------------------------------------------------------
# SSH 鍵ペア (オンデマンド生成)
# ---------------------------------------------------------------
resource "tls_private_key" "ssh_key" {
  algorithm = "ED25519"
}

# 秘密鍵をローカルに保存 (gitignore 対象)
resource "local_sensitive_file" "ssh_private_key" {
  content         = tls_private_key.ssh_key.private_key_openssh
  filename        = "${path.module}/../.ssh/id_ed25519"
  file_permission = "0600"
}

resource "local_file" "ssh_public_key" {
  content         = tls_private_key.ssh_key.public_key_openssh
  filename        = "${path.module}/../.ssh/id_ed25519.pub"
  file_permission = "0644"
}

# ---------------------------------------------------------------
# Firewall Group
# ---------------------------------------------------------------
resource "sakuracloud_packet_filter" "public" {
  name        = "${var.sakura_label_prefix}-public"
  description = "パブリックNIC用 パケットフィルタ。HTTP/HTTPS のみ許可"

  # HTTPS
  expression {
    protocol            = "tcp"
    destination_port    = "443"
    allow               = true
    description         = "HTTPS"
  }

  # HTTP
  expression {
    protocol            = "tcp"
    destination_port    = "80"
    allow               = true
    description         = "HTTP"
  }

  # k3s API (内部ロードバランサからのみ使用するが、HealthCheck用に一時的に許可)
  # SSH は ssh-config.sh で動的に追加するため、デフォルトは閉じる

  # その他すべて拒否
  expression {
    protocol    = "ip"
    allow       = false
    description = "default deny"
  }
}

# パブリックNICにパケットフィルタを適用 (各サーバの network_interface[0] に packet_filter_id を設定)
# → servers.tf の sakuracloud_server.nodes 内 NIC 0 ブロックで参照する
