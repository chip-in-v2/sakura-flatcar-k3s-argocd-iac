terraform {
  required_version = ">= 1.7"

  required_providers {
    sakuracloud = {
      source  = "sacloud/sakuracloud"
      version = "~> 2.25"
    }
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.39"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "sakuracloud" {
  token  = var.sakura_access_token
  secret = var.sakura_access_token_secret
  zone   = var.sakura_region
}

provider "digitalocean" {
  token = var.do_pat
}
