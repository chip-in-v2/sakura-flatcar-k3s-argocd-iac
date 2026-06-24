# ansible の導入

setup.py が肥大化したので、 ansible に書き換えます。

## devcontainer.json

features で python の代わりに ansible をインストールしてください。

## インベントリ

ansible/inventory ディレクトリに sv1, sv2, sv3, localhost の4個のサーバのインベントリを作成してください。 sv1, sv2, sv3 の共通項目については servers というグループを構成して group_vars で管理してください。

## setup.py のサブコマンド

サブコマンドごとに対応する playbook を作成してください。

|サブコマンド|playbook パス|
|--|--|
|build-infra|ansible/playbooks/build-infra.yml|
|boot|ansible/playbooks/boot.yml|
|install-charts|ansible/playbooks/install-infra-apps.yml|
|push-infra-apps|ansible/playbooks/push-infra-apps.yml|
|allow-ssh|ansible/playbooks/allow-ssh.yml|
|deny-ssh|ansible/playbooks/deny-ssh.yml|
|destroy|ansible/playbooks/destroy.yml|

このほかに以下を追加で作成してください。

|playbookパス|説明|
|--|--|
|ansible/playbooks/build-all.yml|build-infra, boot, install-infra-apps を順に実行する|
|ansible/playbooks/shutdown-servers.yml|サーバをすべてシャットダウンする|
|ansible/playbooks/startup-servers.yml|サーバをすべて起動する|

post-create.sh で ~/.bashrc に各playbook の basename から拡張子を取り除いたものの alias を作成して、コマンドとして ansible-playbook を呼び出せるようにしてください。

実装に際しては ansilble/roles の下に role を作成してモジュール化してください。
さくらのクラウドの API を呼んでいるものについては ansible/lib の下に ansible モジュールを python で作成してそれを呼び出すようにしてください。モジュールのプリフィックスは ops-frontier.provider.sakura としてください。

## tetragon

community.general.terraform モジュールを使って ansible から呼び出すようにしてください。

## argocd/*/*.tpl

テンプレートの展開は Jinja2 によるものに変更してください。

## setup.py ファイル

最終的に削除しますので、参照しないようにしてください。