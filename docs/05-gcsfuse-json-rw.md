# 05. gcsfuse マウント領域での JSON 読み書き検証

対応 Issue: #7（親 Issue #1）
前提: **Web アプリは一人で操作する。複数人での同時使用は禁止。** Cloud Run は `max-instances=1`。複数インスタンスからの同時書き込みは対象外。

## 1. 結論

（実機の結果を反映してから確定する。§6 に記入）

- 検証の仕組み（診断経路 `POST /fs-check` と `scripts/fs-check.sh`）はこの環境（ローカル FS）で全 case が通ることを確認した（§5）
- 実機（Cloud Run + Cloud Storage ボリューム）での (a)〜(f) と追加項目の結果、および「そのまま動く / 実装修正で回避可能 / 回避不可」の分類は §4 の表に記入する

## 2. 検証方法

### なぜアプリの中で測るか

gcsfuse の挙動はマウントオプション・実行ユーザー・プロセスモデル（mod_php はリクエストごとにプロセスが変わる）に左右されるため、**アプリと同じプロセス**（Apache + mod_php、www-data、Cloud Run が管理する同じマウント）で測る。サンプルアプリに診断用の経路 `POST /fs-check` を追加し、`scripts/fs-check.sh` が case ごとに呼んで結果を集める。

- 経路は環境変数 `FS_CHECK=1`（Terraform の `fs_check` 変数。既定 `false`）のときだけ有効。無効時は 404 で、存在しない経路と同じ扱い
- 検証用のファイルは `DATA_DIR/fs-check/` 配下に置き、`data.json` には触らない（(e) と `external` はアプリの通常経路 `POST /update` / `GET /` を使う）
- 結果は JSON で返し、スクリプトが `fs-check-results.jsonl`（gitignore 済み）に追記する。各結果に `instance`（後述）と `revision`（`K_REVISION`）が入る
- 経路名は末尾が `z` ではないので Cloud Run の予約済み URL パスに当たらない（docs/03 つまずいた点 5）

### インスタンスの識別

Cloud Run の `/tmp` はインスタンス単位のインメモリ FS なので、`/tmp/fs-check-instance-id` に初回アクセス時に乱数を置いておけば、同じインスタンスの間は同じ値、入れ替わると別の値になる。(e) ではこれでインスタンスの入れ替わりを確認する。

### case と検証項目の対応（`app/src/FsCheck.php`）

| case | 内容 | #7 項目 |
|---|---|---|
| `info` | `DATA_DIR` の存在 / `is_writable` / 空き容量、実行 uid・gid、`memory_limit`、`/proc/mounts` のマウント行 | 付随 |
| `rmw` | `rmw.json` を読み（無ければ初期値）→ `counter++` → `file_put_contents(LOCK_EX)` で書き戻し → 読み直して一致確認。read / write / reread の ms | (a) |
| `rename` | `size` バイトの JSON を同一ディレクトリの tmp に書き → `rename` → 読み直し。write / rename / read の ms、tmp が残っていないこと | (b) |
| `rename-loop` | 内容が丸ごと異なる JSON を `n` 回 tmp + `rename` で差し替える（`interval` ms 間隔） | (b) 原子性（書き手） |
| `read-loop` | `seconds` 秒間 `atomic.json` を読み続け、JSON 不正・先頭 `seq` と末尾 `seq_tail` の不一致（= 途中の内容）・一度読めた後の欠落を数える | (b) 原子性（読み手） |
| `lock` | `file_put_contents(LOCK_EX)` の戻り値、`flock(LOCK_EX)` / 同一ハンドルの `LOCK_EX\|LOCK_NB` / `LOCK_UN` / 別ハンドルの `LOCK_SH\|LOCK_NB` の戻り値 | (c) |
| `lock-hold` | `flock(LOCK_EX)` を取るまでの待ち時間を測り、`seconds` 秒保持して解放。2 リクエストを同時に投げ、後着の `wait_ms` が先着の保持時間に近ければ**同一インスタンス内で直列化**されている | (c) 直列化 |
| `append` | `append.log` に `FILE_APPEND \| LOCK_EX` で `size` バイト追記。ms と追記後の `filesize` | (d) |
| `size` | `size` バイトの JSON を新規作成 / `LOCK_EX` 上書き / tmp + `rename` / `file_get_contents` の 4 通りで計測。内容の一致確認 | (f) |
| `misc` | `chmod(0600)` の戻り値と直後の `fileperms`、`is_writable`、`touch` で mtime が変わるか、`glob` / `scandir` の件数と ms、`mkdir` / `rmdir` | 追加（#3 引き継ぎ） |
| `cleanup` | `fs-check/` 配下を削除 | 後片付け |

### `scripts/fs-check.sh` のサブコマンド

| サブコマンド | 内容 | #7 項目 |
|---|---|---|
| `all`（既定） | `info` → `rmw`×3 → `rename`（1MB）→ 原子性（`read-loop` 10 秒を先に始め、0.5 秒後から `rename-loop` 30 回 × 1MB を並行）→ `lock` → 直列化（`lock-hold` 3 秒と 0.5 秒後の `lock-hold` 0 秒を並行）→ `append`（1KB×3、1MB）→ `size`（`SIZES`。既定 100KB / 1MB / 10MB）→ `misc` | (a)(b)(c)(d)(f) 追加 |
| `restart-mark` | `POST /update`（`key=fs-check`、`value=<epoch>`）→ `GET /` の `counter` と `info` の `instance` / `revision` を記録 | (e) 前半 |
| `restart-verify` | `instance` が変わっていること、`GET /` の `counter` / `fs-check` が記録と一致することを PASS / FAIL 表示 | (e) 後半 |
| `external` | `GET /` で読ませて stat cache を温め → `gcloud storage cp` で `data.json` の `message` を直接書き換え → 直後と 65 秒後の `GET /` で反映有無を表示 | 追加（アプリ以外からの書き換えの見え方 = metadata cache TTL 60 秒の確認。一人で操作・アプリだけが書く前提では対象外だが運用上の注意として記録） |
| `cleanup` | `fs-check/` を削除 | 後片付け |

「同一利用者の連続操作で古い内容が見えないこと」（(e) 後半）は、`rmw` の書き戻し直後の再読と、`scripts/smoke.sh`（`POST /update` → `GET /` に更新値が出る）で担保する。

## 3. 手順（Dev Container 内で実施）

```bash
# 1. 診断経路を有効にしてデプロイ（アプリが変わるので再ビルドが必要）
echo 'fs_check = true' >> terraform/gcp/terraform.tfvars
scripts/build-push.sh                          # 新しいイメージを push（image.auto.tfvars が更新される）
terraform -chdir=terraform/gcp apply           # FS_CHECK=1 と新イメージで新リビジョン

# 2. (a)(b)(c)(d)(f) と追加項目。ID トークンは自動取得（BASE_URL が run.app のとき）
export BASE_URL=$(terraform -chdir=terraform/gcp output -raw service_url)
scripts/fs-check.sh                            # 既定は all。結果は fs-check-results.jsonl に追記
SIZES="52428800" scripts/fs-check.sh           # 任意: 50MB（memory は 512Mi なので様子を見ながら）

# 3. (e) インスタンス再起動直後の鮮度
scripts/fs-check.sh restart-mark               # counter と instance を記録
#    15 分以上放置（アイドルでインスタンスが終了する）か、次で新リビジョンを作る（Terraform に差分が出るが後の apply で戻る）
gcloud run services update $(terraform -chdir=terraform/gcp output -raw service_name) --region asia-northeast1 --update-env-vars FS_CHECK_RESTART=$(date +%s)
scripts/fs-check.sh restart-verify             # instance が変わり、counter / fs-check が一致すれば PASS

# 4. 追加: アプリ以外からの書き換えの見え方（stat cache TTL）
scripts/fs-check.sh external                   # 直後 / 65 秒後の GET / で message が変わるか

# 5. 後片付け（fs-check/ を消し、診断経路を無効に戻す）
scripts/fs-check.sh cleanup
sed -i '/^fs_check/d' terraform/gcp/terraform.tfvars      # Dev Container（GNU sed）。macOS のホストで実行するなら sed -i '' '/^fs_check/d' ...
terraform -chdir=terraform/gcp apply           # FS_CHECK が空になり、FS_CHECK_RESTART も消える

# 参考: gcsfuse 側のログ（マウント時のオプション、エラー）
gcloud run services logs read $(terraform -chdir=terraform/gcp output -raw service_name) --region asia-northeast1 --limit 200 | grep -iE 'gcsfuse|fs-check|update '
```

`WRITE_MODE=rename` の挙動も見る場合は `write_mode = "rename"` を tfvars に書いて apply し、`rmw` と `scripts/smoke.sh` を再実行する（`fs-check` 自体は両方式を毎回測るので不要）。

## 4. 合否基準と分類表

合否基準（Issue #7）: (a)〜(f) の結果がすべて記録され、各項目が「**そのまま動く** / **実装修正で回避可能**（修正内容と工数）/ **回避不可**」に分類されていること。

| 項目 | 確認内容 | 机上評価の見込み（docs/01） | 実機の結果 | 分類 |
|---|---|---|---|---|
| (a) | read-modify-write が成立する | 成立。既存ファイルの変更は全体ダウンロード + 全体再アップロード | （記入） | （記入） |
| (b) | tmp + `rename` の動作と所要時間。途中の内容が見えないこと | GCS の rename API。同一ディレクトリなら 1 オブジェクト操作 | （記入） | （記入） |
| (c) | `LOCK_EX` / `flock` の戻り値。同一インスタンス内で直列化されるか | ロックはカーネル内ローカルで成功。GCS には伝播しない | （記入） | （記入） |
| (d) | `FILE_APPEND` の動作と所要時間 | 1MB 未満は全体再アップロード | （記入） | （記入） |
| (e) | 新インスタンスで読んだ JSON が最新 | 新しいマウントでキャッシュは空。最新世代を読む | （記入） | （記入） |
| (f) | サイズ別（100KB / 1MB / 10MB）の読み書きレイテンシ | 未知。1MB が主ケース | （記入） | （記入） |
| 追加 | `chmod` の戻り値と `is_writable` | `chmod` は反映されない（エラーにもならない） | （記入） | （記入） |
| 追加 | `glob` / `scandir` の所要時間 | LIST 1 回。少数ファイルなら問題なし | （記入） | （記入） |
| 追加 | アプリ以外からの書き換えの見え方 | stat cache TTL 60 秒の間は古い内容が見える可能性 | （記入） | （運用上の注意） |

## 5. この環境での検証結果（ローカル FS。ハーネスの確認と比較基準）

2026-09-15、PHP 8.4 内蔵サーバー（`PHP_CLI_SERVER_WORKERS=4`）+ ext4 上の `DATA_DIR`。gcsfuse ではないので**数値は比較基準**（ローカルディスクの下限）としてだけ使う。

| 確認内容 | 結果 |
|---|---|
| `php -l`（`FsCheck.php` / `Config.php` / `index.php`） | OK |
| `terraform fmt -check` / `validate`（`fs_check` 変数と `FS_CHECK` 環境変数） | Success |
| `FS_CHECK` 未設定で `POST /fs-check` | **404**（経路が無いのと同じ） |
| `scripts/smoke.sh`（moto。既存経路の回帰） | ALL PASS |
| `scripts/fs-check.sh all` | **ALL PASS**。要点は次のとおり |

| case | ローカル FS の結果 |
|---|---|
| `rmw` ×3 | counter 1→3、read 0.0–0.1ms / write 0.1ms / reread 0.0ms、再読一致 |
| `rename`（1MB） | write 0.4ms / rename 0.0ms / read 0.1ms、tmp 残らず |
| `rename-loop` 30 回 × 1MB + `read-loop` 10 秒 | rename 0.2ms、読み手は 158,441 回読んで **30 版すべて観測、途中の内容 0、欠落 0** |
| `lock` | `file_put_contents(LOCK_EX)` 256 / `flock(LOCK_EX)` true / 同一ハンドル `LOCK_NB` true / `LOCK_UN` true / 別ハンドル `LOCK_SH\|LOCK_NB` true |
| `lock-hold` 3 秒 + 0.5 秒後の `lock-hold` 0 秒 | 後着の `wait_ms` = **2497.9**（≈ 3000 − 500。同一プロセス群内で直列化） |
| `append` 1KB ×3、1MB | 0.0–0.1ms、1MB は 0.6ms。`filesize` が期待どおり増える |
| `size` 100KB / 1MB / 10MB | create 0.2 / 0.4 / 38.3ms、overwrite 0.4 / 0.3 / 2.3ms、tmp write 0.1 / 0.4 / 39.8ms、rename 0.1 / 0.1 / 0.6ms、read 0.1 / 0.1 / 5.0ms |
| `misc` | `chmod` true → perms 600（ローカルでは反映される）、`is_writable` true、`touch` で mtime 反映、`glob` 10 件 0.1ms、`mkdir` / `rmdir` true |

### つまずいた点 1: PHP 内蔵サーバーの既定は 1 ワーカーで並行が成立しない

`php -S` は既定で 1 リクエストずつ処理するため、`lock-hold` の後着が待たずに取れ（`wait_ms` = 0）、`read-loop` も `rename-loop` の完了後に動いていた。`PHP_CLI_SERVER_WORKERS=4` で起動すると並行になる。Apache（Cloud Run）は prefork の複数プロセスなので該当しない。

### つまずいた点 2: 並行開始の順序で書き手が遅れる

ワーカーを増やしても、`rename-loop` と `read-loop` を同時に投げると内蔵サーバーの振り分けで書き手のリクエストが読み手の完了後まで待たされることがあった（30 回の rename が 12ms で終わるので、読み手と重ならない）。対処: 読み手を先に開始して 0.5 秒後に書き手を開始し、書き手には反復間隔（既定 100ms）を持たせて、gcsfuse でもローカルでも確実に重なるようにした。

## 6. 実機での確認結果

（ユーザーの手元で §3 を実施して記入する）

| 確認 | 結果 | 備考 |
|---|---|---|
| `info`（uid / gid / mount 行） | （記入） | gcsfuse の起動ログでは `uid:1033 gid:1033`（docs/03 §6 補足） |
| (a) `rmw` | （記入） | |
| (b) `rename` / 原子性 | （記入） | |
| (c) `lock` / `lock-hold` | （記入） | |
| (d) `append` | （記入） | |
| (e) `restart-mark` → `restart-verify` | （記入） | |
| (f) `size` 100KB / 1MB / 10MB | （記入） | |
| 追加 `misc` | （記入） | |
| 追加 `external` | （記入） | |

## 7. #8 / #9 への引き継ぎ

- **#8（タイムアウト・ステートレス性）**: (c) で `flock` が同一インスタンス内で直列化できると確認できれば、二重送信対策として `concurrency` を 1 にする代わりに `flock` で直列化する選択肢が取れる（現行実装のまま）。(f) の所要時間はリクエストタイムアウトと比較する
- **#9（コールドスタート）**: (e) の `restart-verify` で新インスタンスの初回リクエストの所要時間が出るので参考にする。`/tmp/fs-check-instance-id` の仕組みはコールドスタートの検出にも使える
- マウントオプションは既定 + `uid=33,gid=33` のまま。`external` で古い内容が見えても、アプリだけが書く前提では変更不要。必要なら `metadata-cache-ttl-secs=0`（毎回 GCS と照合。レイテンシは増える）
