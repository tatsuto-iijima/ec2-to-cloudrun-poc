# 03. Terraform で GCP 基盤構築 + Cloud Run デプロイ（Cloud Storage ボリューム付き）

対応 Issue: #5（親 Issue #1）
前提: **Web アプリは一人で操作する。複数人での同時使用は禁止。** Cloud Run は `max-instances=1`。

## 1. 結論

- `terraform/gcp/` で API 有効化、Artifact Registry、作業領域バケット、Cloud Run 実行用サービスアカウント、Cloud Run v2 サービス（第2世代、Cloud Storage ボリュームを `/mnt/data` にマウント）を定義した
- イメージのビルドは Cloud Build（`cloudbuild.yaml`、`--target runtime`）。手元に Docker は不要
- Cloud Run は**非公開**（`roles/run.invoker` を自分のアカウントにだけ付与）。確認は ID トークン付き curl か `gcloud run services proxy`
- この作業環境では `terraform fmt` / `init` / `validate` まで確認済み（google provider 8.2.0）。**`apply` → Cloud Build → Cloud Run の起動確認はユーザーの手元で実施**し、結果を「6. 実機での確認結果」に追記する

## 2. 構成

```
terraform/gcp/
  versions.tf                 Terraform >= 1.5、google provider ~> 8.0。state はローカル
  variables.tf                project_id（必須）/ region（asia-northeast1）/ name_prefix（poc）/ image（空なら Cloud Run を作らない）/
                              invoker_member / s3_bucket / aws_region / write_mode / max_instances（1）/ concurrency（80）/ request_timeout（300s）/ cpu / memory
  apis.tf                     run / artifactregistry / cloudbuild / iam / storage を有効化（destroy で無効化しない）
  registry.tf                 Artifact Registry（Docker）。image_uri = REGION-docker.pkg.dev/PROJECT/poc-app/app
  storage.tf                  作業領域バケット PROJECT-poc-data（uniform access、公開防止、force_destroy）
  iam.tf                      Cloud Run 実行用 SA（バケットに roles/storage.objectUser）。Cloud Build 専用 SA（ソース用バケット PROJECT_ID_cloudbuild に objectViewer、AR に artifactregistry.writer、logging.logWriter）
  cloudrun.tf                 Cloud Run v2 サービス（下記）と invoker の IAM
  outputs.tf                  image_uri / bucket_name / service_account_email / build_service_account_email / service_account_unique_id / service_url / service_name
  terraform.tfvars.example    project_id / invoker_member / image の見本
cloudbuild.yaml               docker build --target runtime -f docker/Dockerfile → ${_IMAGE}:${SHORT_SHA} と :latest を push。serviceAccount は Terraform で作った Cloud Build 用 SA（${_BUILD_SA}）。substitution に既定値を置かず、未指定は submit 時にエラー
scripts/build-push.sh         terraform output から _IMAGE / _BUILD_SA を組み立てて gcloud builds submit を実行する
.gcloudignore                 Cloud Build に送らないファイル（vendor、data、docs、terraform など）
docker/Dockerfile             dev ステージに gcloud CLI を追加（公式 apt リポジトリ、signed-by 方式。実行イメージ runtime には含めない）
```

### Cloud Run サービスの設定（`cloudrun.tf`）

| 項目 | 値 | 理由 |
|---|---|---|
| 実行環境 | `EXECUTION_ENVIRONMENT_GEN2` | Cloud Storage ボリュームに必須 |
| スケーリング | min 0 / max `var.max_instances`（既定 1） | 一人で操作する前提。複数インスタンスに起因する gcsfuse のキャッシュ不整合を排除 |
| 同時実行 | `var.concurrency`（既定 80） | 二重送信対策として 1 にするかは #8 で決める |
| タイムアウト | `var.request_timeout`（既定 300s） | #8 で実測と比較 |
| CPU / メモリ | 1 / 512Mi、`cpu_idle = true` | 従量課金の基本構成。`/tmp` はインメモリなので余裕を持たせる |
| 環境変数 | `DATA_DIR=/mnt/data`, `WRITE_MODE`, `S3_BUCKET`, `AWS_REGION` | `AWS_ACCESS_KEY_ID` 等は渡さない（#6 で WIF） |
| ボリューム | `gcs { bucket, read_only=false, mount_options=["uid=33","gid=33"] }` → `/mnt/data` | Apache の worker は www-data（uid/gid 33）。gcsfuse の既定はマウントしたユーザー所有・0644/0755 なので所有者を合わせて書き込めるようにする |
| startup probe | `GET /healthz`（2 秒間隔、最大 15 回） | `/healthz` はファイルにも S3 にも触らない |
| ingress | `INGRESS_TRAFFIC_ALL` + IAM で認証必須 | 非公開運用。`allUsers` には付与しない |
| 実行 SA | `poc-run@PROJECT.iam.gserviceaccount.com` | バケットの読み書きのみ。#6 で AWS 側の信頼ポリシーに使う |

### 2 段階の apply

Cloud Run サービスはイメージが Artifact Registry に存在しないと作れない。`var.image` が空のときはサービスを作らない（`count = 0`）ようにして、次の順で進める。

1. `terraform apply`（`image` 未指定）→ API / Artifact Registry / バケット / SA / Cloud Build の権限
2. `gcloud builds submit` でイメージを push
3. `terraform apply -var image=<image_uri>:<tag>` → Cloud Run サービス + invoker

## 3. デプロイ手順（Dev Container 内で実施）

```bash
# 認証（初回。Dev Container を rebuild すると消えるので再実行）
gcloud auth login --no-launch-browser
gcloud auth application-default login --no-launch-browser
gcloud config set project <PROJECT_ID>

# 変数
cp terraform/gcp/terraform.tfvars.example terraform/gcp/terraform.tfvars   # project_id と invoker_member を記入

# 1 回目の apply（API / Artifact Registry / バケット / SA）
terraform -chdir=terraform/gcp init
terraform -chdir=terraform/gcp apply

# イメージのビルドと push（Cloud Build。--target runtime。専用 SA でビルド）
# terraform output から _IMAGE / _BUILD_SA を組み立てて gcloud builds submit する
scripts/build-push.sh

# 2 回目の apply（Cloud Run サービス）。image は build-push.sh が terraform/gcp/image.auto.tfvars に書き出している
terraform -chdir=terraform/gcp apply
```

`image.auto.tfvars` は `.gitignore` 済み（`*.tfvars`）。手で `-var image=...` を渡す場合は、`git rev-parse --short HEAD` ではなく**実際に push したタグ**（`build-push.sh` の出力、または `:latest`）を使う。

## 4. 動作確認手順

```bash
URL=$(terraform -chdir=terraform/gcp output -raw service_url)
TOKEN=$(gcloud auth print-identity-token)

# 合否基準 1: /healthz が 200
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" $URL/healthz

# 合否基準 2: GET / で JSON が表示される（初回は初期データ）。フッターに DATA_DIR=/mnt/data が出る
curl -s -H "Authorization: Bearer $TOKEN" $URL/ | grep -oE 'DATA_DIR=<code>[^<]*|<th>[^<]*</th>'

# /mnt/data への書き込み（www-data の権限確認）。S3 認証が無いので 500 になるが、書き込み自体は先に行われる
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" -X POST -d 'key=hello&value=world' $URL/update
gcloud storage ls -l gs://$(terraform -chdir=terraform/gcp output -raw bucket_name)/        # data.json があれば書き込み成功
gcloud storage cat gs://$(terraform -chdir=terraform/gcp output -raw bucket_name)/data.json

# ログ（update の所要時間と、S3 PUT のエラー）
gcloud run services logs read $(terraform -chdir=terraform/gcp output -raw service_name) --region asia-northeast1 --limit 50

# ブラウザで確認する場合（ローカル 8081 → Cloud Run。ID トークンを自動付与）
gcloud run services proxy $(terraform -chdir=terraform/gcp output -raw service_name) --region asia-northeast1 --port 8081

# 後片付け（合否基準 3）
terraform -chdir=terraform/gcp destroy
```

期待結果:

| 確認 | 期待 |
|---|---|
| `/healthz` | `200` |
| `GET /` | 200。`message` / `counter` の表と `DATA_DIR=/mnt/data` |
| `POST /update` | **500**（`PutObject` の認証エラー。#6 で解消）。ただしバケットに `data.json` が作られている（www-data が gcsfuse 上に書けている） |
| `gcloud storage cat` | `counter: 1`、`hello: world`、`updated_at` が入った JSON |
| ログ | `error Aws\S3\Exception\...`（S3 側）。`JSON の書き込み` のエラーが**無い**こと |
| `terraform destroy` | バケット（中身ごと）、Cloud Run、SA、AR が消える。API は残る |

`POST /update` でバケットに `data.json` が作られない（500 のメッセージが `JSON の書き込み（LOCK_EX）に失敗` になる）場合は、`mount_options` の `uid` / `gid` が効いていない。`file-mode=0666,dir-mode=0777` を試す（#7 の (c) と合わせて確認）。

## 5. この環境での検証結果

| 確認内容 | 結果 |
|---|---|
| `terraform fmt -check -recursive` | OK |
| `terraform init`（provider を `releases.hashicorp.com` から filesystem mirror で取得。registry.terraform.io は遮断） | OK（hashicorp/google v8.2.0） |
| `terraform validate` | **Success! The configuration is valid.** |
| `cloudbuild.yaml` の YAML、`.devcontainer/devcontainer.json` の JSON | OK |
| `apply` / Cloud Build / Cloud Run 起動 | 未実施（GCP の認証情報が無い）→ 手元で実施 |

### つまずいた点 1: gcloud CLI の devcontainer feature が Debian trixie で失敗する（2026-09-14）

当初はコミュニティ feature `ghcr.io/dhoeric/features/google-cloud-cli:1` で gcloud を入れる構成にしたが、ユーザーの手元（macOS / Apple Silicon、Docker Desktop）で Dev Container のビルドが失敗した。

```
./install.sh: line 72: apt-key: command not found
ERROR: Feature "Google Cloud CLI" (ghcr.io/dhoeric/features/google-cloud-cli) failed to install!
... did not complete successfully: exit code: 127
```

原因: `php:8.3-apache` の現行ベースは Debian trixie で、`apt-key` が削除されている。この feature の `install.sh` は `apt-key` で Google の鍵を登録するため必ず失敗する。
対処: feature をやめ、`docker/Dockerfile` の `dev` ステージで公式手順（`/usr/share/keyrings/cloud.google.gpg` + `signed-by`）により `google-cloud-cli` を入れる。Google の apt リポジトリは amd64 / arm64 の両方を提供しているので Apple Silicon でも動く。実行イメージ `runtime` には含めない。

補足: Apple Silicon の Dev Container は arm64 イメージをビルドするが、Cloud Run 用イメージは Cloud Build が linux/amd64 でビルドするので影響しない。Claude Code の作業環境からは `packages.cloud.google.com` に到達できないため（プロキシで遮断）、この Dockerfile の変更はユーザーの手元の「Rebuild Container」で確認する。

### つまずいた点 2: 1 回目の `terraform apply` で Compute 既定 SA が存在しないと言われる（2026-09-14）

```
Error 400: Service account 912851559962-compute@developer.gserviceaccount.com does not exist.
  with google_project_iam_member.cloud_build_log_writer
```

原因: Cloud Build の実行 SA として Compute Engine の既定 SA（`PROJECT_NUMBER-compute@developer.gserviceaccount.com`）を想定していたが、この SA は Compute Engine API を有効にしたときに作られるもので、新規プロジェクトには存在しない。組織によっては組織ポリシーで既定 SA が無効化されている。
対処: Compute Engine API は有効化せず、Terraform で **Cloud Build 専用の SA**（`poc-build`）を作って必要最小限の権限（ソース用バケット `PROJECT_ID_cloudbuild` の `objectViewer`、Artifact Registry の `writer`、`logging.logWriter`）を付け、`cloudbuild.yaml` の `serviceAccount` で指定する。ユーザー指定の SA でビルドする場合は `options.logging` の指定が必須なので `CLOUD_LOGGING_ONLY` を維持する。`gcloud builds submit` を実行する人には、この SA に対する `roles/iam.serviceAccountUser`（プロジェクトのオーナーなら不要）が必要。

### つまずいた点 3: `gcloud builds submit` で `NOT_FOUND: Unknown service account`（2026-09-14）

```
ERROR: (gcloud.builds.submit) NOT_FOUND: generic::not_found: Unknown service account. This command is authenticated as ...
```

原因: `--substitutions` に `_BUILD_SA` を渡さずに実行したため、`serviceAccount: projects/PROJECT/serviceAccounts/` と SA 名が空になった。`cloudbuild.yaml` に `_BUILD_SA: ""` という空の既定値を置いていたので、指定漏れがエラーにならず空文字で通ってしまった。メッセージ中の「認証されているアカウント」は無関係。
対処: `cloudbuild.yaml` から substitution の既定値を外し、未指定を submit 時のエラーにした。あわせて `scripts/build-push.sh` を追加し、`terraform output` から `_IMAGE` / `_BUILD_SA` を組み立てて実行するようにした（手で substitution を並べない）。

### つまずいた点 4: 2 回目の apply で `Image '...:4bed53a' not found`（2026-09-14）

原因: `git pull` で HEAD が進んだ後に `-var image=...:$(git rev-parse --short HEAD)` を実行したため、まだビルドしていないコミットの SHA をタグに指定した。イメージは `build-push.sh` 実行時点の SHA と `latest` で push されている。
対処: `build-push.sh` が push したタグを `terraform/gcp/image.auto.tfvars` に書き出すようにし、2 回目以降の apply は `-var` なしで実行する。手で指定する場合は実際に push したタグか `:latest` を使う。

### つまずいた点 5: Cloud Run サービスが Ready なのに run.app URL が 404（2026-09-14）

`poc-app` が Ready・ingress `all`・トラフィック 100% で、DNS も正常（Cloud Run の正規 IP）なのに、認証あり／なしとも Google の汎用 404 ページが返り、コンテナにリクエストが届かなかった。同じリージョンに gcloud でデプロイした `hello` と、同じイメージ・同じ設定で gcloud からデプロイした `poc-app-test` は 403（到達）。`describe --format=export` の差分に経路へ影響する項目は無し。
対処: run.app のホスト名がサービス名から決まるため、`service_name` 変数を追加してサービス名だけを変えて作り直せるようにした（`-var service_name=poc-web`）。結果は「6. 実機での確認結果」に記録する。

## 6. 実機での確認結果

（未実施。手元で「3. デプロイ手順」「4. 動作確認手順」を実施して追記）

## 7. #6 / #7 へ引き継ぐ事項

- **#6（S3 認証）**: `terraform output service_account_email` と `service_account_unique_id` を AWS 側の IAM ロールの信頼ポリシーに使う。`S3_BUCKET` は `var.s3_bucket` で差し替える
- **#7（gcsfuse 読み書き）**: `mount_options` は既定 + `uid=33,gid=33` で開始。鮮度の問題が出たら `metadata-cache-ttl-secs=0` を追加する。`WRITE_MODE` は `var.write_mode` で切り替えられる
- **#8 / #9**: `concurrency` / `request_timeout` / `min_instance_count`（現状 0 固定）を変数化・調整する
