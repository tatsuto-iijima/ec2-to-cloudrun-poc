# 08. 運用面（ログ・監視・デプロイ手順）の移行コスト評価

対応 Issue: #10（親 Issue #1）
前提: **Web アプリは一人で操作する。複数人での同時使用は禁止。** Cloud Run は `max-instances=1`、`min-instances=0`（docs/07 の推奨）。先行 Issue: #5（基盤・デプロイ）、#8（ステートレス性）、#9（コールドスタート）。

## 1. 結論

**ログ・監視・デプロイ・ロールバックはすべて Cloud Run の標準機能と、このリポジトリのスクリプト（`scripts/build-push.sh`、`scripts/ops.sh`）+ Terraform で手順化できる。EC2 に比べて運用で触るものは減る**（OS・Apache のパッチ、logrotate、ディスク監視、SSH 鍵の管理が無くなる）。実機（2026-09-29）でデプロイ → ログ確認 → 5xx の発生と検索 → 緊急の切り戻し → 解除までを通した（§9）。

- **ログ**: Apache の access / error ログとアプリのログ（`App\Log`）は stdout / stderr に出すだけで Cloud Logging に集まる（#5〜#9 で確認済み）。アプリのログは Apache を経由させない（経由すると日本語が `\xNN` にエスケープされて読めない。§2.1）。`scripts/ops.sh logs` / `errors` / `requests` で読む。保持は既定 30 日。延長とエクスポートはコマンド 1〜2 本（§2）
- **監視**: リクエスト数・レイテンシ・インスタンス数・CPU / メモリ・起動レイテンシは Cloud Run が自動で送る（設定不要）。アラートは「5 分間に 5xx が 1 回以上 → メール」を Terraform に入れた（`alert_email` を書くと有効。§3）
- **デプロイ**: `scripts/build-push.sh`（Cloud Build でビルド → Artifact Registry）→ `terraform apply`。新リビジョンへの切り替えは Cloud Run が行い、無停止（§4）
- **ロールバック**: 緊急時は `scripts/ops.sh rollback <リビジョン>` で数秒で切り戻せる（ビルド不要）。正規の手順は前のイメージタグで `terraform apply`（§5）
- **移行コスト**: 習得に約 3〜4 人日、運用の整備（アラート・ログ保持・手順書）に約 1.5〜2 人日、デプロイの自動化まで含めると約 3 人日（§7）。EC2 の現行運用の列は一般的な EC2 運用を仮置きしており、**実際の運用に合わせた訂正が必要**

## 2. ログ

### 2.1 何がどこに出るか

| 出どころ | 出力先（コンテナ） | Cloud Logging のログ名 | 内容 |
|---|---|---|---|
| Apache の access ログ | stdout（`CustomLog /proc/self/fd/1 combined`） | `run.googleapis.com/stdout` | combined 形式の 1 行 |
| アプリのログ（`app/src/Log.php`） | stderr（`php://stderr` に直接） | `run.googleapis.com/stderr` | `update key=... read=...ms write=...ms put=...ms`（`POST /update` ごと）、`error <例外クラス>: <メッセージ>`（500 のとき）、`wif: ...`（S3 の一時クレデンシャル取得） |
| Apache の error ログ | stderr（`ErrorLog /proc/self/fd/2`） | `run.googleapis.com/stderr` | Apache の起動・停止、PHP 自身の Warning / Fatal |
| Cloud Run のリクエストログ | （Cloud Run が自動で出す） | `run.googleapis.com/requests` | メソッド、URL、ステータス、レイテンシ、応答サイズ、リビジョン。構造化されていて絞り込みやすい |
| gcsfuse・起動プローブ・インスタンスの起動停止 | （Cloud Run が自動で出す） | `run.googleapis.com/varlog/system` | `File system has been successfully mounted.`、`STARTUP HTTP probe succeeded ...` など（docs/07 §5） |

- **ファイルに書かないので logrotate もディスク監視も要らない**。コンテナ内の `/var/log` は使っていない
- Apache の access ログと Cloud Run のリクエストログは**同じリクエストを 2 回記録する**。量は少ない（一人で操作）ので PoC では両方残す。本番で気になる場合は `CustomLog` を外すか、ログの除外フィルタで stdout の access ログを捨てる（リクエストログの方が構造化されていて検索しやすい）
- **アプリのログは Apache を経由させない**。PHP の `error_log()` は mod_php では Apache の error ログに渡され、Apache 2.4 は本文の非 ASCII を `\xNN` にエスケープする（ビルド時の既定で、設定では変えられない）。実機では例外メッセージが `error InvalidArgumentException: \xe6\x9c\xaa\xe7\x9f\xa5... case \xe3\x81\xa7\xe3\x81\x99: alert-test` となり読めなかった（§9 つまずいた点 1）。そこで `App\Log::write()` が `php://stderr`（Apache が起動時に開いたコンテナの stderr を複製した fd）に 1 行で直接書く。行の文言は従来どおりなので、`textPayload:"update key="` などの検索はそのまま使える。Apache の接頭辞（`[php:notice] [pid ...] [client ...]`）は付かない（時刻は Cloud Logging が付ける）。EC2 の現行アプリも `error_log()` なら同じエスケープが起きているはずで、移行時に `error_log()` を置き換えるかは現行の読み方次第
- 起動時の `AH00558: Could not reliably determine the server's fully qualified domain name` は、本 Issue で `ServerName localhost`（`docker/apache/servername.conf`）を入れて出ないようにした。エラーを探すときの雑音を減らすため（docs/03 §6 の持ち越し）

### 2.2 検索

`scripts/ops.sh`（Dev Container 内）:

```bash
scripts/ops.sh logs 50        # stdout + stderr を新しい方から 50 件、時系列で（時刻、リビジョン、本文）
scripts/ops.sh errors 20      # エラーだけ: stderr の "error " / "PHP Fatal" / "PHP Warning" と、5xx を返したリクエスト
scripts/ops.sh requests 20    # リクエストログ（時刻、ステータス、レイテンシ、メソッド、URL）
FRESHNESS=7d scripts/ops.sh errors 100   # 範囲を 7 日に広げる（既定 1d）
```

コンソール（Logs Explorer）で使うクエリの例（`<svc>` はサービス名。`terraform output service_name`）:

```
# アプリのログ全部
resource.type="cloud_run_revision" AND resource.labels.service_name="<svc>"
  AND (logName:"run.googleapis.com%2Fstdout" OR logName:"run.googleapis.com%2Fstderr")

# /update の処理時間（S3 PUT が遅いときの調査）
resource.type="cloud_run_revision" AND resource.labels.service_name="<svc>" AND textPayload:"update key="

# 5xx
resource.type="cloud_run_revision" AND resource.labels.service_name="<svc>"
  AND logName:"run.googleapis.com%2Frequests" AND httpRequest.status>=500

# 起動（コールドスタート）の記録
resource.type="cloud_run_revision" AND resource.labels.service_name="<svc>"
  AND logName:"run.googleapis.com%2Fvarlog%2Fsystem"
```

`gcloud run services logs read <svc> --region asia-northeast1` でも stdout / stderr は読めるが、エラーだけの絞り込みやリクエストログとの突き合わせができないので `ops.sh` は `gcloud logging read` を使う。

### 2.3 保持とエクスポート

- **保持**: ログはプロジェクトの `_Default` ログバケットに入り、**既定 30 日**で消える。取り込みは毎月 50 GiB まで無料で、このアプリの量（1 リクエスト数百バイト × 数件）では無料枠に収まる
- **延長**: 保持日数を変える（30 日を超える分は保存量に応じて課金。単価は #11 で料金表を確認）

  ```bash
  gcloud logging buckets update _Default --location=global --retention-days=90
  ```

- **エクスポート**（監査などで長期に残したい場合）: シンクで Cloud Storage / BigQuery に送る。シンクが作る書き込み用 ID にバケットへの書き込み権限を付ける

  ```bash
  gcloud logging sinks create <svc>-archive storage.googleapis.com/<保存用バケット> \
    --log-filter='resource.type="cloud_run_revision" AND resource.labels.service_name="<svc>"'
  # 出力の writerIdentity に roles/storage.objectCreator を付与
  gcloud storage buckets add-iam-policy-binding gs://<保存用バケット> \
    --member=<writerIdentity> --role=roles/storage.objectCreator
  ```

- 保持の延長とシンクは PoC では作らない（Terraform にも入れていない）。本番で必要なら `google_logging_project_bucket_config` / `google_logging_project_sink` で Terraform に入れる

## 3. 監視

### 3.1 標準メトリクス（設定不要）

Cloud Run がサービスごとに自動で送る。コンソールの「Cloud Run > サービス > 指標」タブで見られ、Cloud Monitoring の Metrics Explorer でも同じ名前で引ける。

| 見たいこと | メトリクス（`run.googleapis.com/...`） | このアプリでの見方 |
|---|---|---|
| リクエスト数・エラー率 | `request_count`（ラベル `response_code_class` = 2xx / 3xx / 4xx / 5xx） | `POST /update` は 303（3xx）。5xx が出たら異常 → §3.2 のアラート |
| レイテンシ | `request_latencies`（分布。p50 / p95 / p99） | `/update` は通常 0.5 秒前後（docs/06）、コールドの初回は約 2.3 秒（docs/07） |
| インスタンス数 | `container/instance_count`（ラベル `state` = active / idle） | 常に 0 か 1（max 1） |
| CPU / メモリ | `container/cpu/utilizations`、`container/memory/utilizations` | 上限（`cpu` / `memory` 変数）に対する使用率。50MB の JSON でもメモリは余裕（docs/06） |
| 起動時間 | `container/startup_latencies` | コールドスタートの傾向（docs/07） |
| 課金対象時間 | `container/billable_instance_time` | #11 の実績値に使える |

EC2 の CloudWatch で見ていた「ディスク使用率」「StatusCheckFailed」に当たるものは無い（ディスクは Cloud Storage、ホストは Google が管理）。

### 3.2 アラート（Terraform。`alert_email` で有効化）

`terraform/gcp/monitoring.tf`。`alert_email` が空なら何も作らない。

| 項目 | 設定 |
|---|---|
| 条件 | `run.googleapis.com/request_count` のうち `response_code_class = "5xx"` を 5 分ごとに合計し、**0 より大きければ発火** |
| 通知 | メール（`google_monitoring_notification_channel`、type `email`） |
| 自動クローズ | 5xx が止まってから 30 分 |
| 本文（documentation） | 確認手順: `scripts/ops.sh errors` → 直前のデプロイが原因なら `scripts/ops.sh rollback` → 本レポート |

一人で操作するアプリなので、閾値は「1 回でも 5xx が出たら知らせる」にした。`POST /update` が失敗する主な原因（S3 の認証・権限、gcsfuse の書き込み失敗、例外）はすべて 500 になるので、この 1 本で拾える。利用者本人が画面でエラーを見ているので、アラートは「後から原因を追うきっかけ」の位置づけ。

入れていないもの（理由）:

- **稼働時間チェック（uptime check）**: 定期的にリクエストが来るとインスタンスが落ちなくなり、min 0 の意味が薄れて課金が増える。使われていない時間の死活は気にしなくてよい（使うときに起動する）
- **レイテンシのアラート**: コールドスタートで 2 秒台が普通に出るので、閾値を決めにくい。必要なら `request_latencies` の p95 > 5 秒などで追加する

### 3.3 アラートの動作確認

5xx をわざと出す。診断経路 `POST /fs-check` に存在しない case を投げると `FsCheck` が例外を投げ、500 が返る（`scripts/ops.sh alert-test`）。`/fs-check` は `fs_check = true` のときしか無いので、確認の間だけ有効にする。

```bash
grep -q '^fs_check' terraform/gcp/terraform.tfvars || echo 'fs_check = true' >> terraform/gcp/terraform.tfvars
terraform -chdir=terraform/gcp apply
scripts/ops.sh alert-test 3       # 500 を 3 回。数分でメールが届く
scripts/ops.sh errors 10          # 5xx と "error InvalidArgumentException: 未知の case です: alert-test" が見える
sed -i '/^fs_check/d' terraform/gcp/terraform.tfvars && terraform -chdir=terraform/gcp apply
```

## 4. デプロイ

### 4.1 手順（確定）

```bash
scripts/build-push.sh                  # Cloud Build で --target runtime をビルドし、Artifact Registry に <コミットの短縮 SHA> のタグで push。
                                       # タグを terraform/gcp/image.auto.tfvars に書き出す
terraform -chdir=terraform/gcp apply   # 新しいイメージで新リビジョンを作り、トラフィックを 100% 移す
scripts/ops.sh revisions               # 新リビジョンに 100%（最新に追従）になっていることを確認
BASE_URL=$(terraform -chdir=terraform/gcp output -raw service_url) DATA_DIR= S3_ENDPOINT= \
  S3_BUCKET=$(terraform -chdir=terraform/aws output -raw bucket_name) scripts/smoke.sh
```

- **無停止**: 新リビジョンの起動プローブ（`GET /health`）が通ってからトラフィックが切り替わる。起動に失敗したリビジョンにはトラフィックが流れず、前のリビジョンのまま（`apply` はエラーで終わる）
- **設定だけの変更**（環境変数、`min_instances`、`cpu` / `memory` など）も `terraform.tfvars` を直して `apply` するだけ。これも新リビジョンになる
- デプロイ直後の最初のリクエストは、新しいインスタンスの初回なので少し遅い（+約 1 秒。docs/06）

### 4.2 `gcloud run deploy` を使わない理由

`gcloud run deploy` やコンソールでの編集は Terraform の state とずれる。次の `terraform apply` が Terraform の定義に戻す（手で変えた環境変数やイメージが消える）ので、**変更は必ず Terraform 経由**にする（線引きは §6）。#7 / #8 で `gcloud run services update --update-env-vars FS_CHECK_RESTART=...` を使ったのは「インスタンスを入れ替える」ための一時的な操作で、次の `apply` で消えることを前提にしていた。

### 4.3 自動化（Cloud Build）

- ビルドは既に Cloud Build（`cloudbuild.yaml`）。手元に Docker が無くてもよく、ビルド環境の差も出ない
- **push をきっかけにした自動デプロイ**（Cloud Build トリガー）は可能。ただし (1) GitHub リポジトリを Cloud Build に接続する（GitHub App の導入）、(2) トリガー内で `terraform apply` を動かすか、`gcloud run services update --image` で Terraform の外から変えるかを決める必要がある。後者は §4.2 のずれを生むので、やるなら前者（ビルド用 SA に Terraform の実行権限と state バケットの権限を付ける）
- 一人で運用し、デプロイの頻度も低い想定なので、**PoC では手動（上の 2 コマンド）で十分**と判断した。自動化の工数は §7 に計上

## 5. ロールバック

### 5.1 正規の手順（Terraform で前のイメージに戻す）

```bash
scripts/ops.sh revisions 20                    # 各リビジョンのイメージタグ（tag=<コミットの短縮 SHA>）が見える
# image.auto.tfvars を 1 つ前のタグに書き換える（build-push.sh が次に上書きするまでこの値のまま）
sed -i 's|:[0-9a-f]*"$|:<前のタグ>"|' terraform/gcp/image.auto.tfvars
terraform -chdir=terraform/gcp apply
```

- Cloud Run はリビジョン作成時にタグをダイジェスト（`app@sha256:...`）に解決して記録する。`ops.sh revisions` は Artifact Registry のタグ一覧と突き合わせてタグを表示する（引けないときはダイジェストの先頭）
- イメージは Artifact Registry に残っているので、再ビルドは要らない。押したタグの一覧は `gcloud artifacts docker images list $(terraform -chdir=terraform/gcp output -raw image_uri) --include-tags`
- Terraform の定義とも一致するので、この後に `apply` しても戻らない

### 5.2 緊急の手順（トラフィックを前のリビジョンへ）

```bash
scripts/ops.sh revisions                       # 1 つ前のリビジョン名を確認
scripts/ops.sh rollback <1 つ前のリビジョン>   # 数秒でトラフィックが 100% そのリビジョンへ（ビルドも apply も不要）
# ... 原因を直す ...
scripts/ops.sh to-latest                       # 固定を解除（最新リビジョンに追従）
scripts/build-push.sh && terraform -chdir=terraform/gcp apply
```

- Cloud Run は過去のリビジョン（イメージと設定の組）を保持しているので、トラフィックを向け直すだけで戻る。`min 0` なので戻した先のリビジョンでは初回がコールドスタートになる（約 2.3 秒）
- **注意: 固定したまま `terraform apply` しない**。`cloudrun.tf` はトラフィックを管理していない（`traffic` ブロックが無い）ので、`apply` しても固定は外れず、新しく作られたリビジョンにトラフィックが流れない（直したつもりの版が使われない）。`scripts/ops.sh revisions` は固定中に警告を出す
- **リビジョンはイメージと設定の組**。戻すと、そのリビジョンを作ったときの環境変数やスケーリング設定も戻る。実機で戻した先の `poc-app-00022-p88` は `fs_check = true` で作ったリビジョンで、切り戻し中は診断経路 `/fs-check` が有効だった（00021〜00023 は同じイメージで、00022 = fs_check 有効化、00023 = 無効化）。`ops.sh revisions` だけでは設定の違いが見えないので、戻す前に `gcloud run revisions describe <REV> --region asia-northeast1` で環境変数を確認する。設定を変えるたびにリビジョンが増える（実機では 1 日で 3 つ）ので、「1 つ前」が直前のイメージとは限らない
- 設定（環境変数など）の変更で壊れた場合も同じ手順で戻せる。ただし **データ（`data.json`、S3 のオブジェクト）は戻らない**。リビジョンを戻すのはアプリと設定だけ

## 6. Terraform 管理の線引き

| 区分 | 対象 | 手段 |
|---|---|---|
| **Terraform で変える**（正） | イメージ（`image.auto.tfvars`）、環境変数（`write_mode`、`fs_check`、`s3_bucket`、`aws_role_arn` など）、スケーリング（`min_instances` / `max_instances` / `concurrency`）、`cpu` / `memory` / `timeout`、起動プローブ、ボリュームマウント、サービスアカウントと IAM、`invoker_member`、バケット、Artifact Registry、アラート（`alert_email`）、AWS 側の S3 バケット・IAM ロール（`terraform/aws`） | `terraform.tfvars` を直して `apply` |
| **手で変えてよい**（一時的。戻す前提） | トラフィックの固定（`ops.sh rollback` → `to-latest`）、インスタンスの入れ替え（`--update-env-vars FS_CHECK_RESTART=...`。次の `apply` で消える）、時間帯を限った `min-instances=1`（次の `apply` で戻る） | `gcloud run services update(-traffic)`。終わったら戻すか `apply` |
| **Terraform の外で管理**（PoC では手動） | ログの保持日数・シンク（§2.3）、Terraform の state バケット（`scripts/tf-init.sh` が作る）、Artifact Registry に溜まる古いイメージの削除 | `gcloud`。本番化するなら Terraform に入れる |
| **手で変えてはいけない** | `gcloud run deploy` / コンソールでのサービス編集（次の `apply` で消える）、`roles/run.invoker` を `allUsers` に付ける（非公開の前提が崩れる）、作業領域バケットの削除、AWS の IAM ロールの信頼ポリシー | — |

## 7. EC2 との差分と移行コスト

### 7.1 差分表

**「EC2（現行）」の列は一般的な EC2 + Apache/PHP の運用を仮置きしたもの**。実際の運用（使っている監視、cron の有無、デプロイ方法など）に合わせて訂正してほしい。

| 項目 | EC2（現行・仮置き） | Cloud Run（本 PoC） | 移行で変わること |
|---|---|---|---|
| サーバーへのログイン | SSH / Session Manager | **無し**（コンテナに入らない） | 調査はログとメトリクスだけで行う。SSH 鍵・踏み台の管理が不要に |
| ログの確認 | `/var/log/httpd/*.log` を `tail` / `grep` | Cloud Logging（`ops.sh logs` / `errors` / `requests`、Logs Explorer） | コマンドが変わる。logrotate・ログ用ディスクの管理が不要に |
| ログの保持 | logrotate の世代数、ディスク容量次第 | 既定 30 日。延長・エクスポートはコマンド 1〜2 本（§2.3） | 保持要件があれば設定を 1 回 |
| 監視 | CloudWatch（CPU、StatusCheckFailed、ディスク） | Cloud Run の標準メトリクス + 5xx アラート（§3） | アラートを作り直す（Terraform 化済み）。ディスク・ホスト監視は不要に |
| デプロイ | SSH して `git pull` / `rsync`、必要なら Apache 再起動 | `build-push.sh` → `terraform apply`。新リビジョンに無停止で切り替え（§4） | コンテナイメージのビルドが入る（Cloud Build で数分） |
| ロールバック | 前のファイルに戻す（`git checkout` など）。手作業 | `ops.sh rollback`（数秒）または前のタグで `apply`（§5） | 速く、確実になる |
| OS・ミドルウェアのパッチ | `yum` / `dnf update`、再起動 | ホスト OS は Google が管理。Apache / PHP はベースイメージ（`php:8.3-apache`）を更新して再ビルド → デプロイ | **定期的な再ビルド**（例: 月 1 回、`build-push.sh` → `apply`）の運用を決める |
| 定期実行（cron） | crontab | 無い。必要なら Cloud Scheduler + HTTP、または Cloud Run jobs | 現行で cron を使っているか要確認（使っていれば移行対象） |
| データのバックアップ | EBS スナップショット / AMI | JSON は Cloud Storage バケット（`/mnt/data`）。S3 に最新版が配布されている | 必要ならバケットのオブジェクトのバージョニングを有効にする（PoC では未設定） |
| スケール・サイズ変更 | インスタンスタイプの変更（停止を伴う） | `cpu` / `memory` を変えて `apply`（無停止）。台数は max 1 で固定 | 停止が要らなくなる |
| 障害からの復旧 | EC2 の自動復旧、または手で再起動 | インスタンスは自動で入れ替わる。状態は `/mnt/data` と S3 にあり、入れ替え後も継続（docs/06） | 手で再起動する場面が無くなる |
| S3 の認証 | インスタンスプロファイル（IAM ロール） | WIF（Cloud Run の SA → IAM ロール。鍵レス、docs/04） | どちらも鍵のローテーションは不要。信頼ポリシーの理解が要る |
| アクセス制御 | セキュリティグループ、IP 制限など | IAM（`roles/run.invoker`）+ ID トークン。ブラウザからは `gcloud run services proxy` 経由 | **利用者の開き方が変わる**。proxy が手間なら IAP などを検討（PoC 範囲外） |
| TLS 証明書・ドメイン | ALB + ACM、または Let's Encrypt の更新 | `*.run.app` の証明書は自動。独自ドメインはドメインマッピング / ロードバランサ（PoC 範囲外） | 証明書の更新作業が無くなる |
| 課金 | 常時起動（時間課金） | リクエスト処理中と起動時だけ（min 0） | #11 で比較 |

### 7.2 移行コストの見積もり（人日）

EC2 と Apache/PHP の運用経験はあり、GCP・コンテナ・Terraform は初めての 1 人が担当する想定。

**習得コスト（約 3〜4 人日）**

| 項目 | 人日 | 内容 |
|---|---|---|
| Cloud Run の概念 | 0.5 | リビジョン、トラフィック、スケール to 0、コールドスタート、Cloud Storage ボリューム |
| Cloud Logging / Monitoring | 0.5 | ログの読み方（`ops.sh`、Logs Explorer）、メトリクス、アラート |
| コンテナイメージ | 0.5〜1 | Dockerfile、ビルド、ベースイメージの更新 |
| Terraform | 1〜1.5 | `plan` / `apply` の読み方、state、本リポジトリの構成。経験があれば 0.5 |
| IAM / WIF | 0.5 | Cloud Run の非公開運用、S3 への鍵レス認証の仕組み（docs/04） |

**運用の整備（約 1.5〜2 人日。デプロイの自動化を含めると約 3 人日）**

| 項目 | 人日 | 内容 |
|---|---|---|
| アラート | 0.25 | `alert_email` を入れて `apply`、動作確認（§3.3）。必要ならレイテンシなどを追加 |
| ログの保持・エクスポート | 0.25〜0.5 | 保持要件の確認、シンクの作成（Terraform 化するなら +0.25） |
| 運用手順書 | 0.5 | 本レポートの §2〜§6 を運用手順書にする。EC2 の手順書との置き換え |
| ベースイメージの定期更新 | 0.25〜0.5 | 頻度と担当を決める（手順は `build-push.sh` → `apply` のまま） |
| cron などの移行 | 0〜1 | 現行で cron を使っていれば Cloud Scheduler へ（要確認） |
| （任意）デプロイの自動化 | 1 | Cloud Build トリガー + GitHub 接続 + Terraform 実行権限（§4.3） |

**継続的な運用の増減**: OS のパッチ適用、logrotate・ディスクの監視、SSH 鍵の管理、証明書の更新が無くなる。代わりにベースイメージの定期再ビルド（1 回数分 + 動作確認）が増える。一人で使う小さなアプリでは、**継続的な運用の手間は減る**見込み。

## 8. この環境での検証結果

2026-09-29、Claude Code の作業環境（GCP の認証情報が無い）。実機の確認は §9。

| 確認内容 | 結果 |
|---|---|
| `terraform fmt -check` / `validate`（`monitoring.tf`、`alert_email`） | OK（google provider 8.2.0） |
| `bash -n scripts/ops.sh` | OK |
| `ops.sh` の各サブコマンド（偽の `gcloud` / `terraform` を PATH に置いて実行） | `logs` / `errors` / `requests` は正しいフィルタで `gcloud logging read --order=desc` を呼び、時系列に並べ直す。`revisions N` は `--limit N` で取り、ダイジェストを Artifact Registry のタグに引き当てて表示する（`tags` が配列でも文字列でも可。引けなければダイジェストの先頭、`terraform output image_uri` の失敗時は Artifact Registry を呼ばない）。トラフィックを表示し、固定中は警告を出す。`rollback` / `to-latest` は `update-traffic` に正しい引数を渡す。`rollback` の引数なしは使い方を出して終了コード 2。`terraform output` の失敗時はメッセージを出して終了コード 1 |
| `ops.sh alert-test`（PHP 内蔵サーバー） | `FS_CHECK=1` で 500 が N 回、stderr に `error InvalidArgumentException: 未知の case です: alert-test`。`FS_CHECK` なしでは 404 を検出して案内を出し、終了コード 1 |
| `scripts/smoke.sh`（PHP 内蔵サーバー + moto。回帰） | ALL PASS |
| `App\Log`（PHP 内蔵サーバー、実機の結果を受けた修正後） | stderr に `error InvalidArgumentException: 未知の case です: alert-test` と `update key=smoke mode=lock ...` が UTF-8 のまま 1 行で出る。mod_php（Apache）で fd 2 に届くことは Docker が無いため未確認 → 実機で確認（§9） |
| Apache の `ServerName`（`docker/apache/servername.conf`） | この環境では Docker が使えないため未確認 → 実機で消えたことを確認（§9） |

## 9. 実機での確認結果

2026-09-29、Dev Container から次を実行（PR #21 のコメント）。

```bash
export BASE_URL=$(terraform -chdir=terraform/gcp output -raw service_url)

# 1. デプロイ（ServerName の変更を含む新イメージ）
scripts/build-push.sh && terraform -chdir=terraform/gcp apply
scripts/ops.sh revisions

# 2. ログ
scripts/ops.sh logs 20        # AH00558 が出ていないこと
scripts/ops.sh requests 10

# 3. アラート（メールの通知チャネルは確認手続き無しで有効になる）
echo 'alert_email = "<自分のアドレス>"' >> terraform/gcp/terraform.tfvars
grep -q '^fs_check' terraform/gcp/terraform.tfvars || echo 'fs_check = true' >> terraform/gcp/terraform.tfvars
terraform -chdir=terraform/gcp apply
scripts/ops.sh alert-test 3   # 数分でメール
scripts/ops.sh errors 10
sed -i '/^fs_check/d' terraform/gcp/terraform.tfvars && terraform -chdir=terraform/gcp apply

# 4. 緊急のロールバックと解除
scripts/ops.sh revisions
scripts/ops.sh rollback <1 つ前のリビジョン>
scripts/ops.sh revisions      # 固定の警告が出る
BASE_URL=$BASE_URL DATA_DIR= S3_ENDPOINT= S3_BUCKET=$(terraform -chdir=terraform/aws output -raw bucket_name) scripts/smoke.sh
scripts/ops.sh to-latest && scripts/ops.sh revisions
```

| 確認内容 | 結果 |
|---|---|
| デプロイ（`build-push.sh` → `apply`） | 新リビジョン `poc-app-00021-5dz` が 100%（最新に追従）。所要時間は（記入欄） |
| AH00558 | 旧イメージの `poc-app-00020-qf8` の起動では 2 行出ていて、新イメージの `00021` 以降の起動では出ない。**`ServerName` で消えた** |
| `ops.sh logs 20` | access ログ（`169.254.169.126 - - [...] "GET / HTTP/1.1" 200 ...`）、Apache の起動・`SIGTERM` での停止がリビジョン名付き・時系列で読める |
| `ops.sh requests 10` | 時刻、ステータス、レイテンシ（`GET /` 0.06〜0.07 秒、`/health` 2ms 前後）、メソッド、URL |
| `ops.sh alert-test 3` | 500 × 3（`fs_check = true` で作った `poc-app-00022-p88`） |
| `ops.sh errors 10` | 5xx のリクエストと `error InvalidArgumentException: ...` の行が交互に出る。**日本語が `\xNN` にエスケープされていた** → `App\Log` で修正（つまずいた点 1） |
| アラートのメール | （記入欄: 届くまでの時間、内容） |
| `ops.sh rollback poc-app-00022-p88` | 数秒で `Traffic: 100% poc-app-00022-p88`。`revisions` は「（固定）」と警告を表示 |
| 切り戻し中の `smoke.sh`（Cloud Run + 実 S3） | ALL PASS |
| `ops.sh to-latest` | `100% LATEST (currently poc-app-00023-rss)`、`revisions` は「（最新に追従）」 |
| `revisions` のイメージ欄 | タグではなく `app@sha256:...`（Cloud Run はダイジェストで記録する）。23 件すべて出て長い → タグの引き当てと件数指定（既定 10）を追加（§5.1） |

### つまずいた点 1: `ops.sh errors` の日本語が `\xe6\x9c\xaa...` になる（2026-09-29）

- **症状**: `error InvalidArgumentException: \xe6\x9c\xaa\xe7\x9f\xa5\xe3\x81\xae case \xe3\x81\xa7\xe3\x81\x99: alert-test`（「未知の case です」）。行頭に `[php:notice] [pid 21:tid 21] [client ...]` が付く
- **原因**: PHP の `error_log()` は mod_php では Apache の `ap_log_rerror` に渡され、Apache 2.4 はエラーログの本文の非 ASCII・制御文字を `\xNN` にエスケープする（ログの改ざん対策。ビルド時の既定で、`ErrorLogFormat` などの設定では変えられない）。ローカルの PHP 内蔵サーバーは Apache を通らないので再現しなかった
- **対処**: `app/src/Log.php` を追加し、アプリのログは `php://stderr` に直接書く（`index.php` と `GoogleWebIdentityCredentialProvider.php` の `error_log()` を置き換え）。`php://stderr` は Apache の子プロセスの fd 2（Apache が起動時に root で開いたコンテナの stderr）を複製するだけなので、`www-data` でも書ける。書けなかったときは `error_log()` に戻す
- **確認（実機）**: `build-push.sh` → `apply` の後、`fs_check = true` で `scripts/ops.sh alert-test 1` → `scripts/ops.sh errors 5` で `未知の case です` が読めること

## 10. #11 / #12 への引き継ぎ

- **#11（コスト）**: 運用面で追加されるのは Cloud Logging（無料枠内の見込み。保持を延長するなら保存量に応じた課金）と Cloud Monitoring のアラート（条件 1 本。料金表で確認）。`container/billable_instance_time` は実績の課金時間の確認に使える。EC2 側の運用工数（パッチ適用など）の削減は金額換算するなら人件費として扱う
- **#12（最終判定）**: 運用面は「移行可能」。条件は、(1) 変更を Terraform 経由に限る運用ルール（§6）、(2) ベースイメージの定期再ビルド、(3) 利用者のアクセス方法の変更（`gcloud run services proxy`、または IAP 等の追加）。移行コストは §7.2（習得 約 3〜4 人日 + 整備 約 1.5〜3 人日）
