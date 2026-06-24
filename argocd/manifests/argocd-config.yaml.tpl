# ArgoCD 設定 - GitHub OAuth + Ingress
# kubectl apply -n argocd -f argocd/manifests/argocd-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-cm
    app.kubernetes.io/part-of: argocd
data:
  # GitHub SSO via Dex
  dex.config: |
    connectors:
      - type: github
        id: github
        name: GitHub
        config:
          clientID: ${gh_client_id_argocd}
          clientSecret: $dex.github.clientSecret
          orgs:
            - name: ${gh_organization}
  url: "https://argocd.${domain}"
  resource.exclusions: |
    - apiGroups:
      - cert-manager.io
      - acme.cert-manager.io
      kinds:
      - CertificateRequest
      - Order
      - Challenge
      clusters:
      - "*"
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-secret
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-secret
    app.kubernetes.io/part-of: argocd
type: Opaque
stringData:
  dex.github.clientSecret: "${gh_client_secret_argocd}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.csv: |
    p, role:developer, applications, get, */*, allow
    p, role:developer, applications, sync, */*, allow
    p, role:developer, applications, action/*, */*, allow
    p, role:developer, logs, get, */*, allow
    g, ${gh_organization}:admin, role:admin
    g, ${gh_organization}:developer, role:developer
  policy.default: role:developer
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
data:
  server.insecure: "true"

