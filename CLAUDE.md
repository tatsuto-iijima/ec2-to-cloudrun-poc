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
| コンテナ | 公式 `php:8.x-apache` ベース。`PORT` 環境変数で Listen。Apache の access/error ログは stdout/stderr へ出力（Cloud Logging に自動収集） |
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

### サンプルアプリの仕様（最小構成）

- `GET /` : JSON の現在値を表示し、更新フォームを出す
- `POST /update` : `DATA_DIR/*.json` を読み → 更新 → 書き戻し（tmp + rename）→ S3 へ PUT
- `GET /healthz` : 200 を返す
- `DATA_DIR`、S3 バケット名、リージョンは環境変数で設定する

## 4. リポジトリ構成

```
CLAUDE.md         このファイル（AI 駆動開発の前提・ルール）
README.md         リポジトリの概要
app/              サンプル PHP アプリ（public/, src/, composer.json）
docker/           Dockerfile, Apache 設定
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

**#4（サンプルアプリの作成とコンテナ化）以降で確定次第、この節を実際のコマンドに置き換える。** 以下は想定。

```bash
# ローカル起動（サンプルアプリ + 作業領域のバインドマウント。S3 は実バケット、なければ MinIO）
docker compose up --build

# 動作確認
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/
curl -s -X POST http://localhost:8080/update -d 'key=value'

# GCP 基盤（#5 以降）
cd terraform/gcp && terraform init && terraform plan && terraform apply

# AWS 側（#6 以降）
cd terraform/aws && terraform init && terraform plan && terraform apply

# 後片付け
terraform destroy
```
