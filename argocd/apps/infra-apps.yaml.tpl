# ---------------------------------------------------------------
# Cilium (CNI + kube-proxy replacement + 割り当てIPインターセプト)
# 注意: 初回ブートストラップは butane/node.yaml.tpl の install-argocd.sh で実施済み。
# ArgoCD は以後のアップデート・設定変更を管理する。
# ---------------------------------------------------------------
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cilium
  namespace: argocd
spec:
  project: infra
  source:
    repoURL: https://helm.cilium.io
    chart: cilium
    targetRevision: "1.16.*"
    helm:
      values: |
        kubeProxyReplacement: "true"
        k8sServiceHost: "${init_internal_ip}"
        k8sServicePort: "6443"
        operator:
          replicas: 1
        ipam:
          mode: kubernetes
        # 割り当てIP (127.0.99.x) への接続をソケットレベルでインターセプトするため socketLB を有効化
        socketLB:
          enabled: true
        localRedirectPolicy: true
        hubble:
          relay:
            enabled: true
          ui:
            enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
---
# ---------------------------------------------------------------
# Traefik (Ingress Controller + L7 TLS 終端)
# ---------------------------------------------------------------
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: argocd
spec:
  project: infra
  source:
    repoURL: https://helm.traefik.io/traefik
    chart: traefik
    targetRevision: "28.*"
    helm:
      values: |
        service:
          type: NodePort
          spec:
            externalIPs:
              - "${lb_vip_ip}"
        ports:
          web:
            nodePort: 80
            redirectTo:
              port: websecure
              permanent: true
          websecure:
            nodePort: 443
        additionalArguments:
          - "--serversTransport.insecureSkipVerify=true"
          - "--entryPoints.websecure.http.tls=true"
          - "--entryPoints.websecure.http.tls.options=default"
        tlsOptions:
          default:
            sniStrict: false
        logs:
          general:
            format: json
          access:
            enabled: true
            format: json
  destination:
    server: https://kubernetes.default.svc
    namespace: traefik
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
# ---------------------------------------------------------------
# cert-manager (Let's Encrypt ACME DNS-01)
# ---------------------------------------------------------------
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  project: infra
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: "v1.*"
    helm:
      values: |
        installCRDs: true
        extraArgs:
          - --dns01-recursive-nameservers=8.8.8.8:53,1.1.1.1:53
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
# ---------------------------------------------------------------
# Tetragon (eBPF セキュリティ監視)
# ---------------------------------------------------------------
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tetragon
  namespace: argocd
spec:
  project: infra
  source:
    repoURL: https://helm.cilium.io
    chart: tetragon
    targetRevision: "1.*"
    helm:
      values: |
        tetragon:
          exportFilename: /var/run/cilium/tetragon/tetragon.log
          exportFileMaxSizeMB: 10
          exportFileMaxBackups: 5
          exportFilePerm: "600"
          # JSON エクスポートで vector が収集できるようにする
          enableExportAggregation: false
        export:
          stdout:
            enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
---
# ---------------------------------------------------------------
# Vector (ログ/メトリクス収集)
# ---------------------------------------------------------------
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vector
  namespace: argocd
spec:
  project: infra
  source:
    repoURL: https://helm.vector.dev
    chart: vector
    targetRevision: "0.*"
    helm:
      values: |
        role: Agent
        customConfig:
          data_dir: /vector-data-dir
          sources:
            kubernetes_logs:
              type: kubernetes_logs
              auto_partial_merge: true
            k3s_journal:
              type: journald
              units:
                - k3s
                - containerd
            tetragon_logs:
              type: file
              include:
                - /var/run/cilium/tetragon/tetragon.log
              data_dir: /vector-data-dir

          transforms:
            parse_json_logs:
              type: remap
              inputs:
                - kubernetes_logs
                - k3s_journal
                - tetragon_logs
              source: |
                if is_string(.message) {
                  parsed, err = parse_json(.message)
                  if err == null {
                    . = merge(., parsed)
                  }
                }

          sinks:
            greptimedb_sink:
              type: greptimedb_logs
              inputs:
                - parse_json_logs
              endpoint: "http://127.0.99.1:4000"
              table: k3s_logs
              dbname: public
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
# ---------------------------------------------------------------
# GreptimeDB (ログ・メトリクス蓄積)
# ---------------------------------------------------------------
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: greptimedb
  namespace: argocd
spec:
  project: infra
  source:
    repoURL: https://greptimeteam.github.io/greptimedb-operator
    chart: greptimedb-operator
    targetRevision: "0.*"
    helm:
      values: |
        replicas: 1
  destination:
    server: https://kubernetes.default.svc
    namespace: greptimedb
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
# ---------------------------------------------------------------
# Grafana (可視化ダッシュボード)
# ---------------------------------------------------------------
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: grafana
  namespace: argocd
spec:
  project: infra
  source:
    repoURL: https://grafana.github.io/helm-charts
    chart: grafana
    targetRevision: "8.*"
    helm:
      valuesObject:
        ingress:
          enabled: false
        grafana.ini:
          server:
            domain: "grafana.${domain}"
            root_url: "https://grafana.${domain}"
          auth.github:
            enabled: true
            allow_sign_up: true
            scopes: user:email,read:org
            auth_url: https://github.com/login/oauth/authorize
            token_url: https://github.com/login/oauth/access_token
            api_url: https://api.github.com/user
            allowed_organizations: "${gh_organization}"
        envValueFrom:
          GF_AUTH_GITHUB_CLIENT_ID:
            secretKeyRef:
              name: grafana-github-oauth
              key: client_id
          GF_AUTH_GITHUB_CLIENT_SECRET:
            secretKeyRef:
              name: grafana-github-oauth
              key: client_secret
        datasources:
          datasources.yaml:
            apiVersion: 1
            datasources:
              - name: GreptimeDB
                type: mysql
                url: "127.0.99.1:4002"
                database: public
                isDefault: true
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
# ---------------------------------------------------------------
# System Upgrade Controller (k3s 自動アップデート)
# ---------------------------------------------------------------
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: system-upgrade-controller
  namespace: argocd
spec:
  project: infra
  source:
    repoURL: https://rancher.github.io/helm-charts
    chart: system-upgrade-controller
    targetRevision: "104.*"
  destination:
    server: https://kubernetes.default.svc
    namespace: cattle-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
