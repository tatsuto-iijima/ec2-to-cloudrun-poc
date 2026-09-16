# 06. リクエストタイムアウト・ステートレス性の検証

対応 Issue: #8（親 Issue #1）
前提: **Web アプリは一人で操作する。複数人での同時使用は禁止。** Cloud Run は `max-instances=1`。

## 1. 結論

（実機の結果を反映してから確定する。§8 に記入）

- 合否基準 1（処理時間がタイムアウトに対して十分な余裕を持つ）: この環境では 50MB の `POST /update` が 0.7 秒（§7）。実機の数値は §8
- 合否基準 2（インスタンス入れ替え後も操作が継続できる）: `/tmp` に置く状態は WIF のキャッシュとロックファイルだけで、消えても作り直される（§5）。実機確認は §8
- 合否基準 3（二重送信時の方針が決まり、動作確認済み）: **アプリ側で read-modify-write 全体を `flock` で直列化する**（`Updater`）。`concurrency` は 80 のまま（§6）。この環境で 5 本同時に投げて counter がちょうど +5

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
echo 'fs_check = true' >> terraform/gcp/terraform.tfvars
scripts/build-push.sh && terraform -chdir=terraform/gcp apply
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
| `POST /update` の実測（実機、50MB） | （記入） | §8 |

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

（ユーザーの手元で §3 を実施して記入する）

| 確認 | 結果 | 備考 |
|---|---|---|
| `/health`（基準） | （記入） | |
| `bench` 1MB × 3 | （記入） | read / write / put |
| `bench` 10MB × 3 | （記入） | |
| `bench` 50MB × 3 | （記入） | `memory_limit` 128M で通るか |
| S3 転送（put の MB/s、GCP asia-northeast1 → S3 ap-northeast-1） | （記入） | #11 の入力 |
| `double-submit` 5 本 | （記入） | counter +5、ログの `lock` |
| インスタンス入れ替え後の `smoke.sh` | （記入） | `wif: credentials refreshed` |

## 9. #9 / #11 への引き継ぎ

- **#9（コールドスタート）**: `bench` の `/health` の応答時間が「ウォームな 1 リクエスト」の基準。新インスタンスの初回は WIF の取り直し（約 1 秒）と gcsfuse の初回 read（40ms）が加わる
- **#11（コスト）**: S3 転送のレイテンシと MB/s（§8）。GCP → AWS の下り転送量は JSON サイズ × 更新回数
