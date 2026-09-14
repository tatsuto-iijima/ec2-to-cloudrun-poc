# ec2-to-cloudrun-poc

JSON を更新して AWS S3 にアップロードする Web アプリについて、実行基盤のみを EC2(Apache/PHP) から Google Cloud の Cloud Run へ移行できるかを評価する PoC。
このファイルは、Claude Code が毎回同じ前提・構成・作業ルールで作業するための基準ドキュメント。

## 1. PoC の目的とスコープ

- **目的**: 実行基盤を EC2(Apache/PHP) から Cloud Run（コンテナ実行基盤）+ Cloud Storage ボリューム（gcsfuse）へ移行できるかを評価する
- **スコープ内**: アプリのコンテナ化、Cloud Run での起動、gcsfuse 上での JSON 読み書き、Cloud Run から AWS S3 への認証・アップロード、タイムアウト・ステートレス性、コールドスタート、運用面、概算コスト
- **スコープ外**: S3 から Cloud Storage へのストレージ移行。**データの保存先は AWS S3 のまま変更しない**
- **判断基準**: 親 Issue #1 の検証項目 7 件がすべて成立する場合に「移行可能」と判断する。成立しない項目があれば、回避策の有無とその実装コストを併記して結論を出す

## 2. 前提条件

- **Web アプリは一人で操作する。複数人での同時使用は禁止**（運用ルールとして担保する）
- 上記により、同時書き込みの競合制御は PoC の対象外。Cloud Run は `max-instances=1` を基本構成とし、複数インスタンスに起因する gcsfuse のキャッシュ不整合を構造的に排除する
- 既存アプリのコードはこのリポジトリに含めない。現行の挙動（ローカルファイルシステム上の JSON を読み書きし、S3 へアップロード）を模した**サンプル PHP アプリ**を新規作成して検証する
- 単一利用者でも二重送信（ダブルクリック、再読み込み）で同一インスタンス内に並行リクエストが起こりうる。`concurrency=1` で直列化するか、アプリ側で抑止するかは #8 で決める
- **移行対象データ（#3 で確定。詳細は `docs/01-data-inventory-and-gcsfuse-compat.md`）**: 現行アプリがローカル FS に置くのは **JSON マスタファイルのみ**。ローカルがマスターで S3 は配布先。少数ファイル、各 1MB 未満。書き込みは `LOCK_EX` / `flock` を使う
- **置き場所の決定**: JSON → `/mnt/data`（Cloud Storage ボリューム、`DATA_DIR`）、一時ファイル → `/tmp`（インメモリ。大きなファイルを置かない）、ログ → stdout/stderr、PHP セッションは使わない（必要になったら Cookie ベース）

## 3. 技術選定

| 項目 | 選定 |
|---|---|
| コンテナ | 公式 `php:8.x-apache` ベース。`PORT` 環境変数で Listen。Apache の access/error ログは stdout/stderr へ出力（Cloud Logging に自動収集）。`docker/Dockerfile` は `runtime`（実行用。Cloud Run にデプロイ）と `dev`（Dev Container 用。git / composer 入り）の 2 ステージで、**実行イメージのビルドは `--target runtime` を明示する** |
| 実行基盤 | Cloud Run v2 サービス、第2世代実行環境（Cloud Storage ボリュームに必須）、`max-instances=1` |
| 作業領域 | Cloud Run 標準の Cloud Storage ボリュームマウント（内部で gcsfuse）。コンテナ内で gcsfuse を自前起動しない。マウント先は `/mnt/data`、アプリには `DATA_DIR` 環境変数で渡す |
| IaC | Terraform。`terraform/gcp`（Artifact Registry, Cloud Storage, サービスアカウント, Cloud Run v2）と `terraform/aws`（S3, IAM ロール + OIDC 信頼）に分割 |
| S3 認証（主案） | Workload Identity Federation の逆方向。AWS IAM ロールの信頼ポリシーに `accounts.google.com` の Web Identity を設定し、条件キーで Cloud Run のサービスアカウントに限定。PHP 側はメタデータサーバーから ID トークンを取得し STS `AssumeRoleWithWebIdentity` で一時クレデンシャルを得る。**鍵レス** |
| S3 認証（代替案） | IAM ユーザーのアクセスキーを Secret Manager に格納して Cloud Run に注入。主案が成立しない場合のみ |
| S3 クライアント | AWS SDK for PHP。認証は SDK のクレデンシャルプロバイダに委ね、WIF 実装に差し替えられる構造にする |

### 検証アーキテクチャ

```
[ブラウザ] → Cloud Run サービス (php:8.x-apache コンテナ, 第2世代実行環境, max-instances=1)
                 ├─ /mnt/data  ← Cloud Storage ボリュームマウント (gcsfuse, Cloud Run 管理)
                 │     JSON の読み書き（EC2 ローカルディスク相当）
                 └─ AWS SDK for PHP → AWS S3 へアップロード（保存先は S3 のまま）
                        認証: Cloud Run SA の OIDC ID トークン → STS AssumeRoleWithWebIdentity
```

### サンプルアプリの仕様（最小構成。#4 で実装済み）

- `GET /` : JSON の現在値を表示し、更新フォームを出す
- `POST /update` : `DATA_DIR/DATA_FILE` を読み → 更新（`key`/`value`、`counter`、`updated_at`）→ 書き戻し → S3 へ PUT → `/` へ 303。各段階の所要時間（ms）を `error_log` に 1 行出す
- `GET /healthz` : `{"status":"ok"}` を返す。ファイルにも S3 にも触らない（コールドスタート計測の基準）
- コード: `app/public/index.php`（ルーティング）、`app/src/Config.php`（環境変数）、`app/src/JsonStore.php`（読み書き）、`app/src/S3Uploader.php`（S3 PUT）、`app/templates/index.php`（画面）

| 環境変数 | 既定 | 説明 |
|---|---|---|
| `PORT` | `8080` | Apache の待ち受けポート（Cloud Run のコンテナ契約） |
| `DATA_DIR` | `/mnt/data` | JSON マスタを置くディレクトリ |
| `DATA_FILE` | `data.json` | JSON マスタのファイル名 |
| `WRITE_MODE` | `lock` | `lock` = `file_put_contents` + `LOCK_EX`（現行アプリと同じ）/ `rename` = 一時ファイル + `rename` |
| `S3_BUCKET` | （必須） | アップロード先バケット |
| `S3_KEY_PREFIX` | 空 | オブジェクトキーの接頭辞 |
| `AWS_REGION` | `ap-northeast-1` | リージョン |
| `S3_ENDPOINT` | 未設定 | S3 互換エンドポイント（ローカルの moto）。未設定なら本物の S3 |
| `S3_USE_PATH_STYLE` | `S3_ENDPOINT` があれば `true` | パススタイルのエンドポイントを使うか |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | 未設定 | ローカル（moto）用。Cloud Run では使わず WIF（#6）に置き換える |

## 4. リポジトリ構成

```
CLAUDE.md         このファイル（AI 駆動開発の前提・ルール）
README.md         リポジトリの概要
.devcontainer/    Dev Container（docker-compose.yml の app サービスをベースに AWS CLI / Terraform を同梱）
app/              サンプル PHP アプリ（public/, src/, composer.json）
docker/           Dockerfile（runtime / dev の 2 ステージ）, Apache 設定
docker-compose.yml ローカル起動用
terraform/gcp/    Cloud Run / Cloud Storage / サービスアカウント / Artifact Registry
terraform/aws/    S3 / IAM ロール（Google OIDC 信頼）
scripts/          計測スクリプト（コールドスタート、処理時間、読み書き）
docs/             検証レポート（検証項目ごとに 1 ファイル）+ 最終判定
```

`docs/` のファイル名は `NN-<topic>.md` とし、番号はサブ Issue に対応させる。

| ファイル | サブ Issue |
|---|---|
| `docs/01-data-inventory-and-gcsfuse-compat.md` | #3 移行対象データの棚卸しと gcsfuse 互換性の事前評価 |
| `docs/02-sample-app-and-container.md` | #4 サンプル Apache/PHP アプリの作成とコンテナ化 |
| `docs/03-gcp-infra-and-cloudrun-deploy.md` | #5 Terraform で GCP 基盤構築 + Cloud Run デプロイ |
| `docs/04-s3-auth-from-cloudrun.md` | #6 Cloud Run → AWS S3 の認証・アップロード検証 |
| `docs/05-gcsfuse-json-rw.md` | #7 gcsfuse マウント領域での JSON 読み書き検証 |
| `docs/06-timeout-and-statelessness.md` | #8 リクエストタイムアウト・ステートレス性の検証 |
| `docs/07-cold-start.md` | #9 コールドスタート計測と許容レスポンスタイムの評価 |
| `docs/08-operations.md` | #10 運用面（ログ・監視・デプロイ手順）の移行コスト評価 |
| `docs/09-cost-comparison.md` | #11 概算コスト比較（EC2 常時起動 vs Cloud Run 従量） |
| `docs/10-final-report.md` | #12 最終判定レポート（移行可否・回避策・実装コスト） |

## 5. 作業ルール

### タスク管理

- タスクは GitHub Issue で管理する。親 Issue は #1、サブ Issue は #2〜#12
- 実施順と依存関係: #2 → #3 → #4 → #5 → (#6, #7) → (#8, #9) → #10 → #11 → #12
- 着手時に実装プランを該当 Issue にコメントする。プランの修正もコメントで残す。完了時に結果（成果物、コミット、PR）をコメントする
- 検証結果は `docs/` にレポートとして残す。Issue のコメントには要点とレポートへのリンクを書く
- サブ Issue の本文は次の 5 節で構成する: 目的 / 前提・依存 / 作業内容 / 合否基準 / 成果物。「前提・依存」には先行 Issue の番号と、「Web アプリは一人で操作、複数人同時使用は禁止」を明記する

### ブランチとコミット

- 作業ブランチで開発し、push 後に main 向けの PR を作成する。main への直接 push はしない。マージはユーザーが行う
- コミットメッセージは **Conventional Commits** に従う。件名・本文は**日本語**で書く
  - type: `feat` / `fix` / `docs` / `chore` / `refactor` / `test` / `ci`
  - scope の例: `app`, `docker`, `terraform`, `scripts`, `docs`, `claude-md`
  - 例: `feat(app): JSON 更新と S3 アップロードのエンドポイントを追加`、`docs(claude-md): ローカル起動コマンドを追記`
- コード中のコメントは**日本語**で書く。識別子（変数名、関数名、ファイル名）は英語のままにする
- PR 本文には対応する Issue を `Closes #N` で紐付ける

### CLAUDE.md の更新

- 前提・構成・技術選定・作業ルール・コマンドに変更が生じたら、その作業の中で CLAUDE.md を適宜更新する
- 更新は同じ PR に含め、コミットは `docs(claude-md): ...` とする
- 特に第 6 節（ローカルでの起動・検証コマンド）は、サンプルアプリや Terraform が整い次第、確定した内容に置き換える

### クラウドリソースと認証情報

- クラウドリソースは Terraform で作成し、PoC 終了時に `terraform destroy` で削除する（コスト抑制）
- 認証情報（AWS アクセスキー、サービスアカウント鍵、`terraform.tfvars` の秘匿値、`.env`）はリポジトリにコミットしない。`.gitignore` で除外する
- 長期クレデンシャルをコンテナイメージや環境変数に置かない構成を優先する（S3 認証は WIF 主案）

## 6. ローカルでの起動・検証コマンド

### Dev Container（推奨。手元の Docker + VS Code）

`.devcontainer/` は `docker-compose.yml` の **`app` サービス自体を開発環境にする**構成。Apache が動いたまま `app/` の編集が即反映され、AWS CLI / Terraform / composer / git が入っている。

```bash
# VS Code で「Reopen in Container」。初回は .env が無ければ .env.example からコピーされ、
# compose スタック（app / s3mock / s3mock-init / data-init）が起動し、コンテナ内で composer install が走る

# コンテナ内のターミナルで（BASE_URL / DATA_DIR / S3_* / AWS_* は設定済み）
scripts/smoke.sh                                                        # S3 の確認まで含めて ALL PASS になる
aws --endpoint-url http://s3mock:5000 s3 cp s3://poc-bucket/data.json - # S3 モック上のオブジェクト
curl -s http://localhost:8080/healthz
```

- `WRITE_MODE=rename` への切り替えなど compose の操作（再起動、`down`）はホスト側のターミナルで行う（コンテナ内に Docker CLI は無い）
- ホスト側で `docker compose up` するときは `target: runtime`（実行イメージ）、Dev Container は `target: dev` で同じ Dockerfile をビルドする

### Docker Compose（サンプルアプリ + moto の S3 モック。手元の Docker で実行）

```bash
cp .env.example .env            # 初回のみ。moto 用の既定値が入っている
docker compose up --build -d    # app(8080) / s3mock(ホスト 9000 → コンテナ 5000) / s3mock-init / data-init
docker compose logs -f app      # Apache のログ（update の所要時間もここに出る）

# スモークテスト（healthz → GET / → POST /update → data/data.json の確認）
BASE_URL=http://localhost:8080 DATA_DIR=./data scripts/smoke.sh

# S3 モック上のオブジェクトを確認（aws CLI がある場合。認証情報は任意の値でよい）
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url http://localhost:9000 s3 cp s3://poc-bucket/data.json -

# rename 方式で起動し直す
WRITE_MODE=rename docker compose up -d app

docker compose down             # 後片付け（moto のデータはメモリ上なので一緒に消える）
```

- `./data` はコンテナの `/mnt/data` に bind mount される。`data-init` が `uid 33`（www-data）に chown するので、ホスト側で書き込む場合は権限に注意
- 実 S3 を使う場合は `.env` で `S3_ENDPOINT=`（空）にし、`AWS_*` に実際の認証情報を入れる
- S3 モックに moto（`motoserver/moto`）を使うのは、MinIO の公式イメージ（`minio/minio`, `minio/mc`）が Docker Hub から削除されていて pull できないため（2026-09 確認）
- pull 中に `error getting credentials - err: exit status 1, out: ``` が出たら、`~/.docker/config.json` の `credsStore`（Docker Desktop の認証ヘルパー）が失敗している。使うイメージはすべて公開イメージなので `docker login` は不要。対処は `docs/02` の「つまずいた点 2」

### PHP 内蔵サーバー + moto（Docker が使えない環境。Claude Code の作業環境はこちら）

```bash
cd app && composer install && cd ..
python3 -m venv .venv && .venv/bin/pip install "moto[server]" boto3   # .venv は好きな場所でよい
.venv/bin/moto_server -p 9000 &                                        # S3 互換モック
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test .venv/bin/python -c "import boto3; boto3.client('s3', endpoint_url='http://127.0.0.1:9000', region_name='ap-northeast-1').create_bucket(Bucket='poc-bucket', CreateBucketConfiguration={'LocationConstraint': 'ap-northeast-1'})"

DATA_DIR=$PWD/data S3_BUCKET=poc-bucket S3_ENDPOINT=http://127.0.0.1:9000 \
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=ap-northeast-1 WRITE_MODE=lock \
php -S 127.0.0.1:8080 -t app/public app/public/index.php &

BASE_URL=http://127.0.0.1:8080 DATA_DIR=$PWD/data scripts/smoke.sh
```

- 構文チェック: `for f in app/public/index.php app/templates/index.php app/src/*.php; do php -l "$f"; done`
- サーバーを止めるときは `pkill -f "^php -S"`（`pkill -f "php -S"` は自分のシェルにも一致することがある）

### クラウド（#5 以降で確定次第置き換える）

```bash
cd terraform/gcp && terraform init && terraform plan && terraform apply   # GCP 基盤
cd terraform/aws && terraform init && terraform plan && terraform apply   # AWS 側（#6 以降）
terraform destroy                                                          # 後片付け
```
