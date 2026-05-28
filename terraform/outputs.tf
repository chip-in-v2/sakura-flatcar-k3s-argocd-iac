output "node_public_ips" {
  description = "各ノードのパブリック IP アドレス"
  value = {
    for name in local.node_names :
    name => sakuracloud_server.nodes[name].network_interface[0].ip_address
  }
}

output "node_private_ips" {
  description = "各ノードの内部 IP アドレス"
  value = {
    for name in local.node_names :
    name => sakuracloud_server.nodes[name].network_interface[1].ip_address
  }
}

output "lb_global_ip" {
  description = "ロードバランサのグローバル IP (VIP)"
  value       = local.lb_vip_ip
}

output "container_registry_fqdn" {
  description = "コンテナレジストリの FQDN"
  value       = sakuracloud_container_registry.main.fqdn
}

output "container_registry_pull_user" {
  description = "コンテナレジストリ Pull 用ユーザ名"
  value       = "k3s-pull"
}

output "container_registry_pull_password" {
  description = "コンテナレジストリ Pull 用パスワード"
  value       = random_password.registry_pull_password.result
  sensitive   = true
}

output "container_registry_push_user" {
  description = "コンテナレジストリ Push 用ユーザ名"
  value       = "ci-push"
}

output "container_registry_push_password" {
  description = "コンテナレジストリ Push 用パスワード"
  value       = random_password.registry_push_password.result
  sensitive   = true
}

output "k3s_cluster_token" {
  description = "k3s クラスタトークン"
  value       = random_password.k3s_cluster_token.result
  sensitive   = true
}

output "packet_filter_id" {
  description = "パブリック NIC 用パケットフィルタ ID (ssh-config.sh で SSH 許可ルール追加に使用)"
  value       = sakuracloud_packet_filter.public.id
}
