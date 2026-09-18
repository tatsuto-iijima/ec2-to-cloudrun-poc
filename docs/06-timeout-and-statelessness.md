# 06. リクエストタイムアウト・ステートレス性の検証

対応 Issue: #8（親 Issue #1）
前提: **Web アプリは一人で操作する。複数人での同時使用は禁止。** Cloud Run は `max-instances=1`。

## 1. 結論

**合否基準 3 項目すべて成立**（実機 2026-09-18、§8）。Issue #1 の検証項目「Cloud Run のリクエストタイムアウト・ステートレス性がアプリの処理時間と両立するか」は**成立**。

- 合否基準 1（処理時間がタイムアウトに対して十分な余裕を持つ）: 実機の `POST /update` は **1MB 0.45 秒 / 10MB 0.86 秒 / 50MB 2.8 秒**（read + write + S3 PUT）。タイムアウト設定値 300 秒（上限 3600 秒）に対して 50MB でも 1/100。現行の上限 1MB なら 0.5 秒
- 合否基準 2（インスタンス入れ替え後も操作が継続できる）: `/tmp` に置く状態は WIF のキャッシュとロックファイルだけ（§5）。実機で新リビジョン・新インスタンスに切り替えた直後に `GET /` が最新の JSON を返し、`POST /update` が 303（WIF を取り直して S3 PUT まで成功）
- 合否基準 3（二重送信時の方針が決まり、動作確認済み）: **アプリ側で read-modify-write 全体を `flock` で直列化する**（`Updater`）。`concurrency` は 80 のまま（§6）。実機で 5 本同時に投げて全部 303、約 0.29 秒間隔で順に完了し、counter がちょうど +5
- 注意点: 新リビジョン直後の初回 `POST /update` は WIF の初回取得と初回接続で **+約 1 秒**（1MB で 1.7 秒）。大きなオブジェクトを小さく書き戻すときも既存オブジェクトのダウンロードが要る（50MB → 208 バイトの書き戻しに 0.66 秒）。どちらもタイムアウトには影響しない
- S3 転送（GCP asia-northeast1 → S3 ap-northeast-1）: 1MB 0.16〜0.19 秒（レイテンシ支配）、10MB 0.26〜0.36 秒、50MB 0.9〜1.0 秒 ≒ **51〜56 MB/s**（#11 の入力）

## 2. 検証方法

### 本物の `POST /update` を計測する

`POST /update` は 303 の `Location`（`/?result=...`）に `read X ms / write Y ms / put Z ms` を入れて返す（`app/public/index.php`）。`scripts/update-bench.sh` は curl の `%{redirect_url}` からこれを読み取るので、診断用の別経路ではなく**本物の経路**の内訳が取れる。ログにも同じ内訳と `lock`（ロック待ち）・`bytes`・`counter` が出る。

JSON を大きくする手段だけ診断経路に足した: `POST /fs-check case=pad size=N`（`FS_CHECK=1` のときだけ有効。docs/05）が `data.json` に `pad` キー（N バイトの `x`）を書く。`size=0` で外す。S3 には PUT しない（次の `POST /update` が PUT する）。

### `scripts/update-bench.sh`

| サブコマンド | 内容 | 作業項目 |
|---|---|---|
| `bench`（既定） | `/health` を 3 回（基準）→ `SIZES`（既定 1MB / 10MB / 50MB）ごとに `pad` → `POST /update` を `N` 回（既定 3）→ 各回の `total`（curl）/ `read` / `write` / `put` と S3 の MB/s を表示 → `pad 0` | 処理時間のサイズ別計測、S3 転送レイテンシ |
| `double-submit` | `GET /` で `counter` を読む → `N` 本（既定 5）の `POST /update` を同時に投げる → 全部 303 か、`counter` がちょうど +N か、`GET /` が 200 か | 二重送信 |
| `reset` | `pad 0` | 後片付け |

結果は `update-bench-results.jsonl`（gitignore 済み）に追記する。

### ステートレス性の確認

`scripts/fs-check.sh restart-mark` → 新リビジョン（インスタンスが入れ替わる）→ Cloud Run に向けた `scripts/smoke.sh` が ALL PASS で、ログに `wif: credentials refreshed`（`/tmp` のキャッシュが消えて取り直した）が出ること。

## 3. 手順（Dev Container 内で実施）

```bash
# 1. 診断経路を有効にしてデプロイ（アプリが変わるので再ビルド）
grep -q '^fs_check' terraform/gcp/terraform.tfvars || echo 'fs_check = true' >> terraform/gcp/terraform.tfvars   # 既にあれば足さない（やり直しても 1 行のまま）
scripts/build-push.sh && terraform -chdir=terraform/gcp apply   # 途中で失敗してやり直すときは build-push.sh は不要（image.auto.tfvars に push 済みタグが残る）
export BASE_URL=$(terraform -chdir=terraform/gcp output -raw service_url)
SVC=$(terraform -chdir=terraform/gcp output -raw service_name)

# 2. 処理時間（1MB / 10MB / 50MB × 3 回）と S3 転送
scripts/update-bench.sh bench

# 3. 二重送信（5 本同時）
scripts/update-bench.sh double-submit
gcloud run services logs read $SVC --region asia-northeast1 --limit 50 | grep 'update key=dbl'   # lock=…ms が順に増える

# 4. インスタンス入れ替え
scripts/fs-check.sh restart-mark
gcloud run services update $SVC --region asia-northeast1 --update-env-vars FS_CHECK_RESTART=$(date +%s)
scripts/fs-check.sh restart-verify
BASE_URL=$BASE_URL DATA_DIR= S3_ENDPOINT= S3_BUCKET=$(terraform -chdir=terraform/aws output -raw bucket_name) scripts/smoke.sh
gcloud run services logs read $SVC --region asia-northeast1 --limit 50 | grep -E 'wif: credentials refreshed|update key=smoke'

# 5. 後片付け
scripts/update-bench.sh reset
sed -i '/^fs_check/d' terraform/gcp/terraform.tfvars
terraform -chdir=terraform/gcp apply          # FS_CHECK を空に戻し、FS_CHECK_RESTART も消える
```

## 4. タイムアウトの比較

| 項目 | 値 | 備考 |
|---|---|---|
| Cloud Run のリクエストタイムアウト（設定値） | **300 秒**（`terraform/gcp` の `var.request_timeout`。Cloud Run の既定と同じ） | サービスの上限は 3600 秒（60 分） |
| PHP `max_execution_time` | 30 秒（`php.ini` を置いていないので組み込み既定） | Linux では**スクリプトの CPU 時間**だけを数え、gcsfuse や S3 の I/O 待ちは含まない。50MB の `json_encode` / `json_decode` でも 1 秒未満 |
| Apache `Timeout` | 60 秒（既定） | クライアントとの送受信の無通信時間。処理時間の上限ではない |
| `POST /update` の実測（この環境、50MB） | 0.7 秒 | §7 |
| `POST /update` の実測（実機） | **1MB 0.45 秒 / 10MB 0.86 秒 / 50MB 2.8 秒**（新リビジョン直後の初回は +約 1 秒） | §8。300 秒に対して 50MB でも 1/100 |

## 5. ステートレス性の棚卸し

| 状態 | 置き場所 | インスタンス入れ替えで | 影響 |
|---|---|---|---|
| JSON マスタ | `/mnt/data`（Cloud Storage ボリューム） | 残る | なし。#7 (e) で新インスタンスが最新を読むことを確認済み |
| PHP セッション | 使わない（docs/01 §2） | — | なし |
| WIF の一時クレデンシャル | `/tmp/aws-wif-credentials.json`（docs/04） | 消える | 次の `POST /update` で STS から取り直す（+約 1 秒。ログに `wif: credentials refreshed`） |
| 更新のロックファイル | `/tmp/update-<hash>.lock`（`Updater`） | 消える | 次のリクエストで作り直す。ロックは同一インスタンス内でしか効かないので、消えても意味は変わらない |
| `/tmp/fs-check-instance-id` | 診断用（docs/05） | 消える | インスタンスの入れ替わりを検出する印そのもの |
| アップロード一時ファイル、独自ログ、キャッシュ | 無い（docs/01 §2） | — | なし |

`/tmp` は Cloud Run ではインメモリで、インスタンスのメモリ上限（512Mi）に算入される。置いているのは上の 3 ファイル（合計 1KB 未満）だけ。

## 6. 二重送信の方針

### 問題

修正前の `POST /update` は `read → 更新 → file_put_contents(LOCK_EX) → S3 PUT` で、`LOCK_EX` は write の瞬間しか守らない。同一インスタンス内で 2 リクエストが並行すると（Cloud Run の `concurrency` は 80、Apache は prefork の複数プロセス）、両方が同じ `counter` を読んでから順に書くので、片方の更新が失われる。gcsfuse では read 1ms・write 0.2 秒（docs/05）なので、ローカルディスクより窓が広い。

### 選択肢

| 案 | 内容 | 利点 | 欠点 |
|---|---|---|---|
| A. `concurrency=1` | Cloud Run が 1 インスタンスに同時 1 リクエストしか渡さない | コード変更なし | `GET /` や `/health` まで `POST` の後ろに並ぶ。startup probe には影響しないが、画面の操作感が落ちる |
| **B. アプリ側 `flock`（採用）** | `Updater` が `/tmp` のロックファイルを `flock(LOCK_EX)` で握り、read → 更新 → write → S3 PUT まで直列化する | #7 で同一インスタンス内の直列化を確認済み。`max-instances=1` なので十分。現行アプリの `flock` の使い方の延長。`GET` は並行のまま | ロックは同一インスタンス内でしか効かない（`max-instances` を増やすなら A か GCS の世代条件が必要） |
| C. フォームのノンス | 画面ごとに一意のトークンを埋め、使用済みなら 2 回目を拒否 | 「2 回目を拒否」できる | トークンの保存先（`/mnt/data` か Cookie）と実装が増える。一人で操作する前提では過剰 |

B の結果は「2 回目も順に適用される」（counter は 2 回分進む）であり、拒否ではない。一人で操作する前提では、失われないことと壊れないことが担保されれば十分と判断した。加えてフォームのボタンを送信時に無効化し（`app/templates/index.php`）、ダブルクリック自体を減らす。

### 実装（`app/src/Updater.php`）

- ロックファイル: `sys_get_temp_dir() . '/update-' . md5(dataPath) . '.lock'`。gcsfuse 上に置いても他インスタンスには伝播しないので同じ強さで、バケットを汚さない `/tmp` を使う
- ロックの内側: `JsonStore::read` → `key` / `counter` / `updated_at` を更新 → `JsonStore::write`（`WRITE_MODE` どおり）→ S3 PUT。ロック待ち時間を `lock` としてログに出す
- メモリ: 数十 MB の JSON でも `memory_limit` 128M に収まるよう、write 後に配列を解放し、S3 PUT は `file_get_contents` ではなくファイルのストリームを `Body` に渡す（`S3Uploader::put` が `string|resource` を受ける。`ContentLength` を明示）

### 確認方法

`scripts/update-bench.sh double-submit`（5 本同時）で、全部 303・`counter` がちょうど +5・`GET /` が 200。ログの `lock=…ms` が後着ほど大きくなる。

## 7. この環境での検証結果（moto + ローカル FS）

2026-09-16、PHP 8.4 内蔵サーバー（`PHP_CLI_SERVER_WORKERS=4`、`memory_limit=128M`）+ moto。S3 も FS もローカルなので**数値は比較基準**（下限）。

| 確認内容 | 結果 |
|---|---|
| `php -l`、`scripts/smoke.sh`（回帰） | OK / ALL PASS |
| `bench` 1MB × 3 | total 20〜21ms（read 1.3〜1.7 / write 2.8〜2.9 / put 12.7〜13.7ms） |
| `bench` 10MB × 3 | total 131〜172ms（read 19.6〜39.0 / write 30.2〜37.7 / put 78.3〜100.4ms） |
| `bench` 50MB × 3 | total 711〜740ms（read 102〜117 / write 157〜165 / put 445〜475ms）。**メモリエラーなし**（128M） |
| `double-submit` 5 本 | 全部 303、counter 10 → 15（+5）、`GET /` 200。ログの `lock` は 0.0 / 7.8 / 9.6 / 9.8 / 14.4ms と順に増える（直列化されている） |

修正前のコードで更新が失われることは、この環境では窓が数 ms しかないので再現を試みていない。実機（write 0.2 秒）では再現しうるが、修正後のコードで「失われない」ことを確認する方を優先する。

## 8. 実機での確認結果

2026-09-18（JST）、Dev Container から §3 を実施。リビジョン `poc-app-00012`（`bench` / `double-submit`）→ `00013`（`restart-verify` 以降）。結果の全文は PR #19 のコメント。

| 確認 | 結果 | 備考 |
|---|---|---|
| `/health`（基準） | 158 / 72 / 69 ms | 初回は接続確立込み。ウォームで約 70ms |
| `bench` 1MB × 3 | total **1723 / 500 / 445 ms**。read 47.2 / 6.0 / 2.9、write 249.8 / 235.5 / 210.3、put 548.5 / 194.4 / 157.5 ms | 1 回目は新リビジョン直後。put に WIF 初回取得（STS）が入り、total にも約 0.9 秒の未計上分（初回接続・プロセス起動と推定）。2 回目以降は 0.45〜0.5 秒 |
| `bench` 10MB × 3 | total 919 / 762 / 862 ms。read 60.7 / 23.2 / 25.9、write 415.3 / 410.5 / 422.4、put 360.6 / 263.2 / 344.0 ms | S3 27.7〜38.0 MB/s |
| `bench` 50MB × 3 | total **2450 / 2701 / 2777 ms**。read 154.9 / 159.4 / 125.5、write 1333.1 / 1540.3 / 1620.8、put 899.3 / 914.7 / 973.5 ms | S3 51.4〜55.6 MB/s。`memory_limit` 128M で通った（ストリーム PUT） |
| `pad 0`（50MB → 208 バイト） | write 656.9ms | 小さく書き戻すだけでも既存の 50MB オブジェクトのダウンロードが要る（gcsfuse の staged write。docs/01 §4） |
| S3 転送（GCP asia-northeast1 → S3 ap-northeast-1） | 1MB 0.16〜0.19 秒、10MB 0.26〜0.36 秒、50MB 0.90〜0.97 秒 ≒ 51〜56 MB/s | #11 の入力。1MB はレイテンシ支配（約 150ms） |
| `double-submit` 5 本 | 全部 303。total 363 / 664 / 952 / 1215 / 1505 ms（約 290ms 間隔で順に完了）、read 0.4〜0.7 / write 168〜187 / put 93〜128 ms。counter 16 → 21 | 直列化されている（各リクエストの処理 = write 0.18 秒 + put 0.1 秒 ≒ 0.29 秒 = 完了間隔）。ログの `lock=` は未取得だが total の階段で確認できる |
| インスタンス入れ替え | mark: counter 22 / fs-check 1789686928 / instance `1f7cc46a` / rev 00012 → verify: instance `c2c29c16` / rev 00013、`instance_changed: true`、`fresh: true` | 新インスタンスで最新の JSON を読めた |
| 入れ替え後の `smoke.sh`（Cloud Run 向け） | `/health` 200、`GET /` 200、`POST /update` **303**、更新値の表示 PASS。**S3 の確認だけ FAIL**（つまずいた点 1） | `POST /update` が 303 = 新インスタンスで WIF を取り直して S3 PUT まで成功している（ログの `wif: credentials refreshed` は未取得。任意） |

### つまずいた点 1: Cloud Run に向けた `smoke.sh` の S3 確認が FAIL（2026-09-18）

`FAIL: s3://<bucket>/data.json の内容が一致しない` と出たが、アプリ側は `POST /update` が 303 で S3 PUT まで成功している。原因は Dev Container 側の `aws` CLI の認証: `.env` の moto 用 `AWS_ACCESS_KEY_ID=test` が環境変数に残っている、または `AWS_PROFILE` 未設定 / SSO トークン切れで `aws s3 cp` 自体が失敗し、`2>/dev/null` でエラーが捨てられて「一致しない」と表示された。対処: `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; export AWS_PROFILE=<profile>`（必要なら `aws sso login --use-device-code --profile <profile>`）してから再実行。`smoke.sh` は取得失敗と内容不一致を区別して表示するように直した（取得失敗ならエラーの 1 行目と確認コマンドを出す）。

## 9. #9 / #11 への引き継ぎ

- **#9（コールドスタート）**: ウォームな `/health` は約 70ms（初回接続込みで 160ms）が基準。新リビジョン直後の初回 `POST /update` は 1MB で 1.7 秒（2 回目以降 0.45 秒）で、差の約 1.2 秒が WIF の初回取得 + 初回接続 + gcsfuse の初回 read。コンテナ起動そのものの時間（startup probe まで）は #9 で測る
- **#11（コスト）**: S3 転送は 1MB 0.16〜0.19 秒、50MB 0.9〜1.0 秒 ≒ 55 MB/s。GCP → AWS の下り転送量 = JSON サイズ × 更新回数（1MB 未満 × 少数回なら無視できる）
