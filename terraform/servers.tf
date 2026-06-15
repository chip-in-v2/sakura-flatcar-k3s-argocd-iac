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
# Ubuntu パブリックアーカイブ (22.04 LTS cloudimg)
# cloud-init 対応イメージを選択するため名前に (cloudimg) を含むものを使用
# ---------------------------------------------------------------
data "sakuracloud_archive" "ubuntu" {
  filter {
    names = ["Ubuntu 22.04", "(cloudimg)"]
  }
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

  # cloud-init でホスト名・静的IP・SSH公開鍵を設定
  # (disk_edit_parameter はディスクが2枚の場合に対象ディスクの特定に失敗することがあるため非使用)
  user_data = <<-EOT
    #cloud-config
    hostname: ${each.key}
    preserve_hostname: true

    ssh_pwauth: false

    ssh_authorized_keys:
      - ${trimspace(tls_private_key.ssh_key.public_key_openssh)}

    write_files:
      - path: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
        content: "network: {config: disabled}\n"
      - path: /etc/netplan/99-static.yaml
        permissions: '0600'
        content: |
          network:
            version: 2
            ethernets:
              ens3:
                dhcp4: false
                addresses:
                  - ${cidrhost(local.lb_cidr, index(local.node_names, each.key) + 6)}/${sakuracloud_internet.lb_router.netmask}
                routes:
                  - to: default
                    via: ${sakuracloud_internet.lb_router.gateway}
                nameservers:
                  addresses: [8.8.8.8, 1.1.1.1]
              ens4:
                dhcp4: false
                addresses:
                  - ${cidrhost("192.168.100.0/24", index(local.node_names, each.key) + 1)}/24

    runcmd:
      - echo "127.0.1.1 ${each.key}" >> /etc/hosts
      - rm -f /etc/netplan/50-cloud-init.yaml
      - netplan apply
    EOT
}
