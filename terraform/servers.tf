# ---------------------------------------------------------------
# ローカル変数
# ---------------------------------------------------------------
locals {
  node_count   = 3
  node_names   = [for i in range(1, local.node_count + 1) : "${var.sakura_label_prefix}-sv${i}"]
  cluster_token = random_password.k3s_cluster_token.result

  # Butane -> Ignition JSON を各ノード用にレンダリング
  ignition_configs = { for i, name in local.node_names :
    name => templatefile("${path.module}/../butane/node.yaml.tpl", {
      hostname       = name
      cluster_token  = local.cluster_token
      server_is_init = i == 0  # sv1 が init サーバ
      init_ip        = cidrhost("192.168.100.0/24", 1)
      internal_ip    = cidrhost("192.168.100.0/24", i + 1)
      lb_ip          = cidrhost(local.lb_cidr, i + 6)
      lb_netmask     = sakuracloud_internet.lb_router.netmask
      lb_gateway     = sakuracloud_internet.lb_router.gateway
      ssh_public_key = tls_private_key.ssh_key.public_key_openssh
      domain         = var.domain
    })
  }
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
# ディスク (各ノード用 - Flatcar Linux アーカイブから作成)
# ---------------------------------------------------------------
resource "sakuracloud_disk" "nodes" {
  for_each = toset(local.node_names)

  name              = "${each.key}-disk"
  plan              = "ssd"
  size              = 40
  connector         = "virtio"
  description       = "Flatcar OS disk for ${each.key}"
  source_archive_id = var.sakura_flatcar_archive_id
}

# ---------------------------------------------------------------
# サーバ (3台)
# ---------------------------------------------------------------
resource "sakuracloud_server" "nodes" {
  for_each = toset(local.node_names)

  name        = each.key
  description = "k3s control-plane + worker node"
  tags        = [var.sakura_label_prefix, "k3s", each.key]

  core               = var.sakura_server_cpu
  memory             = var.sakura_server_memory
  commitment         = var.sakura_server_commitment
  cpu_model          = var.sakura_server_cpu_model != "uncategorized" ? var.sakura_server_cpu_model : null

  disks = [sakuracloud_disk.nodes[each.key].id]

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

  # Ignition 設定を UserData として渡す
  user_data = chomp(data.external.ignition[each.key].result["json"])

  lifecycle {
    # user_data (Ignition) は初回起動時のみ使用されるため変更を無視
    ignore_changes = [user_data]
  }
}

data "external" "ignition" {
  for_each = toset(local.node_names)

  program = ["bash", "${path.module}/../scripts/butane-render.sh"]
  query = {
    content = local.ignition_configs[each.key]
  }
}
