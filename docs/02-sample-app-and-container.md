# 02. サンプル Apache/PHP アプリの作成とコンテナ化（ローカル起動）

対応 Issue: #4（親 Issue #1）
前提: **Web アプリは一人で操作する。複数人での同時使用は禁止。**

## 1. 結論

- 現行アプリの「ローカル FS 上の JSON を読み書きし、S3 へアップロード」を再現するサンプル PHP アプリを `app/` に作成し、`php:8.3-apache` ベースの Dockerfile と、MinIO を同梱した `docker-compose.yml` を用意した
- **アプリ本体は PHP 内蔵サーバー + moto（S3 互換モック）で検証済み**。`WRITE_MODE=lock` / `rename` の両方でスモークテストが全項目 PASS し、S3 オブジェクトの内容がローカル JSON と一致した
- **Docker イメージのビルドと `docker compose up` は、Claude Code の作業環境に Docker デーモンが無いため未検証**。手元の Docker で「4. 手元での確認手順」を実施して結果を本レポートに追記する
- Issue #4 の合否基準「`POST /update` で JSON が更新され、S3 にオブジェクトが PUT される」「`/healthz` が 200」は、内蔵サーバー + moto の範囲で満たしている

## 2. 構成

```
app/
  composer.json / composer.lock   aws/aws-sdk-php ^3.300、PSR-4 App\ → src/。platform.php=8.3.0 で解決
  public/index.php                フロントコントローラ。GET / , POST /update, GET /healthz。それ以外は 404
  src/Config.php                  環境変数の読み取りと既定値。WRITE_MODE の検証
  src/JsonStore.php               DATA_DIR/DATA_FILE の読み書き。lock（file_put_contents + LOCK_EX）/ rename（一時ファイル + rename）
  src/S3Uploader.php              AWS SDK S3Client で PUT。S3_ENDPOINT があればパススタイル。認証は SDK の既定チェーン
  templates/index.php             現在値の表と更新フォーム。フッターに WRITE_MODE / DATA_DIR / S3 先を表示
docker/
  Dockerfile                      multi-stage: composer:2 で vendor 生成 → php:8.3-apache。ENV PORT=8080, DATA_DIR=/mnt/data, WRITE_MODE=lock
  apache/ports.conf               Listen ${PORT}
  apache/000-default.conf         DocumentRoot /var/www/html/public、FallbackResource /index.php、ログは /proc/self/fd/1,2
docker-compose.yml                app + minio + minio-init（バケット作成）+ data-init（./data を uid 33 に chown）
.env.example                      MinIO 用の既定値。実 S3 は S3_ENDPOINT= を空にして AWS_* を差し替える
.gitignore                        vendor/, .env, data/*.json, Terraform の state / tfvars, 鍵ファイル
data/.gitkeep                     ローカルの DATA_DIR（bind mount 先）
scripts/smoke.sh                  healthz → GET / → POST /update → 表示確認 → data/data.json 確認 →（aws CLI があれば）S3 確認
```

### 現行アプリとの対応

| 現行（EC2） | サンプルアプリ（コンテナ） |
|---|---|
| Apache + PHP | `php:8.3-apache`（Apache prefork + mod_php） |
| ローカルディスクの JSON | `DATA_DIR`（既定 `/mnt/data`。Cloud Run では Cloud Storage ボリューム） |
| `file_put_contents` + `LOCK_EX` | `WRITE_MODE=lock`（既定）。`rename` 方式も切り替え可能 |
| S3 へアップロード | AWS SDK for PHP `putObject`。認証は SDK の既定チェーン（#6 で WIF に差し替え） |
| Apache のログファイル | stdout / stderr（Cloud Logging に自動収集） |

### 設計上の決定

- **`GET /healthz` はファイルにも S3 にも触らない**。#9 のコールドスタート計測で「マウント先アクセスなし」の基準にする
- **`POST /update` は read / write / put の所要時間を `error_log` に 1 行で出す**。#7 #8 の計測はこのログを集計する
  ```
  update key=smoke mode=lock read=0.0ms write=0.3ms put=133.2ms target=s3://poc-bucket/data.json etag="509cb2..."
  ```
- **S3 へ PUT する内容は書き戻し後のファイルを読み直したもの**。gcsfuse 上で「書いた内容がそのまま読めるか」も同時に確認できる
- **認証情報を `S3Client` に渡さない**。`S3Uploader` のコンストラクタは `callable $credentials` を受け取れるので、#6 で WIF のクレデンシャルプロバイダを注入する
- **`JsonStore::read()` はファイルが無くても書かない**（初期データを返すだけ）。ファイルは最初の `POST /update` で作られる
- **一時ファイルは同じディレクトリに置く**（`data.json.<hex>.tmp`）。gcsfuse でディレクトリをまたぐ rename を避けるため（docs/01 参照）
- 入力検証: `key` は `[A-Za-z0-9_.-]{1,64}`、`value` は 10000 バイトまで。失敗時は `/?error=` へ 303

## 3. 検証結果（PHP 内蔵サーバー + moto）

実施環境: Claude Code の作業環境（PHP 8.4.19 CLI、moto 5 系、Docker デーモン無し）。2026-09-13。

| # | 確認内容 | 結果 |
|---|---|---|
| 1 | `composer install` が通り `composer.lock` が生成される（aws/aws-sdk-php 3.395.0） | OK |
| 2 | `php -l` で全 PHP ファイルの構文チェック | OK（5 ファイル） |
| 3 | `JsonStore` を直接呼び、lock / rename の両方式で 新規作成 → 上書き → 再読込 が成立し、一時ファイルが残らない。不正な `WRITE_MODE` は例外 | OK |
| 4 | `GET /healthz` → 200 `{"status":"ok"}` | OK |
| 5 | `GET /` → 200、`GET /nope` → 404、`POST /update` で不正な key → 303 `/?error=...` | OK |
| 6 | `scripts/smoke.sh`（`WRITE_MODE=lock`）: healthz / index / update 303 / 表示 / `data/data.json` の 5 項目 | **ALL PASS** |
| 7 | moto 上の `s3://poc-bucket/data.json` の内容が `data/data.json` と一致、`Content-Type: application/json; charset=utf-8` | OK（MATCH） |
| 8 | `scripts/smoke.sh`（`WRITE_MODE=rename`）と S3 一致 | **ALL PASS** / MATCH |
| 9 | 存在しないバケットへの PUT → 500 とメッセージ、`error_log` に例外クラスとメッセージ | OK |

所要時間ログ（参考。ローカル FS + moto）: `read=0.0ms write=0.3ms put=120〜133ms`

## 4. 手元での確認手順（Docker。未実施）

```bash
cp .env.example .env
docker compose up --build -d
docker compose ps                       # app / minio が Up、minio-init / data-init が Exited 0
BASE_URL=http://localhost:8080 DATA_DIR=./data scripts/smoke.sh
docker compose logs app | grep "update key="
# MinIO コンソール http://localhost:9001（minioadmin / minioadmin）で poc-bucket/data.json を確認

WRITE_MODE=rename docker compose up -d app   # rename 方式でも smoke.sh を通す
docker compose down -v
```

期待結果: `scripts/smoke.sh` が `ALL PASS`、MinIO 上の `data.json` が `./data/data.json` と一致、`docker compose logs app` に `update key=smoke mode=lock ...` の行が出る。

確認できたら、結果（PASS / 所要時間ログ / つまずいた点）を本レポートの「5. Docker での確認結果」に追記する。

## 5. Docker での確認結果

（未実施。手元で確認後に追記）

## 6. #5（Cloud Run デプロイ）へ引き継ぐ事項

- **書き込み権限**: Apache は `www-data`（uid 33）で動く。Cloud Run の Cloud Storage ボリュームに `www-data` が書けるか（gcsfuse の `uid` / `gid` マウントオプションが必要か）を #5 で確認する。ローカルでは `data-init` で bind mount 先を chown している
- **`PORT`**: Apache は `Listen ${PORT}` で起動する。Cloud Run が渡す `PORT`（既定 8080）にそのまま従う
- **ログ**: access / error ログは stdout / stderr。Cloud Logging での見え方は #10 で評価
- **イメージサイズ**: `php:8.3-apache` + vendor（AWS SDK）で 500MB 前後になる見込み。コールドスタートへの影響は #9 で計測
- **環境変数**: `DATA_DIR=/mnt/data`、`S3_BUCKET`、`AWS_REGION` を Cloud Run の環境変数で渡す。`AWS_ACCESS_KEY_ID` 等は渡さない（#6 で WIF）
