# 01. 移行対象データの棚卸しと gcsfuse 互換性の事前評価

対応 Issue: #3（親 Issue #1）
前提: **Web アプリは一人で操作する。複数人での同時使用は禁止。** Cloud Run は `max-instances=1` を基本構成とする。

## 1. 結論

- gcsfuse（Cloud Run の Cloud Storage ボリューム）で置き換える対象は **JSON マスタファイルのみ**。マウント先 `/mnt/data` に置き、アプリには `DATA_DIR` で渡す
- 現行実装の操作（`LOCK_EX` 付き上書き、読み込み、ディレクトリ走査）は、机上評価では **そのまま動く見込み**。ただし次の 3 点は実機で確認する（#7）
  1. `flock` / `LOCK_EX` の戻り値（ロックはカーネル内ローカルで成功する見込み。GCS には伝播しない）
  2. 一時ファイル + `rename` の動作と所要時間
  3. インスタンス再起動直後に読む JSON の鮮度
- 既存ファイルの上書きは「オブジェクト全体をダウンロード → 全体を再アップロード」になるが、**各 1MB 未満**なので実用上の問題にはならない見込み。所要時間は #7 で計測する
- gcsfuse の同時書き込み制約（先に close した側が勝つ）は、前提条件（一人で操作・`max-instances=1`）により対象外
- 判定: **Issue #1 のオープンな論点 2 件は解消。** 移行対象は確定し、衝突点はすべて「そのまま動く」か「実機で要確認」に分類できた。「実装修正が必要」と確定した項目は無い

## 2. 現行アプリのローカル FS 利用の棚卸し

ユーザーへの確認結果（2026-09-13）に基づく。

| 分類 | 現行の内容 | 有無 | 備考 |
|---|---|---|---|
| JSON マスタファイル | アプリが読み書きし、更新のたびに S3 へアップロードする JSON 本体 | **あり** | **ローカルがマスター、S3 は配布先**。S3 から読み戻すことはない。少数ファイル、各 1MB 未満。書き込みは `LOCK_EX` / `flock` を使う |
| PHP セッション（ファイル保存） | `session.save_handler=files` による `/var/lib/php/sessions` 等への保存 | なし | 将来使う場合は Cookie ベース（または Memorystore）とし、`/mnt/data` にセッションファイルを置かない |
| 一時ファイル・アップロードファイル | フォームからのアップロード、処理中の一時ファイル | なし | PHP の `upload_tmp_dir` / `sys_temp_dir` は既定の `/tmp` のままでよい |
| アプリログ・その他 | 独自ログファイル、キャッシュ、設定ファイルの動的更新 | なし | Apache の access/error ログはコンテナでは stdout/stderr へ出し、Cloud Logging に収集させる |

## 3. Cloud Run 上での置き場所の決定

| データ | 置き場所 | 理由 | 注意点 |
|---|---|---|---|
| JSON マスタ | `/mnt/data`（Cloud Storage ボリューム、`DATA_DIR=/mnt/data`） | EC2 のローカルディスク相当として永続化する。インスタンス入れ替えでも失われない | 書き込みは全体再アップロード。`max-instances=1` で単一マウントに固定する |
| 一時ファイル | `/tmp` | コンテナの書き込み可能領域。高速 | Cloud Run では書き込み可能 FS はインメモリで、インスタンスのメモリ上限を消費する。大きな一時ファイルを置かない（#8 で実機確認） |
| ログ | stdout / stderr | Cloud Logging に自動収集 | ファイルに書かない |
| セッション | 使わない | 現行アプリに無い | 必要になったら Cookie ベース |

## 4. gcsfuse の制約一覧（出典付き）

gcsfuse リポジトリ（コミット `19e19b0` 時点の `docs/`）とソースコード、Terraform provider のドキュメントから確認した事実。

| 項目 | 事実 | 出典 |
|---|---|---|
| ファイルロック | gcsfuse が使う FUSE ライブラリ jacobsa/fuse は、INIT 応答で `FUSE_POSIX_LOCKS` / `FUSE_FLOCK_LOCKS` を立てず（`InitBigWrites` と `InitAsyncRead` のみ）、`SETLK` / `GETLK` / `SETLKW` の op も処理しない。Linux の FUSE はこの場合ロックをカーネル内でローカルに処理するため、`flock()` / `fcntl()` は**成功するが、同一マウント（= 同一インスタンス）内でのみ有効**。GCS 側には伝播しない | jacobsa/fuse `connection.go`（INIT フラグ）、`internal/fusekernel/fuse_kernel.go`（`InitPosixLocks`, `InitFlockLocks`, `OpSetlk` の定義のみ） |
| 既存ファイルの変更 | オブジェクト全体をローカル一時領域にダウンロードし、`close` / `fsync` 時に**全体を新しい世代として再アップロード**する | gcsfuse `docs/semantics.md` Writes（Staged writes） |
| 追記 | 元ファイルが 2MB 以上なら追記分のみアップロード。それ未満は全体再アップロード | 同上 |
| 新規ファイルの順次書き込み | v3.0 以降は streaming write が既定。`close` で finalize され、finalize されたオブジェクトだけが見える。書き込み中に rename / read / truncate すると finalize され、以降は staged write に戻る | 同上（Streaming writes） |
| rename（ファイル） | GCS の rename API を使う（`--enable-atomic-rename-object` 既定有効）。高 QPS（1000 QPS 超）で 5xx になる既知問題があり、フラグで無効化できる | `docs/known-issues.md` |
| rename（ディレクトリ） | 階層型名前空間バケットでは原子的に可能。フラットバケットでは既定で不可（`--rename-dir-limit` で非原子的に許可可） | `docs/semantics.md` Missing features |
| メタデータキャッシュ | stat cache / type cache は既定 TTL 60 秒（`metadata-cache: ttl-secs`）。0 で毎回 GCS と照合、-1 で無期限。高性能マシンでは stat cache TTL 無限が既定になる版がある | `docs/semantics.md` Caching、`docs/troubleshooting.md` |
| ファイルキャッシュ | 既定無効。有効時は TTL 内なら GCS に問い合わせずローカルから返す | `docs/semantics.md` File caching |
| 同時書き込み | 同一ファイルを複数が開いて書くと、**先に close / sync した側が勝ち**、後から close した側は世代不一致で失敗する | `docs/semantics.md` Concurrency |
| 非対応の操作 | 拡張属性（xattr）、ハードリンク、`fallocate`、`SyncFS` は `ENOSYS`。パーミッションと所有者は変更できない（変更要求は成功するように見えるが反映されない）。mtime 以外の時刻（atime, ctime）は追跡しない | `docs/troubleshooting.md`、`internal/fs/fs.go` |
| Cloud Run 側の要件 | Cloud Storage ボリュームは**第2世代実行環境のみ**。Terraform は `google_cloud_run_v2_service` の `volumes { gcs { bucket, read_only, mount_options } }` で設定し、`mount_options` で gcsfuse のフラグを渡せる | terraform-provider-google `cloud_run_v2_service` |
| Cloud Run 側の FS | コンテナの書き込み可能領域（`/tmp` を含む）はインメモリで、インスタンスのメモリ上限に算入される | Cloud Run コンテナ契約（今回の作業環境からは公式ページを取得できなかったため、#8 で実機確認する） |

## 5. 衝突表: 現行実装の操作 × gcsfuse 制約

判定の凡例: **動く** = そのまま動く見込み / **修正** = 実装修正が必要 / **要確認** = 実機で確認（#7 の項目番号を併記）

| # | 現行実装の操作 | gcsfuse での挙動 | 判定 | #7 対応 | 回避策・備考 |
|---|---|---|---|---|---|
| 1 | `file_put_contents($path, $json, LOCK_EX)` で既存 JSON を上書き | ロックはカーネル内ローカルで成功する見込み。書き込みは全体ダウンロード + 全体再アップロード（1 GET + 1 PUT 相当）。1MB 未満なら所要時間は小さい見込み | 要確認 | (a) (c) | 失敗する場合は `LOCK_EX` を外す（単一利用者前提のためロック不要）。所要時間は (f) で計測 |
| 2 | `flock($fp, LOCK_EX)` で明示的にロック | 同上。**同一インスタンス内の並行リクエストは直列化される**（二重送信対策として #8 で利用できる） | 要確認 | (c) | 失敗する場合は #1 と同じ |
| 3 | 一時ファイルに書いてから `rename()` で差し替え | 一時ファイルは新規オブジェクト（streaming write、close で finalize）。`rename` は GCS の rename API。同一ディレクトリ内なら 1 オブジェクト操作。原子性は保たれる見込みだが所要時間は未知 | 要確認 | (b) | 一時ファイルは同じディレクトリに置く（ディレクトリをまたぐ rename を避ける） |
| 4 | `file_get_contents` + `json_decode` で読み込み | 1 GET。stat cache 60 秒は同一インスタンスからの書き込みでは無効化されるため、自分の書いた内容は即座に読める | 動く | (a) | なし |
| 5 | `glob("$DATA_DIR/*.json")` / `scandir` でディレクトリ走査 | LIST 操作（type cache 60 秒）。少数ファイルなら問題なし | 動く | 付随 | ファイル数が増えたら LIST 回数を意識する |
| 6 | 同一リクエスト内で write → read | 同一 gcsfuse プロセスなので整合する | 動く | (a) | なし |
| 7 | インスタンス再起動（新インスタンス）直後の read | 新しいマウントで、キャッシュは空。最新世代を読む見込み | 要確認 | (e) | 古い内容が見えた場合は `mount_options` で `metadata-cache-ttl-secs=0` を検討 |
| 8 | `FILE_APPEND` で追記 | 1MB 未満は全体再アップロード（2MB 以上なら追記分のみ） | 動く（現行は未使用） | (d) | 記録のみ |
| 9 | `chmod` / `chown` / `touch` | `chmod` / `chown` は反映されない（エラーにもならない）。`touch` は mtime のみ更新 | 動く | 付随 | パーミッション判定（`is_writable` 等）に依存しない実装にする |
| 10 | ハードリンク / xattr / `fallocate` | `ENOSYS` | 動く（現行は未使用） | なし | 使わない |
| 11 | 複数インスタンスからの同時書き込み | 先に close した側が勝つ | 対象外 | なし | 前提条件（一人で操作、`max-instances=1`）により発生しない |
| 12 | 更新後に S3 へ PUT（AWS SDK） | gcsfuse とは無関係。`/mnt/data` から読んだ内容をそのまま PUT | 動く | なし | S3 認証は #6 |

「修正」と確定した行は無い。「要確認」の行はすべて #7 の (a)〜(f) に対応づけた。

## 6. Cloud Run 側の前提とマウントオプション方針

- 第2世代実行環境（`EXECUTION_ENVIRONMENT_GEN2`）を指定する。Cloud Storage ボリュームは第1世代では使えない
- Terraform では次の形で設定する（#5 で実装）

  ```hcl
  template {
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
    containers {
      volume_mounts {
        name       = "data"
        mount_path = "/mnt/data"
      }
    }
    volumes {
      name = "data"
      gcs {
        bucket        = google_storage_bucket.data.name
        read_only     = false
        mount_options = [] # まずは既定で検証する
      }
    }
  }
  ```

- PoC はまず **既定のマウントオプション**で検証し、#7 の結果に応じて `metadata-cache-ttl-secs`（鮮度）や `implicit-dirs`（ディレクトリ扱い）を調整する
- `/tmp` はインメモリなので、一時ファイルは小さく保ち、処理後に削除する

## 7. #7（gcsfuse マウント領域での JSON 読み書き検証）に引き継ぐ実機確認項目

| #7 項目 | 確認内容 | 本レポートの根拠行 |
|---|---|---|
| (a) | read-modify-write が成立すること | 衝突表 #1, #4, #6 |
| (b) | 一時ファイル + `rename` の動作と所要時間。原子性（rename 中に中途半端な内容が見えないこと） | 衝突表 #3 |
| (c) | `file_put_contents(..., LOCK_EX)` と `flock()` の戻り値。同一インスタンス内で 2 リクエストを同時に投げたときに直列化されるか | 衝突表 #1, #2 |
| (d) | `FILE_APPEND` の動作と所要時間（記録のみ） | 衝突表 #8 |
| (e) | インスタンス再起動直後に読んだ JSON が最新であること | 衝突表 #7 |
| (f) | JSON サイズ別（例 100KB / 1MB / 10MB）の読み書きレイテンシ。現行は 1MB 未満なので 1MB を主ケースにする | 衝突表 #1 |
| 追加 | `chmod` の戻り値と `is_writable` の結果 | 衝突表 #9 |
| 追加 | `glob` 1 回あたりの LIST 回数（Cloud Logging または gcsfuse ログで確認できれば） | 衝突表 #5 |

## 8. 回避策の候補（gcsfuse が不成立の場合）

「少数ファイル・各 1MB 未満・S3 が配布先」という条件を使えば、gcsfuse を使わない構成も取れる。#7 で不成立が出た場合の比較対象として記録する。

| 案 | 内容 | 利点 | 欠点 |
|---|---|---|---|
| A | S3 をマスターにし、`/tmp` を作業領域にする（リクエストごとに S3 GET → 更新 → S3 PUT） | gcsfuse 不要。Cloud Storage も不要 | 「ローカルがマスター」という現行の運用が変わる。S3 への往復がリクエストごとに発生 |
| B | Cloud Storage を SDK 経由で直接読み書きする（FUSE をバイパス） | generation precondition による楽観ロックが使える。FUSE の制約を受けない | アプリのファイル I/O をすべて SDK 呼び出しに書き換える必要がある |

## 9. 出典

- gcsfuse `docs/semantics.md`、`docs/troubleshooting.md`、`docs/known-issues.md`（GoogleCloudPlatform/gcsfuse、コミット `19e19b0`）
- gcsfuse `internal/fs/fs.go`（`GetXattr` / `ListXattr` / `SyncFS` が `ENOSYS`）
- jacobsa/fuse `connection.go`（INIT フラグ）、`internal/fusekernel/fuse_kernel.go`（`InitPosixLocks`, `InitFlockLocks`, `OpSetlk` 等の定義）
- terraform-provider-google `website/docs/r/cloud_run_v2_service.html.markdown`（GCS ボリュームと第2世代要件）
- Cloud Run コンテナ契約（インメモリ FS。作業環境から取得できなかったため #8 で実機確認）
