# 02. サンプル Apache/PHP アプリの作成とコンテナ化（ローカル起動）

対応 Issue: #4（親 Issue #1）
前提: **Web アプリは一人で操作する。複数人での同時使用は禁止。**

## 1. 結論

- 現行アプリの「ローカル FS 上の JSON を読み書きし、S3 へアップロード」を再現するサンプル PHP アプリを `app/` に作成し、`php:8.3-apache` ベースの Dockerfile と、S3 モック（moto）を同梱した `docker-compose.yml` を用意した
- 当初は S3 モックに MinIO を使う計画だったが、`minio/minio` と `minio/mc` が Docker Hub から削除されていて pull できなかったため（5. 参照）、Claude Code の作業環境での検証にも使っている moto（`motoserver/moto`）に置き換えた
- **アプリ本体は PHP 内蔵サーバー + moto（S3 互換モック）で検証済み**。`WRITE_MODE=lock` / `rename` の両方でスモークテストが全項目 PASS し、S3 オブジェクトの内容がローカル JSON と一致した
- **Docker（実行イメージ）でも確認済み**。Claude Code の作業環境には Docker デーモンが無いため、ユーザーの手元の Dev Container（`app` サービス、`target: dev`）で「4. 手元での確認手順」を実施し、`scripts/smoke.sh` が S3 確認まで含めて 6 項目 ALL PASS（「5. Docker での確認結果」参照）
- Issue #4 の合否基準「`POST /update` で JSON が更新され、S3 にオブジェクトが PUT される」「`/healthz` が 200」は、内蔵サーバー + moto と Docker の両方で満たしている

## 2. 構成

```
app/
  composer.json / composer.lock   aws/aws-sdk-php ^3.300、PSR-4 App\ → src/。platform.php=8.3.0 で解決
  public/index.php                フロントコントローラ。GET / , POST /update, GET /healthz。それ以外は 404
  src/Config.php                  環境変数の読み取りと既定値。WRITE_MODE の検証
  src/JsonStore.php               DATA_DIR/DATA_FILE の読み書き。lock（file_put_contents + LOCK_EX）/ rename（一時ファイル + rename）
  src/S3Uploader.php              AWS SDK S3Client で PUT。S3_ENDPOINT があればパススタイル。認証は SDK の既定チェーン
  templates/index.php             現在値の表と更新フォーム。フッターに WRITE_MODE / DATA_DIR / S3 先を表示
.devcontainer/
  devcontainer.json               docker-compose.yml の app サービスをベースにした Dev Container。features で AWS CLI / Terraform / vscode ユーザーを追加
  docker-compose.yml              app への上書き（build.target=dev、/workspace と app/ の bind mount）
docker/
  Dockerfile                      multi-stage: composer:2 で vendor 生成 → runtime（php:8.3-apache。ENV PORT=8080, DATA_DIR=/mnt/data, WRITE_MODE=lock）→ dev（runtime + git / composer）
  apache/ports.conf               Listen ${PORT}
  apache/000-default.conf         DocumentRoot /var/www/html/public、FallbackResource /index.php、ログは /proc/self/fd/1,2
docker-compose.yml                app + s3mock（motoserver/moto）+ s3mock-init（amazon/aws-cli でバケット作成）+ data-init（./data を uid 33 に chown）
.env.example                      moto 用の既定値（認証情報は任意の文字列）。実 S3 は S3_ENDPOINT= を空にして AWS_* を差し替える
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

## 4. 手元での確認手順（Docker）

### Dev Container で実施する場合（推奨）

VS Code で「Reopen in Container」する。`.env` が無ければ `.env.example` からコピーされ、compose スタック（app / s3mock / s3mock-init / data-init）が起動して、コンテナ内で `composer install` が走る。コンテナ内のターミナルで:

```bash
aws --version                                                             # AWS CLI が入っていること
scripts/smoke.sh                                                          # BASE_URL / DATA_DIR / S3_* / AWS_* は設定済み。S3 確認まで ALL PASS
aws --endpoint-url http://s3mock:5000 s3 cp s3://poc-bucket/data.json -   # S3 モック上のオブジェクト
```

`WRITE_MODE=rename` で確認するときは、ホスト側で `WRITE_MODE=rename docker compose -f docker-compose.yml -f .devcontainer/docker-compose.yml up -d app` してから再度 `scripts/smoke.sh`。

### ホストで直接実施する場合

```bash
cp .env.example .env
docker compose up --build -d
docker compose ps                       # app / s3mock が Up、s3mock-init / data-init が Exited 0
BASE_URL=http://localhost:8080 DATA_DIR=./data scripts/smoke.sh
docker compose logs app | grep "update key="
# S3 モック上のオブジェクトを確認（aws CLI がある場合。認証情報は任意の値でよい）
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url http://localhost:9000 s3 cp s3://poc-bucket/data.json -

WRITE_MODE=rename docker compose up -d app   # rename 方式でも smoke.sh を通す
docker compose down
```

期待結果: `scripts/smoke.sh` が `ALL PASS`、moto 上の `data.json` が `./data/data.json` と一致、`docker compose logs app` に `update key=smoke mode=lock ...` の行が出る。

確認できたら、結果（PASS / 所要時間ログ / つまずいた点）を本レポートの「5. Docker での確認結果」に追記する。

## 5. Docker での確認結果

### つまずいた点 1: MinIO のイメージが pull できない（2026-09-14）

`docker compose up --build -d` で次のエラーになった。

```
✘ Image minio/mc:latest    Error pull access denied for minio/mc, repository does not exist or may require 'docker login'
```

Docker Hub の API で確認したところ、`minio/minio` と `minio/mc` はリポジトリ自体が存在しない（404）。`bitnami/minio` もタグが無い。
対処として S3 モックを moto（`motoserver/moto:5.2.3`。Claude Code の作業環境での検証にも使用）に置き換え、バケット作成は `amazon/aws-cli` で行うようにした。moto のデータはメモリ上なので、`docker compose down` で消える。

### つまずいた点 2: `error getting credentials - err: exit status 1, out: ``（2026-09-14）

moto への置き換え後、`alpine:3` / `motoserver/moto:5.2.3` / `amazon/aws-cli:2.36.44` の pull が進行中（aws-cli は 89MB / 140MB まで到達）に次で中断した。

```
error getting credentials - err: exit status 1, out: ``
```

これは Docker CLI が `~/.docker/config.json` の `credsStore` / `credHelpers` に指定された**認証ヘルパー**（Docker Desktop の `docker-credential-desktop`、Linux の `pass` / `secretservice` など）を呼び出して失敗したときのメッセージ。compose の内容やイメージの存在とは無関係で、リポジトリ側の修正は不要。この PoC で使うイメージはすべて公開イメージなので `docker login` も不要。

確認と対処（ユーザーの手元で実施）:

```bash
cat ~/.docker/config.json                                          # "credsStore": "desktop" などが入っているはず
echo https://index.docker.io/v1/ | docker-credential-desktop get   # ヘルパー単体で失敗すればこれが原因（WSL では docker-credential-desktop.exe）
```

| 環境 | 典型的な原因 | 対処 |
|---|---|---|
| macOS Docker Desktop | キーチェーンがロック、Docker Desktop が完全に起動していない | Docker Desktop を再起動（必要なら `security unlock-keychain`）して再実行 |
| Windows + WSL2 | WSL 側の PATH に `docker-credential-desktop.exe` が無い | `export PATH="$PATH:/mnt/c/Program Files/Docker/Docker/resources/bin"` |
| Linux | `credsStore` が `pass` / `secretservice` で未初期化 | `pass init` するか、下の共通対処 |
| 共通 | 公開イメージしか使わない | `~/.docker/config.json` をバックアップし、`"credsStore"` 行を削除して再実行 |

### つまずいた点 3: ホストに `aws` が無い（2026-09-14）

S3 モック上のオブジェクト確認で `Command 'aws' not found`。ホストに AWS CLI を入れる代わりに **Dev Container** を追加した。

- `docker-compose.yml` の `app` サービス自体を Dev Container にする（`dockerComposeFile` + `service: app`）。開発環境 = 実行イメージ（`php:8.3-apache`）で、Apache が動いたまま `app/` の編集が即反映される
- `docker/Dockerfile` に `dev` ステージ（`runtime` + git / unzip / composer）を追加。実行イメージ `runtime` には含めない。最終ステージが `dev` になるため、`docker-compose.yml` と #5 の Cloud Run 用ビルドでは `--target runtime` を明示する
- AWS CLI / Terraform は Dev Container の features で載せる。gcloud CLI は Dockerfile の `dev` ステージで入れる（#5。コミュニティ feature が Debian trixie で失敗するため。`docs/03` 参照）。作業ユーザーは `common-utils` feature で作る `vscode`（uid 1000）。Apache の worker は従来どおり `www-data`
- `app/` を `/var/www/html` に bind mount するとイメージ内の `vendor/` が隠れるため、`postCreateCommand` で `composer install`（ホストの `app/vendor` に生成。`.gitignore` 済み）
- コンテナ内に Docker CLI は無いので、compose の操作（`WRITE_MODE` の切り替え等）はホスト側で行う

### スモークテストの結果（2026-09-14、Dev Container 内で実施）

実施環境: Ubuntu ホスト + Docker、VS Code の Dev Container（`app` サービス、`target: dev`）。`WRITE_MODE=lock`。

```
$ scripts/smoke.sh
PASS: GET /healthz -> 200
PASS: GET / -> 200
PASS: POST /update -> 303
PASS: GET / に更新後の値が表示される
PASS: /mnt/data/data.json に書かれている
PASS: s3://poc-bucket/data.json に同じ内容がある
ALL PASS
```

```
$ aws --endpoint-url http://s3mock:5000 s3 cp s3://poc-bucket/data.json -
{
    "message": "EC2 to Cloud Run PoC",
    "counter": 2,
    "smoke": "ok-1789359869",
    "updated_at": "2026-09-14T04:24:29+00:00"
}
```

| 確認内容 | 結果 |
|---|---|
| Dev Container の起動（compose スタック app / s3mock / s3mock-init / data-init、`composer install`） | OK |
| AWS CLI（features で導入） | OK |
| `scripts/smoke.sh`（healthz / index / update / 表示 / `/mnt/data/data.json` / S3 オブジェクト） | **ALL PASS**（6 項目） |
| S3 モック上のオブジェクトの内容 | `counter: 2`、更新値と `updated_at` が入っている |
| `WRITE_MODE=rename` | Docker 上では未実施（内蔵サーバーでは PASS 済み。#7 の gcsfuse 検証で両方式を改めて確認する） |

これで Issue #4 の合否基準は実行イメージ（`php:8.3-apache`）上でも満たした。

## 6. #5（Cloud Run デプロイ）へ引き継ぐ事項

- **書き込み権限**: Apache は `www-data`（uid 33）で動く。Cloud Run の Cloud Storage ボリュームに `www-data` が書けるか（gcsfuse の `uid` / `gid` マウントオプションが必要か）を #5 で確認する。ローカルでは `data-init` で bind mount 先を chown している
- **`PORT`**: Apache は `Listen ${PORT}` で起動する。Cloud Run が渡す `PORT`（既定 8080）にそのまま従う
- **ログ**: access / error ログは stdout / stderr。Cloud Logging での見え方は #10 で評価
- **イメージサイズ**: `php:8.3-apache` + vendor（AWS SDK）で 500MB 前後になる見込み。コールドスタートへの影響は #9 で計測
- **環境変数**: `DATA_DIR=/mnt/data`、`S3_BUCKET`、`AWS_REGION` を Cloud Run の環境変数で渡す。`AWS_ACCESS_KEY_ID` 等は渡さない（#6 で WIF）
- **ビルドターゲット**: Cloud Run 用イメージは `docker build --target runtime -f docker/Dockerfile .`。`dev` ステージ（git / composer 入り）を含めない
