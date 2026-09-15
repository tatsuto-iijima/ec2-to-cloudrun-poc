# 04. Cloud Run → AWS S3 の認証・アップロード検証（Workload Identity Federation 主案）

Issue #6。Cloud Run から AWS S3 へ、**長期クレデンシャルをイメージにも環境変数にも置かずに** PUT できるかを検証する。
前提: Web アプリは一人で操作する。複数人での同時使用は禁止（#5 までと同じ）。

## 1. 結論

- **主案（鍵レス）で実装した**。Cloud Run 実行用 SA の OIDC ID トークンをメタデータサーバーから取得し、AWS STS `AssumeRoleWithWebIdentity` で一時クレデンシャルを得て S3 に PUT する。AWS 側に置くのは S3 バケットと IAM ロール（信頼ポリシーで Google の SA に限定）だけで、アクセスキーは発行しない
- この環境（GCP / AWS の認証なし）では、moto の S3 + STS と偽のメタデータサーバーで **`AWS_ACCESS_KEY_ID` を渡さずに `POST /update` → S3 PUT が成功**することを確認した（§6）。一時クレデンシャルのキャッシュと期限前の再取得も動いている
- 実機（Cloud Run → 本物の STS / S3）での成否と、信頼ポリシーの条件キーの確定は §7 に記入する。**§7 が埋まるまで #6 の合否は暫定**
- 代替案（Secret Manager 経由のアクセスキー）は、主案が実機で成立しなかった場合のみ実施する（§8 に比較だけ書いた）

## 2. 構成

```
Cloud Run (SA: poc-run@PROJECT.iam.gserviceaccount.com)
  │ 1. GET http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity
  │       ?audience=<IAM ロールの ARN>&format=full   (Metadata-Flavor: Google)
  │    → OIDC ID トークン (iss=https://accounts.google.com, sub=azp=<SA の一意 ID>, aud=<audience>, 有効 1 時間)
  │ 2. STS AssumeRoleWithWebIdentity(RoleArn, WebIdentityToken)   ← 署名不要
  │    → 一時クレデンシャル (AccessKeyId / SecretAccessKey / SessionToken / Expiration)
  │ 3. /tmp/aws-wif-credentials.json に 0600 でキャッシュ。期限 5 分前を切ったら 1. からやり直す
  └ 4. S3 PutObject（AWS SDK for PHP。S3Client の credentials に上のプロバイダを渡す）

AWS
  IAM ロール poc-cloudrun-s3-upload
    信頼ポリシー: Principal Federated=accounts.google.com, Action sts:AssumeRoleWithWebIdentity,
                  Condition StringEquals { accounts.google.com:sub, :aud, :oaud }
    権限:         s3:PutObject on arn:aws:s3:::<bucket>/<key_prefix>*
  S3 バケット <bucket>（public access block、force_destroy）
```

### ファイル

```
terraform/aws/
  versions.tf                 hashicorp/aws ~> 6.0、region = var.region（既定 ap-northeast-1）。state はローカル
  variables.tf                bucket_name / google_service_account_unique_id（必須）、key_prefix、audience、max_session_duration
  s3.tf                       aws_s3_bucket（force_destroy）+ aws_s3_bucket_public_access_block
  iam.tf                      信頼ポリシー（下表の 3 条件）、IAM ロール、s3:PutObject のみのインラインポリシー
  outputs.tf                  bucket_name / role_arn / audience / region
  terraform.tfvars.example
terraform/gcp/
  variables.tf, cloudrun.tf   aws_role_arn / aws_wif_audience を追加し、環境変数 AWS_ROLE_ARN / AWS_WIF_AUDIENCE で渡す
app/src/GoogleWebIdentityCredentialProvider.php
                              メタデータサーバー → STS → Credentials。ファイルキャッシュ付き。S3Uploader の ?callable $credentials に注入
app/src/Config.php            AWS_ROLE_ARN / AWS_WIF_AUDIENCE / AWS_ROLE_DURATION_SECONDS / STS_ENDPOINT / GCE_METADATA_HOST
app/public/index.php          AWS_ROLE_ARN があればプロバイダを注入、無ければ SDK 既定チェーン（ローカルの moto）
.devcontainer/docker-compose.yml, devcontainer.json
                              ~/.aws を名前付きボリュームにして SSO の設定とトークンキャッシュを Dev Container 側で永続化（初回に vscode へ chown）
```

### 信頼ポリシーの条件キーと Google ID トークンのクレームの対応

| AWS 条件キー | ID トークンのクレーム | この PoC での値 | 備考 |
|---|---|---|---|
| `accounts.google.com:sub` | `sub` | SA の一意 ID（`terraform -chdir=terraform/gcp output -raw service_account_unique_id`） | SA を一意に特定する。メールアドレスではない |
| `accounts.google.com:aud` | `azp`（authorized party） | SA の一意 ID | SA の ID トークンでは `azp == sub`。名前が紛らわしいが `aud` クレームではない |
| `accounts.google.com:oaud` | `aud` | IAM ロールの ARN（`terraform -chdir=terraform/aws output -raw audience`） | トークン取得時の `audience`。「このロールのために取ったトークン」だけを通す |

AWS には Google（`accounts.google.com`）用の OIDC プロバイダが組み込まれているので、IAM の OIDC プロバイダリソースは作らない。
対応表は AWS の公開ドキュメント（IAM 条件コンテキストキー「Web ID フェデレーションで使用できるキー」）と参考実装（[wvanderdeijl の gist](https://gist.github.com/wvanderdeijl/c6a9a9f26149cea86039b3608e3556c1)、[jpassing の記事](https://jpassing.com/2021/10/05/authenticating-to-aws-by-using-a-google-cloud-service-account-and-assumerolewithwebidentity/)）による。**実機での確定は §7**。

## 3. 設定の理由

- **3 つの条件キーをすべて `StringEquals` で縛る**: `sub` だけでも SA は特定できるが、`oaud`（audience）を縛ることで、同じ SA が別の目的（Cloud Run のサービス間認証など）で取った ID トークンを流用されない。`aud`（= `azp`）は `sub` と同じ値なので冗長だが、Issue に挙がっている 3 キーの組み合わせを実機で確認する意味で入れている
- **audience にロールの ARN を使う**: 任意の文字列でよいが、ロール ARN なら「何のためのトークンか」が自明で、GCP 側（`AWS_WIF_AUDIENCE` の既定 = `AWS_ROLE_ARN`）と AWS 側（`var.audience` の既定 = ロール ARN）で同じ既定値にできる。ロール自身の ARN を信頼ポリシーで参照すると循環するので、`aws_caller_identity` のアカウント ID と名前から組み立てている
- **権限は `s3:PutObject` のみ**: アプリは PUT しかしない。読み取りや一覧は不要
- **一時クレデンシャルをファイルにキャッシュする**: mod_php はリクエストごとに PHP のプロセスが入れ替わるので、AWS SDK の `CredentialProvider::memoize`（プロセス内）だけでは毎回メタデータサーバーと STS を往復する（この環境の計測で初回 PUT は約 2.2 秒、キャッシュ命中時は 10ms 前後）。Cloud Run の `/tmp` はインスタンス内のインメモリ領域で、インスタンスが消えれば一緒に消える。0600 で書き、別ロールのキャッシュは使わない
- **期限 5 分前に取り直す**: STS の `DurationSeconds`（既定 3600、最小 900）で有効期間が決まる。期限ぎりぎりで PUT が失敗しないよう余裕を持たせる
- **STS はリージョナルエンドポイント**（`sts_regional_endpoints = regional`）: S3 と同じ東京の STS を使う
- **SDK 同梱の `AssumeRoleWithWebIdentityCredentialProvider` を使わない**: トークンを**ファイル**（`AWS_WEB_IDENTITY_TOKEN_FILE`）からしか読めない。EKS のようにトークンがファイルで投影される環境向けで、Cloud Run ではメタデータサーバーから取る必要がある。その実装（`InvalidIdentityToken` のリトライなど）を参考に自前で書いた
- **`format=full`**: ID トークンに `email` クレームが入る。AWS の条件には使わないが、トラブル時にトークンの中身（`gcloud auth print-identity-token` や jwt.io で確認）が読みやすい
- **`GCE_METADATA_HOST` / `STS_ENDPOINT`**: ローカル検証用の差し替え口。前者は Google のクライアントライブラリと同じ環境変数名
- **AWS の認証は Dev Container の中で SSO**: `~/.aws` を名前付きボリューム（`aws-config`）にして、`aws configure sso` の設定と SSO のトークンキャッシュを Rebuild 後も残す。ホストの `~/.aws` はマウントしない（PR #17 のレビューで変更）。`--use-device-code` を付けるのは、AWS CLI v2 の既定（認可コード + PKCE）がブラウザから `127.0.0.1` のコールバックに戻る必要があり、コンテナ内では受け取れないため。デバイスコードなら URL とコードをホストのブラウザで開くだけでよい。空の名前付きボリュームは root 所有でマウントされるので、`postCreateCommand` で vscode に chown している
- **`.env` の moto 用アクセスキー**: Dev Container には `.env` から `AWS_ACCESS_KEY_ID=test` が入る。**環境変数のアクセスキーはプロファイルより優先される**ので、実 AWS を触るシェルでは `unset` する（§4）。アプリ側は `AWS_ROLE_ARN` があれば WIF プロバイダを使い、環境変数のキーは見ない

## 4. デプロイ手順（Dev Container 内で実施）

```bash
# --- AWS 側 ---
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY      # .env の moto 用の値を外す（プロファイルより優先されてしまう）
aws configure sso --use-device-code                # 初回のみ。SSO の start URL / region とプロファイル名を対話で入力。~/.aws は名前付きボリュームなので Rebuild 後も残る
aws sso login --use-device-code --profile <profile>   # トークン（既定 8 時間）が切れたとき。表示された URL とコードをホストのブラウザで開く
export AWS_PROFILE=<profile>
aws sts get-caller-identity                        # 認証の確認

cp terraform/aws/terraform.tfvars.example terraform/aws/terraform.tfvars
#   bucket_name                      : 全世界で一意な名前
#   google_service_account_unique_id : terraform -chdir=terraform/gcp output -raw service_account_unique_id
terraform -chdir=terraform/aws init && terraform -chdir=terraform/aws apply

# --- AWS 側の output を Cloud Run に渡す（*.tfvars は gitignore 済み） ---
cat > terraform/gcp/aws.auto.tfvars <<EOF
s3_bucket    = "$(terraform -chdir=terraform/aws output -raw bucket_name)"
aws_role_arn = "$(terraform -chdir=terraform/aws output -raw role_arn)"
EOF

# --- GCP 側（アプリのコードが変わっているのでイメージも作り直す） ---
scripts/build-push.sh
terraform -chdir=terraform/gcp apply               # 新しいイメージ + 環境変数 AWS_ROLE_ARN / S3_BUCKET で新リビジョン
```

## 5. 動作確認手順と合否基準

```bash
URL=$(terraform -chdir=terraform/gcp output -raw service_url)
TOKEN=$(gcloud auth print-identity-token)
BUCKET=$(terraform -chdir=terraform/aws output -raw bucket_name)
SERVICE=$(terraform -chdir=terraform/gcp output -raw service_name)

# 合否基準 1: POST /update が 303 で、S3 に data.json ができる
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" -X POST -d 'key=wif&value=ok-1' "$URL/update"   # 303
aws s3 cp "s3://$BUCKET/data.json" -                                                                                  # "wif": "ok-1"

# 合否基準 2: 長期クレデンシャルを置いていない（環境変数にアクセスキーが無い。イメージにも無い）
gcloud run services describe "$SERVICE" --region asia-northeast1 --format 'value(spec.template.spec.containers[0].env)'
#   → AWS_ROLE_ARN / S3_BUCKET はあるが AWS_ACCESS_KEY_ID は無い

# ログ: 初回は wif: credentials refreshed、続く POST では出ない（キャッシュ命中）
gcloud logging read 'resource.type="cloud_run_revision" AND textPayload:"wif:"' --limit 10 --format 'value(timestamp,textPayload)'

# 合否基準 3: ID トークンの有効期限（1 時間）を跨いでも PUT が続く。
#   1 時間待つ代わりに一時クレデンシャルを最短（900 秒）にし、キャッシュが切れる（期限 5 分前 = 10 分後）のを待って再 POST する
gcloud run services update "$SERVICE" --region asia-northeast1 --update-env-vars AWS_ROLE_DURATION_SECONDS=900
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" -X POST -d 'key=wif&value=ok-2' "$URL/update"   # 303（refreshed 1 回目）
sleep 660
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $(gcloud auth print-identity-token)" -X POST -d 'key=wif&value=ok-3' "$URL/update"   # 303（refreshed 2 回目）
#   ※ min-instances 0 なので、待っている間にインスタンスが落ちればキャッシュも消えて同じく取り直す。どちらでも「2 回目の POST が 303」なら合格
terraform -chdir=terraform/gcp apply               # 環境変数を Terraform の定義に戻す（AWS_ROLE_DURATION_SECONDS を消す）

# 条件キーの確認（任意）: oaud を別の値にすると拒否されることを 1 回だけ確かめる
terraform -chdir=terraform/aws apply -var audience=https://example.invalid   # → POST /update が 500（AccessDenied）
terraform -chdir=terraform/aws apply                                          # 戻す → 303
```

| 項目 | 期待 |
|---|---|
| `POST /update` | 303。S3 の `data.json` に更新値 |
| Cloud Run の環境変数 | `AWS_ROLE_ARN`, `AWS_WIF_AUDIENCE`（空）, `S3_BUCKET` はある。`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` は無い |
| ログ | 初回 `wif: credentials refreshed role=... expires=...`。以後キャッシュ命中中は出ない |
| 期限跨ぎ | `AWS_ROLE_DURATION_SECONDS=900` で 11 分後の POST も 303。`refreshed` が 2 回 |
| 条件キー | `sub` + `aud` + `oaud` の 3 つで成功。`oaud` を変えると `AccessDenied` |

## 6. この環境での検証結果（2026-09-15）

GCP / AWS の認証が無いので、moto（S3 + STS。`AssumeRoleWithWebIdentity` はトークンを検証せずに一時クレデンシャルを返す）と、メタデータサーバーを模した PHP 内蔵サーバー（`Metadata-Flavor: Google` が無ければ 403、`audience` を `aud` に入れたダミー JWT を返す）で end-to-end を通した。

| 項目 | 結果 |
|---|---|
| `php -l`（変更・追加した PHP） | OK |
| `terraform fmt -check` / `init` / `validate`（`terraform/aws`: aws 6.64.0、`terraform/gcp`: google 8.2.0。filesystem mirror） | OK（両方 Success） |
| **`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` を渡さず**、`AWS_ROLE_ARN` + `STS_ENDPOINT`（moto）+ `GCE_METADATA_HOST`（偽メタデータ）で `scripts/smoke.sh` | **ALL PASS**（health / GET / / POST /update 303 / 表示 / data.json） |
| moto の S3 に `data.json` | 更新値あり（`counter: 3`, `smoke`, `second`, `third`） |
| 偽メタデータサーバーのログ | `audience=arn:aws:iam::123456789012:role/poc-cloudrun-s3-upload format=full` で 2 回（初回と、キャッシュを失効させた後） |
| キャッシュ | `/tmp/aws-wif-credentials.json` が `-rw-------`。2 回目の POST は STS を呼ばない（`refreshed` が出ない）。`expires` を過去に書き換えた 3 回目の POST で再取得 |
| 所要時間（ログ） | 初回 `put=2211.3ms`（メタデータ + STS + moto の初回）、キャッシュ命中時 `put=7.2ms` / `12.4ms` |
| 画面のフッター | `認証=WIF arn:aws:iam::...:role/poc-cloudrun-s3-upload` |
| 回帰: `AWS_ROLE_ARN` なし + `AWS_ACCESS_KEY_ID=test`（従来のローカル構成） | ALL PASS。フッターは `認証=SDK 既定チェーン` |

アプリのログ（抜粋）:

```
wif: credentials refreshed role=arn:aws:iam::123456789012:role/poc-cloudrun-s3-upload expires=2026-09-15T02:26:30+00:00
update key=smoke mode=lock read=0.0ms write=0.4ms put=2211.3ms target=s3://poc-bucket/data.json etag="5c13..."
update key=second mode=lock read=0.0ms write=0.2ms put=7.2ms target=s3://poc-bucket/data.json etag="4457..."
wif: credentials refreshed role=arn:aws:iam::123456789012:role/poc-cloudrun-s3-upload expires=2026-09-15T02:26:30+00:00
update key=third mode=lock read=0.0ms write=0.2ms put=12.4ms target=s3://poc-bucket/data.json etag="c6d5..."
```

この環境では確認できないもの: 本物の STS が Google の ID トークンを受理すること、信頼ポリシーの条件キーの組み合わせ、Cloud Run のメタデータサーバーが返すトークンのクレーム。いずれも §7 で確定する。

## 7. 実機での確認結果（手元で実施して記入）

| 項目 | 結果 | メモ |
|---|---|---|
| `terraform -chdir=terraform/aws apply` | 未実施 | |
| `scripts/build-push.sh` → `terraform -chdir=terraform/gcp apply` | 未実施 | |
| `POST /update` → 303、S3 に `data.json` | 未実施 | |
| 環境変数にアクセスキーが無い | 未実施 | |
| ログ `wif: credentials refreshed` | 未実施 | |
| 期限跨ぎ（`AWS_ROLE_DURATION_SECONDS=900`、11 分後の POST） | 未実施 | |
| 条件キーの確定（`sub` + `aud` + `oaud`。`oaud` を変えると拒否） | 未実施 | |

## 8. 代替案（Secret Manager 経由のアクセスキー）との比較

主案が実機で成立した場合は実施しない。比較のみ。

| 観点 | 主案: WIF（鍵レス） | 代替案: IAM ユーザーのアクセスキー + Secret Manager |
|---|---|---|
| 長期クレデンシャル | 無い。AWS 側はロールの信頼ポリシーで Google の SA を指定するだけ | 有る（アクセスキー）。Secret Manager に格納し Cloud Run に環境変数として注入 |
| 追加の GCP リソース | 無し | Secret Manager の API 有効化、シークレット、Cloud Run SA への `secretmanager.secretAccessor` |
| 追加の AWS リソース | IAM ロール 1 つ | IAM ユーザー + アクセスキー + ポリシー |
| 運用コスト | ロールの信頼ポリシーを一度書けば終わり。SA を作り直したら一意 ID を差し替える | アクセスキーのローテーション（発行 → シークレットの新バージョン → Cloud Run の再デプロイ → 旧キー無効化）を定期的に行う。漏えい時の失効も同じ手順 |
| リクエストごとのオーバーヘッド | 初回（およびキャッシュ失効時）にメタデータサーバー + STS の往復。以後はキャッシュ | 無し |
| コードの変更 | クレデンシャルプロバイダの追加（本 Issue で実装） | 無し（SDK の既定チェーンが環境変数を読む） |

## 9. #7 以降への引き継ぎ

- S3 PUT が通るようになったので、#7（gcsfuse 上の JSON 読み書き）と #8（タイムアウト・ステートレス性）は `POST /update` を最後まで通した状態で計測できる。`put=` の時間は初回だけ STS の往復を含む点に注意（ログの `wif: credentials refreshed` の直後の 1 件）
- #9（コールドスタート）: インスタンスが新しくなるとキャッシュも消えるので、コールドスタート直後の最初の `POST /update` は STS の往復分だけ遅い。`/health` の計測には影響しない
- #10（運用）: 鍵のローテーションが不要な点を移行コストの評価に反映する
- `terraform -chdir=terraform/aws destroy` は #7 完了後に GCP 側と一緒に実施する（バケットは `force_destroy = true`）
