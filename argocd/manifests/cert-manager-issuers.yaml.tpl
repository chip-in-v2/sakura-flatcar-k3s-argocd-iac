# cert-manager ClusterIssuer - Let's Encrypt DNS-01 (DigitalOcean)
# Terraform apply 後に terraform/scripts/post-apply.sh が適用する
apiVersion: v1
kind: Secret
metadata:
  name: digitalocean-dns
  namespace: cert-manager
type: Opaque
stringData:
  access-token: "${do_pat}"
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "admin@${domain}"
    privateKeySecretRef:
      name: letsencrypt-production-key
    solvers:
      - dns01:
          digitalocean:
            tokenSecretRef:
              name: digitalocean-dns
              key: access-token
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: "admin@${domain}"
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - dns01:
          digitalocean:
            tokenSecretRef:
              name: digitalocean-dns
              key: access-token
---
# ワイルドカード証明書
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-tls
  namespace: traefik
spec:
  secretName: wildcard-tls
  issuerRef:
    name: letsencrypt-${le_environment}
    kind: ClusterIssuer
  dnsNames:
    - "${domain}"
    - "*.${domain}"
