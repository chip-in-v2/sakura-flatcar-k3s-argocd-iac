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
          Gateway=
          DNS=

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
            K3S_TOKEN="${cluster_token}" \
            sh -s - server \
              --cluster-init \
              --tls-san "${hostname}.${domain}" \
              --advertise-address "${internal_ip}" \
              --node-ip "${internal_ip}" \
              --flannel-iface eth1 \
              --disable traefik \
              --disable servicelb \
              --write-kubeconfig-mode 0644
          %{ else ~}
            INSTALL_K3S_VERSION="$K3S_VERSION" \
            K3S_TOKEN="${cluster_token}" \
            K3S_URL="https://${init_ip}:6443" \
            sh -s - server \
              --tls-san "${hostname}.${domain}" \
              --advertise-address "${internal_ip}" \
              --node-ip "${internal_ip}" \
              --flannel-iface eth1 \
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

          # k3s が Ready になるまで待機
          until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
            echo "Waiting for k3s cluster..."
            sleep 5
          done

          # ArgoCD namespace と インストール
          kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
          kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

          # cert-manager インストール
          kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

          # Traefik (Ingress Controller) インストール
          kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -
          helm repo add traefik https://helm.traefik.io/traefik
          helm upgrade --install traefik traefik/traefik \
            --namespace traefik \
            --set service.type=NodePort \
            --set ports.web.nodePort=80 \
            --set ports.websecure.nodePort=443 \
            --wait

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
