# 07. コールドスタート計測と許容レスポンスタイムの評価

対応 Issue: #9（親 Issue #1）
前提: **Web アプリは一人で操作する。複数人での同時使用は禁止。** 利用頻度が低く、コールドスタートに当たりやすい想定。Cloud Run は `max-instances=1`。

## 1. 結論

**4 構成とも許容レスポンスタイム（仮: アイドル後の初回の p95 < 3 秒）を満たす**（実機 2026-09-27〜28、§4 / §8）。許容値は Issue #9 の例をそのまま仮置きしており、ユーザーの確認を待っている。

- **推奨は現行既定の min 0 / boost なし**。追加コストは 0 で、アイドル後の初回（コールドスタート）は `GET /` で p50 2.32 秒 / p95 2.35 秒。許容値との差は約 0.6 秒
- 初回を 0.2 秒台にしたい場合だけ **min 1**（アイドル後の初回 `GET /` p50 0.18 秒）。待機インスタンス 1 台分の課金が増える（概算 約 $10 / 月、要確認。#11 で確定。§6）
- **startup CPU boost は効果なし**（p50 の差は 3〜10ms で誤差の範囲）。付ける理由が無い
- **gcsfuse はコールドスタートを特に遅くしていない**。コールドの `/`（JSON 読み込みあり）と `/health`（読み込みなし）の差は約 0.13 秒で、ウォームなインスタンスでの差と同程度（初回の JSON 読み込みぶんだけ）
- **コールドスタートの本体は約 2.1 秒**（コールドの `/health` 2.19 秒 − ウォームの `/health` 0.06 秒）。起動ログでは gcsfuse のマウント完了から起動プローブ成功まで約 1.8 秒かかり、11 回とも「2 回目で成功」だった。Apache は 0.6 秒前後で上がっているので、待ちの大半は起動プローブの間隔 2 秒。間隔を 1 秒にすれば約 0.8 秒縮み、コールドの初回は約 1.5 秒になる見込み（起動ログからの見積もり。§5）

## 2. 検証方法

### なぜ「アイドルで落としてから 1 リクエスト」で測るか

新リビジョンをデプロイすると、Cloud Run は起動プローブのためにインスタンスを先に起こし、そのまま待機させる（#7 の `restart-verify` でインスタンス ID が変わったのはこれ）。そのため「デプロイ直後の 1 リクエスト」は利用者が体感するコールドスタート（アイドルでインスタンスが 0 台になった後の初回）ではない。本レポートでは **アイドル（既定 16 分。Cloud Run は最長 15 分アイドルでインスタンスを落とす）で確実に 0 台にしてから 1 リクエスト**を投げ、その TTFB（`curl` の `time_starttransfer`）を「初回」とする。

### コールドだったかの判定（`X-Instance-Id` / `X-Instance-Uptime`）

アプリは全応答に `X-Instance-Id`（`/tmp/instance-id` に置いた乱数。インスタンスが入れ替わると変わる）と `X-Instance-Uptime`（そのインスタンスが最初のリクエストを受けてからの秒数）を付ける（`app/src/InstanceInfo.php`）。起動プローブ（`GET /health`）が必ず最初のリクエストになるので、uptime はプローブ成功からの経過秒数に近い。

- **コールド** = ID が前回と変わり、かつ uptime ≤ `COLD_MAX_UPTIME`（既定 10 秒）。このリクエストが原因で起動したインスタンス
- ID が同じ = まだ落ちていなかった（アイドルが足りない）。ID が変わったが uptime が大きい = 何かが先に起こしていた（デプロイなど）。どちらも採用せず、待ち時間を延ばして再試行

### gcsfuse の寄与の分離

1 回のコールドスタートで測れる「初回」は 1 つなので、奇数回目は `GET /`（gcsfuse 上の JSON を読む）、偶数回目は `GET /health`（ファイルにも S3 にも触らない）を初回にし、直後にもう一方を「同一インスタンスの 2 回目」として測る。`/`（初回）− `/health`（初回）が gcsfuse 初回アクセス + PHP の JSON 処理の寄与。Issue の `/healthz` は Cloud Run の予約パスで使えないので `/health`（docs/03 つまずいた点 5）。

### `min_instances=1` の構成（常駐モード）

`min_instances=1` ではインスタンスが常に 1 台待機し、アイドルでも落ちないのでコールドスタートは起きない。この構成で測るべきは「アイドル（16 分）後の初回リクエストが、待機中のインスタンスでどれだけ速く返るか」（`cpu_idle=true` なのでアイドル中は CPU が絞られる。その影響が出るか）。そのため構成ラベルが `min1`〜`min9` で始まるときは、成功した試行をそのまま標本として採用し、待ち時間は延ばさない（`report` では `first(アイドル後・常駐)`）。`N=5` で約 80 分。

なお Cloud Run は待機中のインスタンスも裏で入れ替えることがある（構成 3 の計測で 1 回観測。新しいインスタンスは既に 1310 秒稼働していたので、リクエストは起動を待っていない）。

### `scripts/cold-start.sh`

| サブコマンド | 内容 |
|---|---|
| `sample` | `IDLE` 秒待つ → 初回（`/` または `/health`）を計測 → コールド判定 → 直後に 2 回目 → jsonl に追記。コールド標本が `N`（既定 5）個集まるまで繰り返す（コールドでなければ `EXTRA` 秒延ばす。上限 `MAX_IDLE`、既定 1800 秒）。構成ラベルは `terraform output cold_start_config`（`min0-boost0` 等）で、`min1` 以上は常駐モード。ID トークンは 1 時間で切れるので毎回取り直す。gcloud の認証が切れたら再開手順を出して終了コード 3 で止まり、同じコマンドで続きから追記できる |
| `report` | jsonl を構成 × パス × 種別（`first(cold)` / `first(アイドル後・常駐)` / `second(同一インスタンス)` / `first(warm, 不採用)`）で集計し、n / p50 / p95 / min / max を表示。失敗行と不正な行は除外 |
| `startup-log` | 直近の起動ログ（gcsfuse マウント完了 → Apache 起動 → 起動プローブ成功）を時刻付きで表示。差がコンテナ起動の内訳 |
| `image-size` | Artifact Registry のレイヤー合計サイズ |

## 3. 手順（Dev Container 内で実施）

1 標本に `IDLE`（16 分）以上かかるので、`nohup` で流して放置する。min 0 の構成は 1 構成 1.5〜2 時間、min 1 の構成は約 80 分（`N=5`）。Issue の 10 回にするなら `N=10`。

組織アカウントのセッション制御で、gcloud の認証は十数時間で切れる（構成 3 の計測では開始から約 12 時間後に切れた）。切れるとスクリプトは再開手順を出して止まるので、`gcloud auth login --no-launch-browser` の後に同じコマンドを実行すれば続きから追記される。長く放置する前に取り直しておくと確実。

```bash
export BASE_URL=$(terraform -chdir=terraform/gcp output -raw service_url)
rm -f cold-start-results.jsonl        # 修正前の cold-start.sh が書いた失敗行があれば消す（つまずいた点 1）

# 構成 1: min 0 / boost なし（既定）。tfvars に何も書かなければこの構成
sed -i '/^min_instances\|^startup_cpu_boost/d' terraform/gcp/terraform.tfvars
terraform -chdir=terraform/gcp apply
nohup scripts/cold-start.sh sample > cold-start.log 2>&1 &     # 進捗は tail -f cold-start.log。最初に「現在のインスタンス: xxxxxxxx」が出れば認証は通っている
#   ... 終わるのを待つ（cold-start.log の末尾に「コールド標本 N 個」が出る）

# 構成 2: min 0 / boost あり
echo 'startup_cpu_boost = true' >> terraform/gcp/terraform.tfvars && terraform -chdir=terraform/gcp apply
nohup scripts/cold-start.sh sample > cold-start.log 2>&1 &

# 構成 3: min 1 / boost あり（常時 1 台。課金が発生するので計測が終わったら戻す）
echo 'min_instances = 1' >> terraform/gcp/terraform.tfvars && terraform -chdir=terraform/gcp apply
nohup scripts/cold-start.sh sample > cold-start.log 2>&1 &     # 常駐モード（アイドル後の初回をそのまま採用）。約 80 分

# 構成 4: min 1 / boost なし
sed -i '/^startup_cpu_boost/d' terraform/gcp/terraform.tfvars && terraform -chdir=terraform/gcp apply
nohup scripts/cold-start.sh sample > cold-start.log 2>&1 &

# 集計・付随情報
scripts/cold-start.sh report
scripts/cold-start.sh startup-log
scripts/cold-start.sh image-size

# 後片付け: min 0 / boost なしに戻す
sed -i '/^min_instances\|^startup_cpu_boost/d' terraform/gcp/terraform.tfvars && terraform -chdir=terraform/gcp apply
```

- `min_instances=1` の構成は常駐モード（§2）。`report` の `first(アイドル後・常駐)` 行がその構成の「アイドル後の初回」
- 計測中は他の操作（ブラウザで開く、`smoke.sh` など）をしない。アイドルが途切れる

## 4. 合否基準と結果

合否基準（Issue #9）: 各構成の p50 / p95 が記録され、許容レスポンスタイムを満たす構成とそのコストが明示されていること。許容値（仮）: **初回の p95 < 3 秒**。

| 構成 | `/` 初回 p50 / p95 | `/health` 初回 p50 / p95 | 2 回目（同一インスタンス）`/` / `/health` | 許容値 | 月額の増分 |
|---|---|---|---|---|---|
| min 0 / boost なし（現行既定・**推奨**） | **2324 / 2347**（n=3、コールド） | 2189 / 2194（n=2、コールド） | 190 / 57 | 満たす | 0 |
| min 0 / boost あり | 2327 / 2375（n=3、コールド） | 2199 / 2240（n=2、コールド） | 155 / 55 | 満たす | 0（起動中の CPU 分のみ） |
| min 1 / boost あり | 180 / 1176（n=14、アイドル後・常駐） | —（標本なし） | — / 56 | 満たす | §6（約 $10 / 月、要確認） |
| min 1 / boost なし | 183 / 218（n=3、アイドル後・常駐） | 91 / 140（n=2、アイドル後・常駐） | 102 / 53 | 満たす | §6（約 $10 / 月、要確認） |

単位は ms（TTFB）。p95 は昇順 ceil(0.95n) 番目なので、n が 14 以下では最大値と同じ。

- **標本数**: min 0 は構成ごとに 5 標本（パスごとに 2〜3）で、Issue の「各 10 回」には届いていない。ただし boost の有無で差が無いので、min 0 の 2 構成を合わせた 10 標本で見ても 2189〜2375ms（幅 0.19 秒）に収まっており、許容値 3 秒に対する結論は変わらない
- **min 1 / boost ありの 1176ms** は 14 件中 1 回だけの外れ値（他の 13 件は 140〜261ms）。原因は特定していない（アイドル中に CPU が絞られた状態からの復帰の揺らぎと推定）
- **min 1 の初回と 2 回目の差**（`/` で 183 → 102ms）は、`cpu_idle = true` でアイドル中に CPU が絞られるぶん

## 5. 起動時間の内訳

TTFB から分解すると次のとおり（min 0 / boost なしの p50）。

| 区間 | 時間 | 根拠 |
|---|---|---|
| ネットワーク往復 + アプリの処理（`/health`） | 約 0.06 秒 | ウォームの `/health` 57ms |
| コールドスタートの本体（インスタンス確保 → コンテナ起動 → gcsfuse マウント → Apache 起動 → 起動プローブ成功 → リクエスト転送） | **約 2.1 秒** | コールドの `/health` 2189ms − ウォームの `/health` 57ms |
| 初回の JSON 読み込み（gcsfuse + PHP） | 約 0.13 秒 | コールドの `/` − `/health` = 135ms。ウォームでも 133ms で同程度 |

### 起動ログから見た内訳（`startup-log`）

`scripts/cold-start.sh startup-log` で、gcsfuse のマウント完了・Apache の起動・起動プローブ成功の時刻を起動ごとに並べた（2026-09-14〜15 のデプロイ時の起動 11 回。起動の手順はアイドル後のコールドスタートと同じ）。

| 起動（リビジョン） | マウント → Apache | Apache → プローブ成功 | マウント → プローブ成功 | 試行 |
|---|---|---|---|---|
| poc-app-00001-4nl | 1.25 秒 | 0.56 秒 | 1.81 秒 | 2 |
| poc-app-00001-b9l | 0.76 | 1.00 | 1.75 | 2 |
| poc-app-00001-pd7 | 0.47 | 1.40 | 1.88 | 2 |
| poc-app-00002-526 | 0.75 | 1.05 | 1.80 | 2 |
| poc-app-00003-j9d | 0.74 | 1.11 | 1.85 | 2 |
| poc-app-00004-cbl | 0.65 | 1.21 | 1.86 | 2 |
| poc-app-00005-nkc | 0.49 | 1.35 | 1.84 | 2 |
| poc-app-00006-2gs | 0.58 | 0.23 | 0.80 | 2 |
| poc-app-00007-q52 | 0.49 | 0.05 | 0.54 | 2 |
| poc-app-00008-pvc | 0.45 | 1.41 | 1.86 | 2 |
| poc-app-00009-87k | 0.56 | 1.27 | 1.83 | 2 |
| **中央値** | **0.58** | **1.11** | **1.83** | 11 回とも 2 |

- **Apache は速い**: マウント完了から 0.45〜0.76 秒で上がる（最初のデプロイの 1 回だけ 1.25 秒）
- **待ちの大半は起動プローブの間隔**: 11 回とも「2 回目で成功」。1 回目はコンテナ起動直後で Apache がまだ上がっておらず失敗し、2 秒後の 2 回目まで待つ。そのためマウントからプローブ成功までが 9 回で約 1.8 秒にそろっている（残り 2 回は 1 回目の時刻がずれて 0.5〜0.8 秒）
- **間隔を 1 秒にした場合の見込み**: 2 回目が起動から約 1 秒後になり、Apache はそれまでに上がっているので、マウント → プローブ成功は約 1.0 秒（約 0.8 秒短縮）。コールドの初回は 2.3 秒 → 約 1.5 秒の計算（見積もり。実測は下の任意の追加計測）
- **gcsfuse のマウントは起動を特に遅くしていない**: マウントは Cloud Run がコンテナ起動前に行う。TTFB でも `/` と `/health` の差は通常の初回読み込みぶん（0.13 秒）だけだった
- **マウントより前**（インスタンスの確保とイメージの取得）はログに出ない。TTFB から見ると、コールドの本体約 2.1 秒のうち約 0.3 秒がここと、プローブ成功後の転送に当たる

| 項目 | 値 |
|---|---|
| イメージサイズ（`image-size`、最新 `20a483e`） | **175.5 MB**（圧縮済みレイヤーの合計。直前のタグは 175.4 / 187.2 MB） |
| マウント完了 → Apache → プローブ成功（中央値） | 0.58 秒 → 1.11 秒 → 計 1.83 秒 |
| 起動プローブ設定 | `GET /health`、`initial_delay 0` / `period 2` / `timeout 2` / `failure_threshold 15`。`startup_probe_period_seconds` で間隔を変えられる（`failure_threshold` は合計 30 秒を保つよう自動で決まる） |

### 任意の追加計測: 起動プローブの間隔を 1 秒にする

合否は上の 4 構成で確定しているので、これは推奨構成をさらに速くできるかの確認（約 2 時間）。**プローブ間隔が効くのは起動時だけなので、必ず min 0 で測る**（min 1 ではコールドスタートが起きず、効果が見えない。つまずいた点 4）。

```bash
sed -i '/^min_instances\|^startup_cpu_boost/d' terraform/gcp/terraform.tfvars      # min 0 / boost なしにしておく
echo 'startup_probe_period_seconds = 1' >> terraform/gcp/terraform.tfvars && terraform -chdir=terraform/gcp apply
nohup scripts/cold-start.sh sample > cold-start.log 2>&1 &     # ラベルは min0-boost0-probe1
scripts/cold-start.sh report
sed -i '/^startup_probe_period_seconds/d' terraform/gcp/terraform.tfvars && terraform -chdir=terraform/gcp apply   # 戻す（効果があれば既定値を 1 にする）
```

| 構成 | `/` 初回 p50 / p95 | `/health` 初回 p50 / p95 |
|---|---|---|
| min 0 / boost なし / プローブ間隔 1 秒 | （記入） | （記入） |

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

### つまずいた点 1: `cold-start.sh` が `curl: (6) Could not resolve host: Bearer` で失敗する（2026-09-27）

実機の構成 1 で `sample` を始めたところ、次のエラーが出て計測にならなかった。

```
curl: (6) Could not resolve host: Bearer
curl: (6) Could not resolve host: <ID トークン>
```

原因: スクリプトのバグ。認証ヘッダーを関数から `echo` で文字列として返し、`curl $(auth_args) ...` と引用符なしで展開していたため、`Authorization: Bearer <token>` が空白で割れて `Bearer` と `<token>` が別の引数になり、curl がそれらを URL（ホスト名）として解釈した。`fs-check.sh` / `update-bench.sh` / `smoke.sh` はヘッダーを配列で渡しているので起きない。この環境の検証は localhost に対してトークン無しで行ったので、この経路を通っていなかった。

対処:

- 認証ヘッダーを配列（`auth=(-H "Authorization: Bearer $t")`）で渡す。IDLE の間にトークンが切れるので、リクエストのたびに取り直す
- curl が失敗した試行は `"ok":false`、`"code":0` の有効な JSON として記録し、採用しない。修正前は `"code":000`（先頭ゼロ）という不正な JSON が書かれていた
- 開始時の `GET /health` が 200 でない、または `X-Instance-Id` が無ければ、原因の候補（BASE_URL・認証・古いイメージ）を出して中断する
- `report` は失敗行と不正な行を集計から除き、件数を表示する
- 検証に `TOKEN=dummy`（localhost はヘッダーを無視する）を加え、修正前のコードで同じエラーが再現し、修正後は出ないことを確認した

### つまずいた点 2: `min_instances=1` で待ち時間が延び続け、約 12 時間後に gcloud の認証が切れた（2026-09-27）

構成 3（min 1 / boost あり）で `sample` を流したところ、15 回目の直前に次のエラーで止まった。

```
ERROR: (gcloud.auth.print-identity-token) There was a problem refreshing your current auth tokens:
  Reauthentication failed. cannot prompt during non-interactive execution.
```

原因はスクリプトの設計。`min_instances=1` ではインスタンスが落ちないので、全試行が「warm（採用しない）」になり、コールド標本を待って待ち時間を 300 秒ずつ延ばし続けた（960 秒 → 5160 秒）。15 回で約 12 時間かかり、その間に組織のセッション制御で gcloud の認証が切れた。採用されないので初回パスも毎回 `/` のままだった。さらに認証の取り直しが `probe`（プロセス置換のサブシェル）の中にあったため、gcloud のメッセージだけ出て、理由を言わずに終了していた。

対処:

- `min_instances≥1` の構成は常駐モードにした（§2）。成功した試行をそのまま採用し、待ち時間は延ばさない。初回パスは標本ごとに `/` と `/health` を交互にする
- min 0 の構成でも、待ち時間の延長に上限（`MAX_IDLE`、既定 1800 秒）を付けた
- 認証の取り直しをメインのシェルで行い、失敗したら再開手順を出して終了コード 3 で止める
- `report` はラベルが `min1` 以上の初回を `first(アイドル後・常駐)` に集計する。修正前の形式で記録された構成 3 の 14 件もそのまま集計に使える

### つまずいた点 3: `startup-log` がシステムログを拾えず、`image-size` が 0.0 MB（2026-09-28）

実機で `startup-log` を実行したところ、Apache の起動行（`resuming normal operations`）しか出ず、gcsfuse のマウント完了と起動プローブ成功の行が無かった。`image-size` は `0.0 MB` と出た。

- `startup-log`: `gcloud run services logs read` はコンテナの stdout/stderr とリクエストログが中心で、gcsfuse とプローブのメッセージが出る Cloud Run のシステムログを含まなかった。→ `gcloud logging read` でサービスの全ログから探すように直した（`FRESHNESS`、`LIMIT` で範囲を変えられる）
- `image-size`: `gcloud artifacts files list` の `sizeBytes` を合計していたが、値が取れていなかった。→ `gcloud artifacts docker images list <image_uri> --include-tags` の `metadata.imageSizeBytes`（圧縮済みレイヤーの合計 = pull する量）を新しい順に 3 件表示するように直した。値が無ければ `describe` で確認するよう表示する
- どちらもこの環境では偽の `gcloud` で表示を確認しただけで、本物の gcloud の出力形式は手元で確認する → 手元で取得できた（§5）

### つまずいた点 4: `startup-log` が古い起動しか出さない、ラベル `unknown` の結果、min 1 のままのプローブ比較（2026-09-29）

修正後のツールを手元で実行したところ、次の 3 点が見つかった。

- `startup-log` が `--order=asc --limit=60` だったため、**古い順に 60 件**（09-14〜15 のデプロイ時の起動）しか出ず、計測した 09-27〜28 の起動が出なかった。本文の無い行（監査ログなど）も混ざった。→ 新しい方から取って時系列に並べ直し、本文の無い行を捨て、起動ごとの内訳表（マウント → Apache → プローブ成功と試行回数）を出すようにした。生の行は `RAW=1`
- `report` に**ラベル `unknown` の結果が 15 件**あった。構成ラベル（`terraform output cold_start_config`）の取得に失敗したまま `sample` が走ったもので（ADC の期限切れなどと推定）、どの構成か分からない。→ `sample` はラベルが取れなければ理由を出して止まる。`report` は `unknown` の行を集計から除く
- `min1-boost0-probe1` の結果が 1 件あった。`min_instances = 1` のままプローブ間隔を 1 秒にして計測したもので、常駐モードではコールドスタートが起きないので、プローブ間隔の効果は測れていない。手順に「min 0 で測る」と書いていなかった。→ §5 の手順に明記した。この 1 件は比較に使わない

## 8. 実機での確認結果

2026-09-27〜28、Dev Container から §3 を実施（PHP 8.3.35 のイメージ）。構成 3 は修正前のスクリプトで計測（つまずいた点 2）。`report` の全行は次のとおり（PR #20 のコメント）。

```
label          path     kind                         n     p50     p95     min     max
min0-boost0    /        first(cold)                  3    2324    2347    2261    2347
min0-boost0    /        second(同一インスタンス)     2     190     195     190     195
min0-boost0    /health  first(cold)                  2    2189    2194    2189    2194
min0-boost0    /health  second(同一インスタンス)     3      57      71      53      71
min0-boost1    /        first(cold)                  3    2327    2375    2317    2375
min0-boost1    /        second(同一インスタンス)     2     155     212     155     212
min0-boost1    /health  first(cold)                  2    2199    2240    2199    2240
min0-boost1    /health  second(同一インスタンス)     3      55      57      52      57
min1-boost0    /        first(アイドル後・常駐)      3     183     218     161     218
min1-boost0    /        second(同一インスタンス)     2     102     117     102     117
min1-boost0    /health  first(アイドル後・常駐)      2      91     140      91     140
min1-boost0    /health  second(同一インスタンス)     3      53      56      53      56
min1-boost1    /        first(アイドル後・常駐)     14     180    1176     140    1176
min1-boost1    /health  second(同一インスタンス)    14      56      64      50      64
```

| 構成 | 要点 | `startup-log` の要点 |
|---|---|---|
| min 0 / boost なし | コールド 5 標本。`/` 2261〜2347ms、`/health` 2189〜2194ms | 修正前の `startup-log` では Apache の起動行だけ（つまずいた点 3） |
| min 0 / boost あり | コールド 5 標本。`/` 2317〜2375ms、`/health` 2199〜2240ms。boost なしと差が無い | 同上 |
| min 1 / boost あり | 中間結果（修正前のスクリプト、2026-09-27）: アイドル 16〜86 分後の初回 `GET /` が 14 件。TTFB 140〜1176ms（昇順 140, 149, 151, 151, 155, 168, 180, 182, 187, 193, 211, 260, 261, 1176）、**p50 180ms / p95 1176ms**（14 件なので p95 は最大値。1176ms は 1 回だけの外れ値）。`/health` を初回にした標本は無い。途中で Cloud Run が待機インスタンスを裏で入れ替えた（`a50f150a` → `b331db56`、入れ替え後のインスタンスは既に 1310 秒稼働）。最終値は `report` で確定 | 起動は計測対象外（コールドスタートが起きない） |
| min 1 / boost なし | アイドル後・常駐 5 標本。`/` 161〜218ms、`/health` 91〜140ms | 起動は計測対象外 |

`report` にはこのほか `min1-boost0-probe1`（min 1 のままプローブ間隔 1 秒で 1 標本。プローブの効果は測れていない）と `unknown`（構成ラベルの取得に失敗した 15 件）が出ていたが、どちらも比較には使わない（つまずいた点 4）。

起動ログの内訳とイメージサイズは §5。

## 9. #10 / #11 への引き継ぎ

- **#10（運用）**: 推奨は min 0（初回 2.3 秒を許容する）。初回の待ちを避けたい時間帯だけ `min-instances=1` にする運用（スケジュールで `gcloud run services update --min-instances`）は選択肢。起動プローブの間隔短縮（§5 の任意の追加計測）も同様
- **#11（コスト）**: §6 の式に料金表の単価を入れて `min-instances=1` の月額を確定する。推奨の min 0 では、課金はリクエスト処理中（`POST /update` 0.5 秒 × 回数、docs/06）とコールドスタートの起動分だけ。startup CPU boost は効果が無いので費用に含めない
