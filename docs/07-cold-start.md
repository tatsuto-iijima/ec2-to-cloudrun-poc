# 07. コールドスタート計測と許容レスポンスタイムの評価

対応 Issue: #9（親 Issue #1）
前提: **Web アプリは一人で操作する。複数人での同時使用は禁止。** 利用頻度が低く、コールドスタートに当たりやすい想定。Cloud Run は `max-instances=1`。

## 1. 結論

（実機の結果を反映してから確定する。§8 に記入）

- 許容レスポンスタイム（仮）: **アイドル後の初回リクエストの p95 < 3 秒**（Issue #9 の例。ユーザーと合意して確定する）
- 4 構成（`min-instances` 0 / 1 × startup CPU boost あり / なし）の p50 / p95 と、許容値を満たす構成とそのコストは §4 / §6

## 2. 検証方法

### なぜ「アイドルで落としてから 1 リクエスト」で測るか

新リビジョンをデプロイすると、Cloud Run は起動プローブのためにインスタンスを先に起こし、そのまま待機させる（#7 の `restart-verify` でインスタンス ID が変わったのはこれ）。そのため「デプロイ直後の 1 リクエスト」は利用者が体感するコールドスタート（アイドルでインスタンスが 0 台になった後の初回）ではない。本レポートでは **アイドル（既定 16 分。Cloud Run は最長 15 分アイドルでインスタンスを落とす）で確実に 0 台にしてから 1 リクエスト**を投げ、その TTFB（`curl` の `time_starttransfer`）を「初回」とする。

### コールドだったかの判定（`X-Instance-Id` / `X-Instance-Uptime`）

アプリは全応答に `X-Instance-Id`（`/tmp/instance-id` に置いた乱数。インスタンスが入れ替わると変わる）と `X-Instance-Uptime`（そのインスタンスが最初のリクエストを受けてからの秒数）を付ける（`app/src/InstanceInfo.php`）。起動プローブ（`GET /health`）が必ず最初のリクエストになるので、uptime はプローブ成功からの経過秒数に近い。

- **コールド** = ID が前回と変わり、かつ uptime ≤ `COLD_MAX_UPTIME`（既定 10 秒）。このリクエストが原因で起動したインスタンス
- ID が同じ = まだ落ちていなかった（アイドルが足りない）。ID が変わったが uptime が大きい = 何かが先に起こしていた（デプロイなど）。どちらも採用せず、待ち時間を延ばして再試行

### gcsfuse の寄与の分離

1 回のコールドスタートで測れる「初回」は 1 つなので、奇数回目は `GET /`（gcsfuse 上の JSON を読む）、偶数回目は `GET /health`（ファイルにも S3 にも触らない）を初回にし、直後にもう一方を「同一インスタンスの 2 回目」として測る。`/`（初回）− `/health`（初回）が gcsfuse 初回アクセス + PHP の JSON 処理の寄与。Issue の `/healthz` は Cloud Run の予約パスで使えないので `/health`（docs/03 つまずいた点 5）。

### `scripts/cold-start.sh`

| サブコマンド | 内容 |
|---|---|
| `sample` | `IDLE` 秒待つ → 初回（`/` または `/health`）を計測 → コールド判定 → 直後に 2 回目 → jsonl に追記。コールド標本が `N`（既定 5）個集まるまで繰り返す（コールドでなければ `EXTRA` 秒延ばす）。構成ラベルは `terraform output cold_start_config`（`min0-boost0` 等）。ID トークンは 1 時間で切れるので毎回取り直す |
| `report` | jsonl を構成 × パス × 種別（`first(cold)` / `second(同一インスタンス)` / `first(warm, 不採用)`）で集計し、n / p50 / p95 / min / max を表示 |
| `startup-log` | 直近の起動ログ（gcsfuse マウント完了 → Apache 起動 → 起動プローブ成功）を時刻付きで表示。差がコンテナ起動の内訳 |
| `image-size` | Artifact Registry のレイヤー合計サイズ |

## 3. 手順（Dev Container 内で実施）

1 標本に `IDLE`（16 分）以上かかるので、`nohup` で流して放置する。4 構成 × `N=5` で約 6 時間、Issue の 10 回にするなら `N=10` で約 11 時間。

```bash
export BASE_URL=$(terraform -chdir=terraform/gcp output -raw service_url)

# 構成 1: min 0 / boost なし（既定）。tfvars に何も書かなければこの構成
sed -i '/^min_instances\|^startup_cpu_boost/d' terraform/gcp/terraform.tfvars
terraform -chdir=terraform/gcp apply
nohup scripts/cold-start.sh sample > cold-start.log 2>&1 &     # 進捗は tail -f cold-start.log
#   ... 終わるのを待つ（cold-start.log の末尾に「コールド標本 N 個」が出る）

# 構成 2: min 0 / boost あり
echo 'startup_cpu_boost = true' >> terraform/gcp/terraform.tfvars && terraform -chdir=terraform/gcp apply
nohup scripts/cold-start.sh sample > cold-start.log 2>&1 &

# 構成 3: min 1 / boost あり（常時 1 台。課金が発生するので計測が終わったら戻す）
echo 'min_instances = 1' >> terraform/gcp/terraform.tfvars && terraform -chdir=terraform/gcp apply
nohup scripts/cold-start.sh sample > cold-start.log 2>&1 &     # min 1 ではコールドにならず「warm（採用しない）」が続く。その TTFB が「アイドル後の初回」なので MAX_TRIES=5 で打ち切ってよい

# 構成 4: min 1 / boost なし
sed -i '/^startup_cpu_boost/d' terraform/gcp/terraform.tfvars && terraform -chdir=terraform/gcp apply
MAX_TRIES=5 nohup scripts/cold-start.sh sample > cold-start.log 2>&1 &

# 集計・付随情報
scripts/cold-start.sh report
scripts/cold-start.sh startup-log
scripts/cold-start.sh image-size

# 後片付け: min 0 / boost なしに戻す
sed -i '/^min_instances\|^startup_cpu_boost/d' terraform/gcp/terraform.tfvars && terraform -chdir=terraform/gcp apply
```

- `min_instances=1` の構成ではインスタンスが落ちないので `sample` は全部「warm（採用しない）」になる。`report` の `first(warm, 不採用)` 行がその構成の「アイドル後の初回」（`cpu_idle=true` なのでアイドル中は CPU が絞られる。その影響が出るか見る）
- 計測中は他の操作（ブラウザで開く、`smoke.sh` など）をしない。アイドルが途切れる

## 4. 合否基準と結果

合否基準（Issue #9）: 各構成の p50 / p95 が記録され、許容レスポンスタイムを満たす構成とそのコストが明示されていること。許容値（仮）: **初回の p95 < 3 秒**。

| 構成 | `/` 初回 p50 / p95 | `/health` 初回 p50 / p95 | 2 回目（同一インスタンス）`/` / `/health` | 許容値 | 月額の増分 |
|---|---|---|---|---|---|
| min 0 / boost なし（現行既定） | （記入） | （記入） | （記入） | （記入） | 0 |
| min 0 / boost あり | （記入） | （記入） | （記入） | （記入） | 0（起動中の CPU 分のみ） |
| min 1 / boost あり | （記入） | （記入） | （記入） | （記入） | §6 |
| min 1 / boost なし | （記入） | （記入） | （記入） | （記入） | §6 |

## 5. 起動時間の内訳（記入欄）

`startup-log` の出力から: gcsfuse `File system has been successfully mounted.` → Apache `resuming normal operations` → `STARTUP HTTP probe succeeded` の時刻差。#5 の起動ログ（docs/03 §6）では gcsfuse 3.11.3 のマウント → Apache 2.4.68 / PHP 8.3.33 起動 → プローブ 2 回目で成功だった。

| 項目 | 値 |
|---|---|
| イメージサイズ（`image-size`） | （記入） |
| gcsfuse マウント完了 → プローブ成功 | （記入） |
| 起動プローブ設定 | `GET /health`、`initial_delay 0` / `period 2` / `timeout 2` / `failure_threshold 15`（docs/03）。period を 1 秒にすれば最大 1 秒縮む余地がある |

## 6. `min-instances=1` の月額概算（#11 の入力）

常時 1 台を待機させる分の課金（リクエスト処理中の課金は構成によらず同じ）。Cloud Run のリクエストベース課金では、待機中の最小インスタンスは「アイドル」の単価で vCPU 秒と GiB 秒が課金される。

```
月の秒数 = 30 日 × 86,400 = 2,592,000 秒
vCPU 秒 = 1 vCPU × 2,592,000 = 2,592,000 vCPU 秒
GiB 秒  = 0.5 GiB × 2,592,000 = 1,296,000 GiB 秒
月額 ≒ 2,592,000 × (アイドル vCPU 単価) + 1,296,000 × (アイドル GiB 単価)
```

単価は #11 で Cloud Run の料金表（asia-northeast1 は Tier 2）から確定する。参考として、アイドル vCPU 単価を $0.0000025 / vCPU 秒、アイドルメモリ単価を $0.0000025 / GiB 秒と置くと **約 $10 / 月**（要確認。無料枠の適用前）。`min-instances=0` ならこの分は 0。

## 7. この環境での検証結果

2026-09-18、PHP 8.4 内蔵サーバー（実機では測れないのでハーネスの確認のみ）。

| 確認内容 | 結果 |
|---|---|
| `php -l`（`InstanceInfo.php` / `FsCheck.php` / `index.php`） | OK |
| `terraform fmt` / `validate`（`min_instances` / `startup_cpu_boost` / `cold_start_config`） | Success（google provider 8.2.0 で `startup_cpu_boost` を受け付ける） |
| `/health` と `/` の応答ヘッダー | `X-Instance-Id: 7face1f5`、`X-Instance-Uptime: 0` → 2 秒後 `2` |
| `sample`（`/tmp/instance-id` を消してコールドを模擬、`IDLE=3 N=3`） | 3 回とも `COLD`（ID が変わり uptime 0）。奇数回目 `/`、偶数回目 `/health` が初回になり、2 回目も記録される |
| `report` | label × path × 種別ごとに n / p50 / p95 / min / max が出る |

## 8. 実機での確認結果

（ユーザーの手元で §3 を実施して記入する）

| 構成 | `report` の行 | `startup-log` の要点 |
|---|---|---|
| min 0 / boost なし | （記入） | （記入） |
| min 0 / boost あり | （記入） | （記入） |
| min 1 / boost あり | （記入） | |
| min 1 / boost なし | （記入） | |

## 9. #10 / #11 への引き継ぎ

- **#10（運用）**: コールドスタートを避けたい時間帯だけ `min-instances=1` にする運用（スケジュールで `gcloud run services update --min-instances`）は運用面の選択肢。起動プローブの period 短縮も同様
- **#11（コスト）**: §6 の式に料金表の単価を入れて `min-instances=1` の月額を確定する。`min-instances=0` の場合の課金はリクエスト処理中（`POST /update` 0.5 秒 × 回数、docs/06）だけ
