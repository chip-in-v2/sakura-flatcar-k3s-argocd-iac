# ---------------------------------------------------------------
# さくらのクラウド ロードバランサ (L4)
# ---------------------------------------------------------------

# ルータ + スイッチ (LB 用グローバルIP)
resource "sakuracloud_internet" "lb_router" {
  name        = "${var.sakura_label_prefix}-lb-router"
  netmask     = 28
  band_width  = 100
  description = "LB 用 グローバル IP ルータ"
}

locals {
  lb_cidr      = "${sakuracloud_internet.lb_router.network_address}/${sakuracloud_internet.lb_router.netmask}"
  lb_mgmt_ip   = cidrhost(local.lb_cidr, 2)  # LB 管理 IP
  lb_vip_ip    = cidrhost(local.lb_cidr, 4)  # VIP (DNS が指すパブリック IP)
}

resource "sakuracloud_load_balancer" "lb" {
  name        = "${var.sakura_label_prefix}-lb"
  description = "HTTP/HTTPS L4 ロードバランサ"
  plan        = "standard"

  network_interface {
    switch_id    = sakuracloud_internet.lb_router.switch_id
    vrid         = 1
    ip_addresses = [local.lb_mgmt_ip]
    netmask      = sakuracloud_internet.lb_router.netmask
    gateway      = sakuracloud_internet.lb_router.gateway
  }

  # HTTPS VIP
  vip {
    vip        = local.lb_vip_ip
    port       = 443
    delay_loop = 10

    dynamic "server" {
      for_each = local.node_names
      content {
        ip_address = sakuracloud_server.nodes[server.value].network_interface[0].user_ip_address
        protocol   = "https"
        path       = "/"
        status     = "200"
        enabled    = true
      }
    }
  }

  # HTTP VIP (HTTPS へのリダイレクトは Ingress Controller 側で実施)
  vip {
    vip        = local.lb_vip_ip
    port       = 80
    delay_loop = 10

    dynamic "server" {
      for_each = local.node_names
      content {
        ip_address = sakuracloud_server.nodes[server.value].network_interface[0].user_ip_address
        protocol   = "http"
        path       = "/"
        status     = "200"
        enabled    = true
      }
    }
  }
}

# ---------------------------------------------------------------
# DigitalOcean DNS - ドメイン確認 (既存ドメインを参照)
# ---------------------------------------------------------------
data "digitalocean_domain" "main" {
  name = var.domain
}

# ワイルドカード A レコード -> LB VIP グローバル IP
resource "digitalocean_record" "wildcard" {
  domain = data.digitalocean_domain.main.id
  type   = "A"
  name   = "*"
  value  = local.lb_vip_ip
  ttl    = 300
}

# apex A レコード
resource "digitalocean_record" "apex" {
  domain = data.digitalocean_domain.main.id
  type   = "A"
  name   = "@"
  value  = local.lb_vip_ip
  ttl    = 300
}

# ---------------------------------------------------------------
# さくらのクラウド コンテナレジストリ
# ---------------------------------------------------------------
resource "sakuracloud_container_registry" "main" {
  name            = "${replace(var.sakura_label_prefix, "-", "")}registry"
  access_level    = "none"
  subdomain_label = "${replace(var.sakura_label_prefix, "-", "")}reg"
  description     = "インフラ組み込み Helm チャート用コンテナレジストリ"

  user {
    name       = "k3s-pull"
    password   = random_password.registry_pull_password.result
    permission = "readonly"
  }

  user {
    name       = "ci-push"
    password   = random_password.registry_push_password.result
    permission = "readwrite"
  }
}

resource "random_password" "registry_pull_password" {
  length  = 32
  special = false
}

resource "random_password" "registry_push_password" {
  length  = 32
  special = false
}
