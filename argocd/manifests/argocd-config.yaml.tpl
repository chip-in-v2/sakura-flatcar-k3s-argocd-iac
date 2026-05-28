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
  oidc.github.clientSecret: "${gh_client_secret_argocd}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.csv: |
    g, ${gh_organization}:admin, role:admin
    g, ${gh_organization}:developer, role:readonly
  policy.default: role:''
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.options: "default"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - "argocd.${domain}"
      secretName: wildcard-tls
  rules:
    - host: "argocd.${domain}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
