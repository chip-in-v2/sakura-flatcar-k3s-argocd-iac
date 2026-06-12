# ---------------------------------------------------------------
# k8s-bootstrap.tf
# terraform apply でテンプレートをレンダリングして rendered/ に出力する。
# rendered/ は .gitignore に登録し、機密情報が Git に入らないようにする。
#
# 適用 (クラスタ起動後) は scripts/post-apply.sh が行う。
# ---------------------------------------------------------------

locals {
  rendered_dir = "${path.module}/../rendered"
  # init サーバの内部 IP (servers.tf と同じロジック: cidrhost(192.168.100.0/24, 1))
  init_internal_ip = cidrhost("192.168.100.0/24", 1)
}

# ---------------------------------------------------------------
# argocd-config.yaml の生成
# ---------------------------------------------------------------
resource "local_sensitive_file" "argocd_config" {
  content = templatefile("${path.module}/../argocd/manifests/argocd-config.yaml.tpl", {
    domain                  = var.domain
    gh_organization         = var.gh_organization
    gh_client_id_argocd     = var.gh_client_id_argocd
    gh_client_secret_argocd = var.gh_client_secret_argocd
  })
  filename        = "${local.rendered_dir}/argocd-config.yaml"
  file_permission = "0600"
}

# ---------------------------------------------------------------
# cert-manager-issuers.yaml の生成
# ---------------------------------------------------------------
resource "local_sensitive_file" "cert_manager_issuers" {
  content = templatefile("${path.module}/../argocd/manifests/cert-manager-issuers.yaml.tpl", {
    domain         = var.domain
    do_pat         = var.do_pat
    le_environment = var.le_environment
  })
  filename        = "${local.rendered_dir}/cert-manager-issuers.yaml"
  file_permission = "0600"
}

# ---------------------------------------------------------------
# infra-apps.yaml の生成 (ArgoCD App of Apps から参照)
# NOTE: ArgoCD は rendered/ ではなく Git から読む。
#       post-apply.sh が rendered/ 版を直接 kubectl apply して
#       ArgoCD の App リソースを作成する (GitOps 管理外)。
# ---------------------------------------------------------------
resource "local_sensitive_file" "infra_apps" {
  content = templatefile("${path.module}/../argocd/apps/infra-apps.yaml.tpl", {
    domain           = var.domain
    gh_organization  = var.gh_organization
    init_internal_ip = local.init_internal_ip
    lb_vip_ip        = local.lb_vip_ip
  })
  filename        = "${local.rendered_dir}/infra-apps.yaml"
  file_permission = "0640"
}

# ---------------------------------------------------------------
# Grafana GitHub OAuth 用 Kubernetes Secret の生成
# (infra-apps.yaml.tpl 内で envValueFrom → secretKeyRef で参照する)
# ---------------------------------------------------------------
resource "local_sensitive_file" "grafana_oauth_secret" {
  content = templatefile("${path.module}/../argocd/manifests/grafana-oauth-secret.yaml.tpl", {
    gh_client_id_grafana     = var.gh_client_id_grafana
    gh_client_secret_grafana = var.gh_client_secret_grafana
  })
  filename        = "${local.rendered_dir}/grafana-oauth-secret.yaml"
  file_permission = "0600"
}

# ---------------------------------------------------------------
# bootstrap.yaml (値の置換不要だがまとめて rendered/ に出力)
# ---------------------------------------------------------------
resource "local_file" "argocd_bootstrap" {
  content         = file("${path.module}/../argocd/bootstrap.yaml")
  filename        = "${local.rendered_dir}/bootstrap.yaml"
  file_permission = "0640"
}

# ---------------------------------------------------------------
# cilium-assigned-ips.yaml の生成
# Cilium externalIPs サービス (割り当てIP → 实 Pod DNAT) および
# grafana Ingress (traefik → grafana 割り当てIP ルーティング)
# ---------------------------------------------------------------
resource "local_file" "cilium_assigned_ips" {
  content = templatefile("${path.module}/../argocd/manifests/cilium-assigned-ips.yaml.tpl", {
    domain = var.domain
  })
  filename        = "${local.rendered_dir}/cilium-assigned-ips.yaml"
  file_permission = "0640"
}
