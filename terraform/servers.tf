# ---------------------------------------------------------------
# ローカル変数
# ---------------------------------------------------------------
locals {
  node_count    = 3
  node_names    = [for i in range(1, local.node_count + 1) : "${var.sakura_label_prefix}-sv${i}"]
  cluster_token = random_password.k3s_cluster_token.result
}

# ---------------------------------------------------------------
# k3s クラスタトークン (ランダム生成)
# ---------------------------------------------------------------
resource "random_password" "k3s_cluster_token" {
  length  = 64
  special = false
}

# ---------------------------------------------------------------
# 内部ネットワーク (スイッチ)
# ---------------------------------------------------------------
resource "sakuracloud_switch" "internal" {
  name        = "${var.sakura_label_prefix}-internal"
  description = "k3s クラスタノード間内部通信用スイッチ"
}

# ---------------------------------------------------------------
# Ubuntu パブリックアーカイブ (22.04 LTS)
# ---------------------------------------------------------------
data "sakuracloud_archive" "ubuntu" {
  os_type = "ubuntu2204"
}

# ---------------------------------------------------------------
# ブートストラップディスク (Ubuntu 20GB)
# グローバルIP・SSH公開鍵をディスク修正で設定
# ---------------------------------------------------------------
resource "sakuracloud_disk" "bootstrap" {
  for_each = toset(local.node_names)

  name              = "${each.key}-bootstrap"
  plan              = "ssd"
  size              = 20
  connector         = "virtio"
  source_archive_id = data.sakuracloud_archive.ubuntu.id
  description       = "Ubuntu bootstrap disk for ${each.key}"
}

# ---------------------------------------------------------------
# ターゲットディスク (Flatcar 用 40GB・未フォーマット)
# ---------------------------------------------------------------
resource "sakuracloud_disk" "nodes" {
  for_each = toset(local.node_names)

  name        = "${each.key}-disk"
  plan        = "ssd"
  size        = 40
  connector   = "virtio"
  description = "Flatcar target disk for ${each.key}"
}

# ---------------------------------------------------------------
# サーバ (3台)
# ---------------------------------------------------------------
resource "sakuracloud_server" "nodes" {
  for_each = toset(local.node_names)

  name        = each.key
  description = "k3s control-plane + worker node"
  tags        = [var.sakura_label_prefix, "k3s", each.key]

  core       = var.sakura_server_cpu
  memory     = var.sakura_server_memory
  commitment = var.sakura_server_commitment
  cpu_model  = var.sakura_server_cpu_model != "uncategorized" ? var.sakura_server_cpu_model : null

  # ISOイメージは使用しない。ブートストラップディスク (Ubuntu) から起動
  disks = [
    sakuracloud_disk.bootstrap[each.key].id, # /dev/vda - Ubuntu ブートディスク
    sakuracloud_disk.nodes[each.key].id,     # /dev/vdb - Flatcar ターゲットディスク
  ]

  # NIC 0: LB ルータスイッチ (グローバル IP / LB バックエンド)
  network_interface {
    upstream         = sakuracloud_internet.lb_router.switch_id
    packet_filter_id = sakuracloud_packet_filter.public.id
    user_ip_address  = cidrhost(local.lb_cidr, index(local.node_names, each.key) + 6)
  }

  # NIC 1: 内部ネットワーク
  network_interface {
    upstream        = sakuracloud_switch.internal.id
    user_ip_address = cidrhost("192.168.100.0/24", index(local.node_names, each.key) + 1)
  }

  # ディスク修正でグローバルIPとSSH公開鍵を設定
  disk_edit_parameter {
    hostname        = each.key
    ip_address      = cidrhost(local.lb_cidr, index(local.node_names, each.key) + 6)
    netmask         = sakuracloud_internet.lb_router.netmask
    gateway         = sakuracloud_internet.lb_router.gateway
    ssh_key_ids     = [sakuracloud_ssh_key.main.id]
    disable_pw_auth = true
  }
}
