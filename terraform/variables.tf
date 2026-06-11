# ---------------------------------------------------------------
# さくらのクラウド 認証情報
# ---------------------------------------------------------------
variable "sakura_access_token" {
  description = "さくらのクラウド API アクセストークン"
  type        = string
  sensitive   = true
}

variable "sakura_access_token_secret" {
  description = "さくらのクラウド API アクセストークン シークレット"
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------
# DigitalOcean 認証情報
# ---------------------------------------------------------------
variable "do_pat" {
  description = "DigitalOcean Personal Access Token"
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------
# サーバ設定
# ---------------------------------------------------------------
variable "sakura_label_prefix" {
  description = "サーバのラベルプリフィックス (ホスト名と一致させる)"
  type        = string
  default     = "ops-frontier"
}

variable "sakura_region" {
  description = "さくらのクラウドのリージョン"
  type        = string
  default     = "is1c"
}

variable "sakura_server_cpu" {
  description = "サーバのCPU数"
  type        = number
  default     = 2
}

variable "sakura_server_memory" {
  description = "サーバのメモリサイズ(GB)"
  type        = number
  default     = 4
}

variable "sakura_server_commitment" {
  description = "サーバの占有度 (standard or dedicatedcpu)"
  type        = string
  default     = "standard"
}

variable "sakura_server_cpu_model" {
  description = "サーバのCPUモデル"
  type        = string
  default     = "uncategorized"
}

variable "sakura_iso_image_id" {
  description = "さくらのクラウドにアップロードした Flatcar Linux インストーラ ISO の ID (廃止: Ubuntu アーカイブブートに移行済み)"
  type        = string
  default     = null
}

variable "sakura_registry_subdomain_label" {
  description = "コンテナレジストリのサブドメインラベル (グローバル一意の必要があります)"
  type        = string
  default     = "ops-frontier-registry-20260611"
}

# ---------------------------------------------------------------
# DNS / TLS
# ---------------------------------------------------------------
variable "domain" {
  description = "DigitalOcean DNS に委譲されたドメイン"
  type        = string
}

variable "le_environment" {
  description = "Let's Encrypt の環境 (production または staging)"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging"], var.le_environment)
    error_message = "le_environment は 'production' または 'staging' を指定してください。"
  }
}

# ---------------------------------------------------------------
# GitHub OAuth
# ---------------------------------------------------------------
variable "gh_organization" {
  description = "GitHub 組織 ID"
  type        = string
  default     = "chip-in-v2"
}

variable "gh_client_id_grafana" {
  description = "Grafana 用 GitHub OAuth Client ID"
  type        = string
  sensitive   = true
}

variable "gh_client_secret_grafana" {
  description = "Grafana 用 GitHub OAuth Client Secret"
  type        = string
  sensitive   = true
}

variable "gh_client_id_argocd" {
  description = "ArgoCD 用 GitHub OAuth Client ID"
  type        = string
  sensitive   = true
}

variable "gh_client_secret_argocd" {
  description = "ArgoCD 用 GitHub OAuth Client Secret"
  type        = string
  sensitive   = true
}
