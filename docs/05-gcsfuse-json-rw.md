# 05. gcsfuse マウント領域での JSON 読み書き検証

対応 Issue: #7（親 Issue #1）
前提: **Web アプリは一人で操作する。複数人での同時使用は禁止。** Cloud Run は `max-instances=1`。複数インスタンスからの同時書き込みは対象外。

## 1. 結論

- **(a)〜(f) と追加項目はすべて「そのまま動く」。実装修正が必要な項目は無い。** Issue #1 の検証項目「gcsfuse マウント領域で、アプリが期待する JSON の読み書きが成立するか」は**成立**（実機 2026-09-15、§6）
- read-modify-write、一時ファイル + `rename`（途中の内容は見えない）、`LOCK_EX` / `flock`（同一インスタンス内で直列化される）、`FILE_APPEND`、新インスタンスでの鮮度、100KB〜50MB の読み書きのすべてが成功した
- コストはローカルディスク比で **書き込み 1 回 0.1〜0.2 秒**（オブジェクト全体の再アップロード。1MB 未満ならサイズによらずほぼ一定）、**読み込み 40ms（同一インスタンスで読み直すと 1ms）**。現行アプリの「少数ファイル・各 1MB 未満・1 操作 1 更新」なら実用上の問題にならない
- 注意点は 2 つ。並行して読まれている最中の `rename` は稀に 4〜5 秒かかる（30 回中の最大値。平均 0.3 秒）。アプリ以外（`gcloud storage cp` 等）で書き換えたオブジェクトは **最大 60 秒間、古い内容が見える**（stat cache TTL）。どちらも「一人で操作・アプリだけが書く」前提では影響しない
- `mount_options` は既定 + `uid=33,gid=33` のまま変更しない。`chmod` は成功を返すが反映されない（既知）。パーミッションに依存しない現行実装のままでよい

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

`WRITE_MODE` について:

- `WRITE_MODE`（Terraform の `write_mode`）が効くのは、アプリ本体の `POST /update` が `data.json` を書き戻す方式（`JsonStore::write`）だけ。`/fs-check` はこの設定に依存しない。`rmw` は常に `LOCK_EX` 上書き、`rename` / `rename-loop` / `size` は常に一時ファイル + `rename` で、**両方式を毎回測る**（結果の `write_mode` はどちらの設定で測ったかの記録）。`WRITE_MODE` を変えて `scripts/fs-check.sh` を走らせ直す必要はない
- 実際の `POST /update` を rename 方式で動かした所要時間も見たい場合だけ、次を行う（環境変数だけの変更なので再ビルドは不要）

  ```bash
  echo 'write_mode = "rename"' >> terraform/gcp/terraform.tfvars
  terraform -chdir=terraform/gcp apply
  scripts/smoke.sh                                                                       # POST /update が rename 方式で走る
  gcloud run services logs read $(terraform -chdir=terraform/gcp output -raw service_name) --region asia-northeast1 --limit 20 | grep 'update key='   # mode=rename write=…ms
  sed -i '/^write_mode/d' terraform/gcp/terraform.tfvars && terraform -chdir=terraform/gcp apply   # lock に戻す
  ```

## 4. 合否基準と分類表

合否基準（Issue #7）: (a)〜(f) の結果がすべて記録され、各項目が「**そのまま動く** / **実装修正で回避可能**（修正内容と工数）/ **回避不可**」に分類されていること。

| 項目 | 確認内容 | 机上評価の見込み（docs/01） | 実機の結果 | 分類 |
|---|---|---|---|---|
| (a) | read-modify-write が成立する | 成立。既存ファイルの変更は全体ダウンロード + 全体再アップロード | 6 回すべて一致。read 初回 33〜44ms → 以後 0.5〜1.4ms、write（`LOCK_EX` 上書き）78〜194ms、reread 36〜52ms | **そのまま動く** |
| (b) | tmp + `rename` の動作と所要時間。途中の内容が見えないこと | GCS の rename API。同一ディレクトリなら 1 オブジェクト操作 | 1MB: write 138ms / rename 40〜114ms / read 77〜112ms、tmp 残らず。並行読み取り 5,075 回で途中の内容 0・欠落 0・JSON 不正 0。並行中の rename は平均 0.27〜0.33 秒、最大 4.3〜4.9 秒 | **そのまま動く**（並行読み取り中の rename の裾が重い点は記録） |
| (c) | `LOCK_EX` / `flock` の戻り値。同一インスタンス内で直列化されるか | ロックはカーネル内ローカルで成功。GCS には伝播しない | `file_put_contents(LOCK_EX)` 成功、`flock(LOCK_EX)` / `LOCK_NB` / `LOCK_UN` / 別ハンドルの `LOCK_SH` すべて true。後着の待ち **2.5 秒**（先着が 3 秒保持、0.5 秒後に開始）→ 直列化される | **そのまま動く**（#8 の二重送信対策に使える） |
| (d) | `FILE_APPEND` の動作と所要時間 | 1MB 未満は全体再アップロード | 1KB 追記 73〜224ms、1MB 追記 180〜205ms。1MB 超のファイルへの 1KB 追記も 180〜220ms（全体再アップロード） | **そのまま動く**（現行は未使用） |
| (e) | 新インスタンスで読んだ JSON が最新 | 新しいマウントでキャッシュは空。最新世代を読む | 旧インスタンスで書いた `counter=7` / `fs-check=1789471033` を、新リビジョン・新インスタンスで読んで一致（`instance_changed: true, fresh: true`） | **そのまま動く** |
| (f) | サイズ別（100KB / 1MB / 10MB）の読み書きレイテンシ | 未知。1MB が主ケース | 新規 / 上書き / tmp 書き / rename / 読み（ms）: 100KB 106 / 157 / 111 / 49 / 37、**1MB 104 / 166 / 124 / 47 / 38**、10MB 235 / 309 / 205 / 39 / 112、50MB 630 / 1045 / 600 / 60 / 376 | **そのまま動く**（1MB 未満は書き 0.1〜0.2 秒・読み 0.04 秒。50MB でも 1 秒） |
| 追加 | `chmod` の戻り値と `is_writable` | `chmod` は反映されない（エラーにもならない） | `chmod(0600)` は true だが `fileperms` は **666 のまま**。`is_writable` true。`touch` は mtime に反映される | **そのまま動く**（パーミッション判定に依存しない実装のまま） |
| 追加 | `glob` / `scandir` の所要時間 | LIST 1 回。少数ファイルなら問題なし | 10〜11 ファイルで `glob` 24〜26ms、`scandir` 28〜33ms。gcsfuse の readdir は `.` `..` を返さない | **そのまま動く** |
| 追加 | アプリ以外からの書き換えの見え方 | stat cache TTL 60 秒の間は古い内容が見える可能性 | `gcloud storage cp` 直後の `GET /` は**古い内容**、65 秒後に新しい内容 | **運用上の注意**（アプリ以外で書き換えたら 60 秒待つか新リビジョンにする。アプリだけが書く前提では影響なし） |

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

2026-09-15、Dev Container から `scripts/fs-check.sh all` を 2 回（2 回目は `SIZES=52428800`）、`restart-mark` → `gcloud run services update --update-env-vars` で新リビジョン → `restart-verify`、`external`、`cleanup` を実施。**全 case `ok: true`、`restart-verify` / `external` とも期待どおり**（結果の全行は PR #18 のコメント）。

環境: リビジョン `poc-app-00007` → `00008`、PHP 8.3.33（apache2handler）、`memory_limit` 128M、実行 uid/gid **33**、`/proc/mounts` は `fuse.gcsfuse rw,nosuid,nodev,relatime,user_id=0,group_id=0,default_permissions,allow_other`。

| 確認 | 結果 | 備考 |
|---|---|---|
| `info` | `DATA_DIR` あり・書き込み可、uid/gid 33 | docs/03 §6 補足の `uid:1033` は gcsfuse 側の表示。PHP は www-data（33）のまま、`allow_other` + file-mode 666 / dir-mode 777 で書けている。`mount_options` は現状維持 |
| (a) `rmw` ×3 ×2 回 | counter 1→6、毎回 reread 一致。read 44.3 / 1.4 / 0.8ms、write 78.5 / 191.5 / 193.7ms、reread 51.7 / 44.2 / 36.0ms（2 回目も同傾向） | 初回の read はオブジェクトの取得、2 回目以降は同一インスタンスのキャッシュ。write はサイズ 99 バイトでも 0.1〜0.2 秒 |
| (b) `rename` 1MB | write 138.0 / rename 114.1 / read 111.6ms（2 回目 139.3 / 39.9 / 76.8） | tmp は残らない |
| (b) `rename-loop` 30 回 + `read-loop` 10 秒 | 1 回目: 読み 3,366 回、欠落 0・途中 0・不正 0、18 版観測。rename min 40.7 / avg 334.0 / **max 4250.5ms**、30 回で 16.8 秒。2 回目: 読み 1,709 回、17 版観測。rename min 39.1 / avg 265.8 / max 4903.8ms | 途中の内容が見えないことは確認できた。並行読み取り中の rename は稀に 4〜5 秒かかる（原因は未特定。読み取り側がオブジェクトを開いている間の世代切り替えと推定）。単独の `rename` は 40〜114ms |
| (c) `lock` | `file_put_contents(LOCK_EX)` 256（98 / 163ms）、`flock(LOCK_EX)` true（0.1ms）、同一ハンドル `LOCK_NB` true、`LOCK_UN` true、別ハンドル `LOCK_SH\|LOCK_NB` true | docs/01 の予測どおりロックは成功する |
| (c) `lock-hold` 3 秒 + 0.5 秒後の 0 秒 | 後着の `wait_ms` **2514.6**（2 回目 2482.3）、先着は 0 | 同一インスタンス内で `flock` が直列化される |
| (d) `append` | 1KB: 73.2 / 181.1 / 158.7ms、1MB: 180.4ms。2 回目（既に 1MB 超）: 1KB 223.9 / 177.6 / 174.1ms、1MB 204.6ms。`filesize` は毎回期待どおり | 追記でも全体再アップロード（2MB 未満） |
| (e) `restart-mark` → `restart-verify` | mark: counter 7、value 1789471033、instance `3c866098`、rev 00007。verify: instance `2720df2d`、rev 00008、`instance_changed: true`、`fresh: true` | 新インスタンス（新しいマウント）で最新の JSON を読めた |
| (f) `size` | 100KB: create 105.9 / overwrite 157.4 / tmp 110.8 / rename 48.9 / read 37.1ms。1MB: 103.7 / 166.0 / 124.1 / 46.5 / 38.3。10MB: 235.4 / 308.6 / 205.2 / 38.9 / 112.0。50MB: 630.4 / 1044.6 / 599.8 / 59.6 / 375.9 | 上書きは新規作成より遅い（既存世代の扱いが増える）。50MB でも `memory_limit` 128M に収まった |
| 追加 `misc` | `chmod` true → perms **666**（反映されない）、`is_writable` true / dir true、`touch` true・mtime 反映、`glob` 10 件 24.2ms、`scandir` 28.3ms、`mkdir` / `rmdir` true | `scandir_count` が 2 少なく出た（gcsfuse は `.` `..` を返さないのに固定で 2 を引いていた集計側の不具合。修正済み） |
| 追加 `external` | before `EC2 to Cloud Run PoC` → `gcloud storage cp` 直後も同じ（古い）→ 65 秒後 `external-1789471131` | stat cache TTL 60 秒のとおり |
| `POST /update`（ログ） | `mode=lock read=102.7ms write=181.4ms put=1022.7ms` | アプリ本体の経路。S3 PUT の 1 秒は WIF の初回取得を含む（#8 で内訳を見る） |
| `smoke.sh` | 全て **403** | `smoke.sh` が ID トークンを付けないため（つまずいた点 3）。Cloud Run 側の問題ではない |

### つまずいた点 3: `scripts/smoke.sh` を Cloud Run に向けると 403

`smoke.sh` はローカル用に書いたので `Authorization` ヘッダを付けず、非公開の Cloud Run では全リクエストが 403 になった。対処: `fs-check.sh` と同じく、`BASE_URL` が `*.run.app` なら `gcloud auth print-identity-token` の ID トークンを自動で付ける（`TOKEN` で明示も可）。Cloud Run に向けるときは `DATA_DIR` を空にし、S3 の確認は実バケット + `AWS_PROFILE` で行う。

```bash
BASE_URL=$URL DATA_DIR= S3_ENDPOINT= S3_BUCKET=$(terraform -chdir=terraform/aws output -raw bucket_name) scripts/smoke.sh
```

## 7. #8 / #9 への引き継ぎ

- **#8（タイムアウト・ステートレス性）**: (c) で `flock` が同一インスタンス内で直列化されることを確認した（後着 2.5 秒待ち）ので、二重送信対策は `concurrency=1` にしなくても現行実装の `LOCK_EX` で直列化できる。`POST /update` の実測は read 0.1 秒 / write 0.2 秒 / S3 PUT 1.0 秒（WIF 初回込み）で、タイムアウト 300 秒に対して余裕がある
- **#9（コールドスタート）**: 新インスタンスの初回 read は 33〜44ms（2 回目以降 1ms）。`/tmp/fs-check-instance-id` の仕組みはインスタンスの入れ替わりの検出にそのまま使える
- マウントオプションは既定 + `uid=33,gid=33` のまま。アプリだけが書く前提では `metadata-cache-ttl-secs` を変えない（変えると毎回 GCS と照合してレイテンシが増える）。アプリ以外で書き換えたときは 60 秒待つか新リビジョンにする
- 並行読み取り中の `rename` の裾（最大 4〜5 秒）は現行の `WRITE_MODE=lock` では発生しない経路。`rename` 方式に切り替える場合の注意として残す
