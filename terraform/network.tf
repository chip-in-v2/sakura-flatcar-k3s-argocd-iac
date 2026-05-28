# ---------------------------------------------------------------
# さくらのクラウド ロードバランサ (L4)
# ---------------------------------------------------------------
resource "sakuracloud_load_balancer" "lb" {
  name        = "${var.sakura_label_prefix}-lb"
  description = "HTTP/HTTPS L4 ロードバランサ"
  plan        = "standard"

  network_interface {
    switch_id    = sakuracloud_internet.lb_router.switch_id
    vrid         = 1
    ip_addresses = [cidrhost(sakuracloud_internet.lb_router.ip_network, 4)]
    nw_mask_len  = sakuracloud_internet.lb_router.nw_mask_len
    gateway      = sakuracloud_internet.lb_router.gateway
  }
}

# ルータ + スイッチ (LB 用グローバルIP)
resource "sakuracloud_internet" "lb_router" {
  name        = "${var.sakura_label_prefix}-lb-router"
  netmask     = 28
  band_width  = 100
  description = "LB 用 グローバル IP ルータ"
}

# HTTPS VIP
resource "sakuracloud_load_balancer_vip" "https" {
  load_balancer_id = sakuracloud_load_balancer.lb.id
  port             = 443
  delay_loop       = 10
  sorry_server     = cidrhost("192.168.100.0/24", 1) # sv1 をソーリーサーバに
}

# HTTP VIP (HTTPS にリダイレクトさせる Ingress Controller 側で実施)
resource "sakuracloud_load_balancer_vip" "http" {
  load_balancer_id = sakuracloud_load_balancer.lb.id
  port             = 80
  delay_loop       = 10
  sorry_server     = cidrhost("192.168.100.0/24", 1)
}

# ノードを実サーバとして LB に登録
resource "sakuracloud_load_balancer_server" "https_nodes" {
  for_each = toset(local.node_names)

  load_balancer_vip_id = sakuracloud_load_balancer_vip.https.id
  ip_address           = sakuracloud_server.nodes[each.key].network_interface[1].ip_address
  port                 = 443
  enabled              = true
  health_check_path    = "/healthz"
  health_check_status  = 200
}

resource "sakuracloud_load_balancer_server" "http_nodes" {
  for_each = toset(local.node_names)

  load_balancer_vip_id = sakuracloud_load_balancer_vip.http.id
  ip_address           = sakuracloud_server.nodes[each.key].network_interface[1].ip_address
  port                 = 80
  enabled              = true
  health_check_path    = "/healthz"
  health_check_status  = 200
}

# ---------------------------------------------------------------
# DigitalOcean DNS - ドメイン確認 (既存ドメインを参照)
# ---------------------------------------------------------------
data "digitalocean_domain" "main" {
  name = var.domain
}

# ワイルドカード A レコード -> LB グローバル IP
resource "digitalocean_record" "wildcard" {
  domain = data.digitalocean_domain.main.id
  type   = "A"
  name   = "*"
  value  = cidrhost(sakuracloud_internet.lb_router.ip_network, 4)
  ttl    = 300
}

# apex A レコード
resource "digitalocean_record" "apex" {
  domain = data.digitalocean_domain.main.id
  type   = "A"
  name   = "@"
  value  = cidrhost(sakuracloud_internet.lb_router.ip_network, 4)
  ttl    = 300
}

# ---------------------------------------------------------------
# さくらのクラウド コンテナレジストリ
# ---------------------------------------------------------------
resource "sakuracloud_container_registry" "main" {
  name            = "${replace(var.sakura_label_prefix, "-", "")}registry"
  access_level    = "readwrite"
  subdomain_label = "${replace(var.sakura_label_prefix, "-", "")}reg"
  description     = "インフラ組み込み Helm チャート用コンテナレジストリ"
}

resource "sakuracloud_container_registry_user" "k3s" {
  container_registry_id = sakuracloud_container_registry.main.id
  username              = "k3s-pull"
  password              = random_password.registry_pull_password.result
  permission            = "ro"
}

resource "sakuracloud_container_registry_user" "ci" {
  container_registry_id = sakuracloud_container_registry.main.id
  username              = "ci-push"
  password              = random_password.registry_push_password.result
  permission            = "readwrite"
}

resource "random_password" "registry_pull_password" {
  length  = 32
  special = false
}

resource "random_password" "registry_push_password" {
  length  = 32
  special = false
}
