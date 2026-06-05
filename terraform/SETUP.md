# セットアップツール

## 概要
大幅に方針を変更することにしました。
まず、サーバにはブートストラップ用の Ubuntu とターゲットである Flatcar Container Linux の両方をインストールし、ディスクの順序を APIで入れ替えることでどちらを起動するかを選択できるようにします。このとき、グローバルIPとSSH公開鍵は同じものが使用されるようにします。これにより、サーバを再構築せずに Flatcar Container Linux の ignition をデバッグできるようにします。ブートストラップディスクのサイズは 20GB、ターゲットディスクのサイズは40GBとします。

## 完成後削除予定スクリプト

このスクリプトの開発が完了した際には試行錯誤で作成した以下のファイルは削除します。このため、これらを使用してはなりません。

- scripts/*.sh
- .github/workflows/create-flatcar-archive.yml
- ssh-config.sh
- packer/*
- build.py

ただし、flatcar-install コマンドがudevadm settle でフリーズする現象があり、build.py で入れた以下のパッチは有効かもしれない。
```
sudo sed -i 's/udevadm settle/udevadm settle --timeout=30/g' /usr/sbin/flatcar-install
```

## コマンド

セットアップツールは setup.py という python3 で記述されたスクリプトであり、以下のサブコマンドを受け付けます。

|サブコマンド|概要|
|--|--|
|build-infra|ネットワークとサーバを terraform で構築します|
|boot|Flatcar Linux をインストールして起動します|
|deny-ssh|パケットフィルタでsshのアクセスを禁止します|
|destroy|ネットワークとサーバを terraform で削除します|

## build-infra サブコマンド

```./setup.py build-infra``` で起動します。 ```cd terraform && terraform apply``` を実行します。
ssh でログインできるようにパケットフィルタに ssh の inbound と outbound を追加します。inbound については実行中の開発環境のグローバルIPに限定するように設定します。~/.ssh に config を設定し、サーバ名で ssh できるようにします。flatcar-install コマンドをインストールしておきます。

現行からの変更点は以下です。
- 起動するサーバは flatcar の ISO イメージから起動するのではなく ubuntu のパブリックアーカイブから起動し、グローバルIP、ssh公開鍵をディスク修正で設定
- 未フォーマットのディスクをターゲットディスクとして追加し、 /dev/sdb として見えるように設定。

##　 boot サブコマンド

```./setup.py boot``` で起動します。サーバごとに以下の動作を実行します。

1. ssh で ubuntu で起動していることを確認します。もし、flatcar linux で起動している場合は、以下の手順でブートディスクを入れ替えます。
   1. サーバをシャットダウンします
   2. API を呼び出して、ディスクの順序を入れ替え、ブートストラップディスクから起動し、ターゲットディスクが /dev/sdb に見えるようにします
   3. サーバを起動します
2. ubuntu に付与されているIPアドレスやssh公開鍵を調べ、それが埋め込まれた Ignition ファイルを butane のテンプレートから生成します。
3. ssh で flatcar-install コマンドを実行して、 /dev/vdb に Ignition ファイルを含めてインストールします。
4. サーバをシャットダウンします
5. API を呼び出して、ディスクの順序を入れ替え、ターゲットディスクから起動するようにします。ブートストラップディスクは /dev/sdb に見えるようにしておきます。
6. サーバを起動します。

## deny-ssh

```./setup.py deny-ssh``` で起動します。build-infra で設定したパケットフィルタのエントリを削除します。

## destroy サブコマンド

```./setup.py destroy``` で起動します。 ```cd terraform && terraform destroy``` を実行します。