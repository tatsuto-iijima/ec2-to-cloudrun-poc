#!/usr/bin/env bash
# コールドスタート（アイドル後の初回リクエスト）の TTFB を計測する（Issue #9、docs/07）。
#
# 使い方:
#   BASE_URL=https://poc-app-xxxx.a.run.app scripts/cold-start.sh [sample|report|startup-log|image-size]
#     sample       IDLE 秒（既定 960 = 16 分）待ってから 1 リクエストを投げ、初回の TTFB を測る。コールド（インスタンスが
#                  入れ替わり、uptime が COLD_MAX_UPTIME 秒以内）なら採用。N 個（既定 5）のコールド標本が集まるまで繰り返す。
#                  奇数回目は GET /（gcsfuse 読み込みあり）、偶数回目は GET /health（読み込みなし）を初回にし、直後にもう一方を
#                  「同一インスタンスの 2 回目」として測る。結果は OUT（既定 cold-start-results.jsonl）に追記
#     report       OUT を構成 × パス × cold/warm で集計し、p50 / p95 / min / max を表示する（既定）
#     startup-log  直近の起動ログ（gcsfuse マウント → 起動プローブ成功）を時刻付きで表示する
#     image-size   Artifact Registry 上のイメージのレイヤー合計サイズを表示する
#   環境変数:
#     TOKEN            ID トークン（run.app なら自動取得。IDLE 中に期限切れ（1 時間）になるので毎回取り直す）
#     LABEL            構成ラベル。既定は terraform output cold_start_config（例 min0-boost0）
#     N                集めるコールド標本の数（既定 5）。MAX_TRIES（既定 N*3）回試しても足りなければ終了
#     IDLE             アイドル秒数（既定 960）。コールドにならなかったら EXTRA 秒（既定 300）延ばして再試行
#     COLD_MAX_UPTIME  コールドと判定する X-Instance-Uptime の上限秒（既定 10。起動プローブが最初のリクエストになるため 0 にはならない）
#     OUT              結果の jsonl（既定 cold-start-results.jsonl。gitignore 済み）
#   長時間かかるので Dev Container で nohup で流す: nohup scripts/cold-start.sh sample > cold-start.log 2>&1 &
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
TOKEN="${TOKEN:-}"
LABEL="${LABEL:-}"
N="${N:-5}"
MAX_TRIES="${MAX_TRIES:-$((N * 3))}"
IDLE="${IDLE:-960}"
EXTRA="${EXTRA:-300}"
COLD_MAX_UPTIME="${COLD_MAX_UPTIME:-10}"
OUT="${OUT:-cold-start-results.jsonl}"
cmd="${1:-report}"

cd "$(dirname "$0")/.."

# 認証ヘッダー。ヘッダーは空白を含むので必ず配列で curl に渡す（文字列にして展開すると
# "Bearer" とトークンが別の引数に割れ、curl がホスト名として解釈する。docs/07 つまずいた点 1）。
# IDLE（16 分）の間に ID トークン（1 時間）が切れうるので、リクエストのたびに取り直す
auth=()
refresh_auth() {
  auth=()
  local t="$TOKEN"
  if [[ -z "$t" && "$BASE_URL" == *.run.app* ]]; then t=$(gcloud auth print-identity-token); fi
  if [[ -n "$t" ]]; then auth=(-H "Authorization: Bearer $t"); fi
}

# 1 リクエストを測り、"code<TAB>ttfb_ms<TAB>total_ms<TAB>instance<TAB>uptime" を返す。
# curl が失敗したら code=0（stderr に 1 行）。instance / uptime はヘッダーが無ければ空
probe() { # probe <path>
  local hdr out code ttfb total inst up
  refresh_auth
  hdr=$(mktemp)
  if ! out=$(curl -sS "${auth[@]}" -o /dev/null -D "$hdr" -w '%{http_code}\t%{time_starttransfer}\t%{time_total}' "$BASE_URL$1"); then
    echo "$(date -u +%FT%TZ) curl が失敗: $BASE_URL$1" >&2
    out=$'0\t0\t0'
  fi
  IFS=$'\t' read -r code ttfb total <<<"$out"
  inst=$(grep -i '^x-instance-id:' "$hdr" | tr -d '\r' | awk '{print $2}' || true)
  up=$(grep -i '^x-instance-uptime:' "$hdr" | tr -d '\r' | awk '{print $2}' || true)
  rm -f "$hdr"
  # code は "000" のような先頭ゼロを数値に直す（JSON に書くため）
  printf '%d\t%.0f\t%.0f\t%s\t%s\n' "$((10#${code:-0}))" "$(php -r 'echo (float) $argv[1] * 1000;' "${ttfb:-0}")" "$(php -r 'echo (float) $argv[1] * 1000;' "${total:-0}")" "${inst:-}" "${up:-}"
}

record() { # record <json>
  printf '%s\n' "$1" >>"$OUT"
}

sample() {
  [[ -n "$LABEL" ]] || LABEL=$(terraform -chdir=terraform/gcp output -raw cold_start_config 2>/dev/null || echo unknown)
  echo "構成 $LABEL: コールド標本 $N 個（IDLE ${IDLE}s、判定 uptime<=${COLD_MAX_UPTIME}s、最大 $MAX_TRIES 回）。結果: $OUT"
  local prev="" collected=0 tries=0 wait="$IDLE" i first second
  # 前回の計測で最後に見たインスタンス ID（あれば）。無ければ 1 回だけ /health で取得する（これで idle タイマーが動き出す）
  prev=$(grep -h "\"label\":\"$LABEL\"" "$OUT" 2>/dev/null | tail -1 | php -r '$d=json_decode(stream_get_contents(STDIN),true); echo $d["instance"]??"";' || true)
  if [[ -z "$prev" ]]; then
    local c0
    IFS=$'\t' read -r c0 _ _ prev _ < <(probe /health)
    if [[ "$c0" != 200 || -z "$prev" ]]; then
      echo "GET /health が $c0 でした（X-Instance-Id: ${prev:-なし}）。BASE_URL・認証（gcloud auth login）・デプロイ済みのイメージ（X-Instance-* を返す版か）を確認してください" >&2
      exit 1
    fi
    echo "$(date -u +%FT%TZ) 現在のインスタンス: $prev（ここからアイドルを数える）"
  fi
  while (( collected < N && tries < MAX_TRIES )); do
    tries=$((tries + 1))
    echo "$(date -u +%FT%TZ) [$tries] ${wait}s 待つ..."
    sleep "$wait"
    i=$((collected + 1))
    if (( i % 2 == 1 )); then first=/; second=/health; else first=/health; second=/; fi
    local c1 t1 tot1 inst1 up1 c2 t2 tot2 inst2 up2 cold ok ts
    ts=$(date -u +%FT%TZ)
    IFS=$'\t' read -r c1 t1 tot1 inst1 up1 < <(probe "$first")
    IFS=$'\t' read -r c2 t2 tot2 inst2 up2 < <(probe "$second")
    if [[ "$c1" == 200 && "$c2" == 200 && -n "$inst1" ]]; then ok=true; else ok=false; fi
    if [[ "$ok" == true && "$inst1" != "$prev" && -n "$up1" && "$up1" -le "$COLD_MAX_UPTIME" ]]; then cold=true; else cold=false; fi
    record "{\"ts\":\"$ts\",\"label\":\"$LABEL\",\"try\":$tries,\"order\":\"first\",\"path\":\"$first\",\"ok\":$ok,\"code\":$c1,\"ttfb_ms\":$t1,\"total_ms\":$tot1,\"instance\":\"$inst1\",\"uptime\":${up1:-null},\"prev\":\"$prev\",\"cold\":$cold,\"idle_s\":$wait}"
    record "{\"ts\":\"$ts\",\"label\":\"$LABEL\",\"try\":$tries,\"order\":\"second\",\"path\":\"$second\",\"ok\":$ok,\"code\":$c2,\"ttfb_ms\":$t2,\"total_ms\":$tot2,\"instance\":\"$inst2\",\"uptime\":${up2:-null},\"prev\":\"$prev\",\"cold\":false,\"idle_s\":$wait}"
    if [[ "$ok" != true ]]; then
      # 失敗した試行は採用しない。インスタンスが分からないので prev も更新しない
      echo "$ts   失敗（採用しない）: $first -> HTTP $c1 / $second -> HTTP $c2。次も ${wait}s 待つ"
      continue
    fi
    if [[ "$cold" == true ]]; then
      collected=$((collected + 1)); wait="$IDLE"
      echo "$ts   COLD #$collected: $first ttfb=${t1}ms total=${tot1}ms (instance $prev -> $inst1, uptime ${up1}s) / 2 回目 $second ttfb=${t2}ms"
    else
      wait=$((wait + EXTRA))
      echo "$ts   warm（採用しない）: $first ttfb=${t1}ms instance=$inst1 uptime=${up1}s（前回 $prev）。次は ${wait}s 待つ"
    fi
    prev="$inst2"
  done
  echo "コールド標本 $collected 個 / $tries 回。集計: $0 report"
}

report() {
  [[ -f "$OUT" ]] || { echo "$OUT がありません" >&2; exit 1; }
  php -r '
    $all = array_map(fn($l) => json_decode($l, true), file($argv[1], FILE_IGNORE_NEW_LINES));
    // 壊れた行（修正前の版が書いた "code":000 など）と、失敗した試行（HTTP 200 以外）は集計しない
    $rows = array_values(array_filter($all, fn($r) => is_array($r) && isset($r["ttfb_ms"]) && ($r["ok"] ?? true) !== false && (int) ($r["code"] ?? 0) === 200));
    $skipped = count($all) - count($rows);
    $g = [];
    foreach ($rows as $r) {
      if ($r["order"] === "first" && !$r["cold"]) { $k = [$r["label"], $r["path"], "first(warm, 不採用)"]; }
      elseif ($r["order"] === "first") { $k = [$r["label"], $r["path"], "first(cold)"]; }
      else { $k = [$r["label"], $r["path"], "second(同一インスタンス)"]; }
      $g[implode("\t", $k)][] = (float) $r["ttfb_ms"];
    }
    ksort($g);
    $pct = function (array $v, float $p) { sort($v); $i = (int) ceil($p / 100 * count($v)) - 1; return $v[max(0, $i)]; };
    printf("%-14s %-8s %-26s %3s %7s %7s %7s %7s\n", "label", "path", "kind", "n", "p50", "p95", "min", "max");
    foreach ($g as $k => $v) {
      [$label, $path, $kind] = explode("\t", $k);
      printf("%-14s %-8s %-26s %3d %7.0f %7.0f %7.0f %7.0f\n", $label, $path, $kind, count($v), $pct($v, 50), $pct($v, 95), min($v), max($v));
    }
    echo "（ms。first(cold) が「アイドル後の初回」。p95 は昇順 ceil(0.95n) 番目）\n";
    if ($skipped > 0) { echo "失敗・不正な行 {$skipped} 件は集計から除外\n"; }
  ' "$OUT"
}

startup_log() {
  local svc
  svc=$(terraform -chdir=terraform/gcp output -raw service_name)
  gcloud run services logs read "$svc" --region asia-northeast1 --limit 300 --format 'value(timestamp,textPayload)' 2>/dev/null \
    | grep -iE 'successfully mounted|STARTUP .*probe|resuming normal operations|Container called exit|Default STARTUP' | tail -n 12
  echo "（gcsfuse のマウント完了 → Apache 起動 → 起動プローブ成功 の順。差がコンテナ起動の内訳）"
}

image_size() {
  local repo="poc-app"
  gcloud artifacts files list --repository="$repo" --location=asia-northeast1 --format='value(sizeBytes)' 2>/dev/null \
    | php -r '$s=0; foreach (file("php://stdin") as $l) { $s += (int) trim($l); } printf("Artifact Registry %s の全レイヤー合計: %.1f MB（タグ間で共有されるレイヤーを含む。1 イメージの実サイズは docker image inspect で）\n", $argv[1], $s / 1048576);' "$repo"
}

case "$cmd" in
  sample) sample ;;
  report) report ;;
  startup-log) startup_log ;;
  image-size) image_size ;;
  *) echo "usage: $0 [sample|report|startup-log|image-size]" >&2; exit 2 ;;
esac
