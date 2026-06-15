variant: flatcar
version: 1.0.0

# ---------------------------------------------------------------
# ホスト名
# ---------------------------------------------------------------
storage:
  files:
    - path: /etc/hostname
      mode: 0644
      contents:
        inline: "${hostname}"

    # ---------------------------------------------------------------
    # パブリック NIC の静的 IP 設定 (LB ルータネットワーク / eth0)
    # ---------------------------------------------------------------
    - path: /etc/systemd/network/05-public.network
      mode: 0644
      contents:
        inline: |
          [Match]
          Name=eth0

          [Network]
          Address=${lb_ip}/${lb_netmask}
          Gateway=${lb_gateway}
          DNS=8.8.8.8
          DNS=8.8.4.4

    # ---------------------------------------------------------------
    # 内部 NIC の静的 IP 設定 (systemd-networkd)
    # ---------------------------------------------------------------
    - path: /etc/systemd/network/10-internal.network
      mode: 0644
      contents:
        inline: |
          [Match]
          Name=eth1

          [Network]
          Address=${internal_ip}/24

    # ---------------------------------------------------------------
    # k3s インストールスクリプト
    # ---------------------------------------------------------------
    - path: /opt/bin/install-k3s.sh
      mode: 0755
      contents:
        inline: |
          #!/bin/bash
          set -euo pipefail

          K3S_VERSION="v1.30.2+k3s1"
          INSTALL_K3S_VERSION="$K3S_VERSION"

          curl -sfL https://get.k3s.io | \
          %{ if server_is_init ~}
            INSTALL_K3S_VERSION="$K3S_VERSION" \
            INSTALL_K3S_SKIP_SELINUX_RPM=true \
            K3S_TOKEN="${cluster_token}" \
            sh -s - server \
              --cluster-init \
              --tls-san "${hostname}.${domain}" \
              --advertise-address "${internal_ip}" \
              --node-ip "${internal_ip}" \
              --flannel-backend=none \
              --disable-network-policy \
              --disable-kube-proxy \
              --service-node-port-range 80-32767 \
              --disable traefik \
              --disable servicelb \
              --write-kubeconfig-mode 0644
          %{ else ~}
            INSTALL_K3S_VERSION="$K3S_VERSION" \
            INSTALL_K3S_SKIP_SELINUX_RPM=true \
            K3S_TOKEN="${cluster_token}" \
            K3S_URL="https://${init_ip}:6443" \
            sh -s - server \
              --tls-san "${hostname}.${domain}" \
              --advertise-address "${internal_ip}" \
              --node-ip "${internal_ip}" \
              --flannel-backend=none \
              --disable-network-policy \
              --disable-kube-proxy \
              --service-node-port-range 80-32767 \
              --disable traefik \
              --disable servicelb \
              --write-kubeconfig-mode 0644
          %{ endif ~}

    # ---------------------------------------------------------------
    # ArgoCD 初期インストールスクリプト (init サーバのみ実行)
    # ---------------------------------------------------------------
%{ if server_is_init ~}
    - path: /opt/bin/install-argocd.sh
      mode: 0755
      contents:
        inline: |
          #!/bin/bash
          set -euo pipefail

          export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
          export PATH=$PATH:/opt/bin

          # k3s API が応答するまで待機 (CNI 未インストールのためノードは NotReady のまま)
          until k3s kubectl get nodes 2>/dev/null; do
            echo "Waiting for k3s API..."
            sleep 5
          done

          # ---------------------------------------------------------------
          # Cilium CNI インストール (kube-proxy replacement モード)
          # flannel-backend=none で起動しているため, ArgoCD より先にインストールする
          # ---------------------------------------------------------------
          HELM_VERSION="v3.15.0"
          curl -sSL "https://get.helm.sh/helm-$${HELM_VERSION}-linux-amd64.tar.gz" | \
            tar xz -C /tmp
          HELM=/tmp/linux-amd64/helm

          $HELM repo add cilium https://helm.cilium.io/ 2>/dev/null || true
          $HELM repo update cilium

          $HELM upgrade --install cilium cilium/cilium \
            --namespace kube-system \
            --version ">=1.16.0 <1.17.0" \
            --set kubeProxyReplacement=true \
            --set k8sServiceHost="${internal_ip}" \
            --set k8sServicePort=6443 \
            --set operator.replicas=1 \
            --set ipam.mode=kubernetes \
            --set socketLB.enabled=true \
            --set localRedirectPolicy=true \
            --set "hubble.relay.enabled=true" \
            --set "hubble.ui.enabled=true"

          echo "Waiting for Cilium agents to be ready..."
          until k3s kubectl get pods -n kube-system -l k8s-app=cilium 2>/dev/null | grep -q cilium; do
            echo "  Cilium pods not yet created, waiting..."
            sleep 5
          done
          k3s kubectl wait --for=condition=ready pod -l k8s-app=cilium \
            -n kube-system --timeout=300s

          # ---------------------------------------------------------------
          # ArgoCD namespace と インストール
          # ---------------------------------------------------------------
          k3s kubectl create namespace argocd --dry-run=client -o yaml | k3s kubectl apply -f -
          k3s kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

          # ArgoCD が Ready になるまで待機
          echo "Waiting for ArgoCD to be ready..."
          k3s kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

          # ArgoCD App of Apps ブートストラップ
          # bootstrap.yaml と infra-apps.yaml は terraform apply 後に
          # ローカルから kubectl apply -f rendered/ で適用してください。
          echo "ArgoCD installed. Apply rendered/bootstrap.yaml and rendered/infra-apps.yaml from your local machine."

%{ endif ~}

    # ---------------------------------------------------------------
    # SSH 公開鍵
    # ---------------------------------------------------------------
    - path: /home/core/.ssh/authorized_keys
      mode: 0600
      user:
        name: core
      group:
        name: core
      contents:
        inline: |
          ${ssh_public_key}

    # ---------------------------------------------------------------
    # containerd ログを JSON で出力するための設定
    # ---------------------------------------------------------------
    - path: /etc/containerd/config.toml
      mode: 0644
      contents:
        inline: |
          version = 2
          [plugins."io.containerd.grpc.v1.cri".containerd]
            snapshotter = "overlayfs"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
            runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true

# ---------------------------------------------------------------
# systemd ユニット
# ---------------------------------------------------------------
systemd:
  units:
    # k3s インストール → 起動
    - name: install-k3s.service
      enabled: true
      contents: |
        [Unit]
        Description=Install and start k3s
        After=network-online.target
        Wants=network-online.target
        ConditionPathExists=!/opt/bin/k3s

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/opt/bin/install-k3s.sh
        StandardOutput=journal
        StandardError=journal

        [Install]
        WantedBy=multi-user.target

%{ if server_is_init ~}
    # ArgoCD インストール (init サーバのみ)
    - name: install-argocd.service
      enabled: true
      contents: |
        [Unit]
        Description=Install ArgoCD and supporting components
        After=install-k3s.service
        Requires=install-k3s.service

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/opt/bin/install-argocd.sh
        StandardOutput=journal
        StandardError=journal

        [Install]
        WantedBy=multi-user.target
%{ endif ~}

    # Flatcar 自動更新 (OS の自動アップデートを有効化)
    - name: update-engine.service
      enabled: true
    - name: locksmithd.service
      enabled: true

%{ if auto_shutdown_at_utc ~}
    # 自動シャットダウン (${auto_shutdown_at_utc} UTC)
    - name: auto-shutdown.service
      contents: |
        [Unit]
        Description=Automatic shutdown for cost saving
        After=network-online.target

        [Service]
        Type=oneshot
        ExecStart=/usr/bin/halt -p

    - name: auto-shutdown.timer
      enabled: true
      contents: |
        [Unit]
        Description=Trigger automatic shutdown at ${auto_shutdown_at_utc} UTC daily

        [Timer]
        OnCalendar=*-*-* ${auto_shutdown_at_utc} UTC
        Persistent=true

        [Install]
        WantedBy=timers.target
%{ endif ~}

# ---------------------------------------------------------------
# ユーザ設定
# ---------------------------------------------------------------
passwd:
  users:
    - name: core
      groups:
        - sudo
        - docker
      ssh_authorized_keys:
        - "${ssh_public_key}"
