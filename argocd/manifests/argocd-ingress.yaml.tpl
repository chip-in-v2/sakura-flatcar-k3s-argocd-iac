# ArgoCD Ingress + Traefik TLSStore
# Traefik CRD が登録された後に適用する
# Traefik のデフォルト TLS ストア (traefik namespace の wildcard-tls を使用)
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: traefik
spec:
  defaultCertificate:
    secretName: wildcard-tls
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.tls: "true"
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
