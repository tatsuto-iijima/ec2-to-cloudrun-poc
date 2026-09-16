#!/usr/bin/env bash
# POST /update の処理時間（JSON 読み書き + S3 PUT）と二重送信の挙動を計測する（Issue #8、docs/06）。
# 本物の POST /update を呼び、303 の Location に入っている「read X ms / write Y ms / put Z ms」を読み取る。
# JSON のサイズは POST /fs-check case=pad（FS_CHECK=1 のときだけ有効）で data.json に埋め草を入れて変える。
#
# 使い方:
#   BASE_URL=https://poc-app-xxxx.a.run.app scripts/update-bench.sh [bench|double-submit|reset]
#     bench          SIZES（既定 1MB / 10MB / 50MB）ごとに pad → POST /update を N 回（既定 3）→ 内訳と S3 の MB/s を表示（既定）
#     double-submit  N 本（既定 5）の POST /update を同時に投げ、counter がちょうど +N になるか（更新が失われないか）を確認
#     reset          pad を外す（data.json を元のサイズに戻す）
#   環境変数: TOKEN（ID トークン。run.app なら自動取得）、SIZES、N、OUT（既定 update-bench-results.jsonl。gitignore 済み）
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
TOKEN="${TOKEN:-}"
SIZES="${SIZES:-1048576 10485760 52428800}"
N="${N:-}"
OUT="${OUT:-update-bench-results.jsonl}"
cmd="${1:-bench}"

cd "$(dirname "$0")/.."

if [[ -z "$TOKEN" && "$BASE_URL" == *.run.app* ]]; then
  TOKEN=$(gcloud auth print-identity-token)
fi
auth=()
[[ -n "$TOKEN" ]] && auth=(-H "Authorization: Bearer $TOKEN")

fail=0
pass() { echo "PASS: $*"; }
ng() { echo "FAIL: $*"; fail=1; }
record() { printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" >>"$OUT"; }

# POST /fs-check case=pad size=<bytes>
pad() {
  local body code
  body=$(curl -sS "${auth[@]}" -X POST --data-urlencode "case=pad" --data-urlencode "size=$1" -w '\n%{http_code}' "$BASE_URL/fs-check")
  code=${body##*$'\n'}; body=${body%$'\n'*}
  if [[ "$code" != "200" ]]; then
    echo "FAIL: /fs-check case=pad -> HTTP $code（FS_CHECK=1 で apply していますか）: $body" >&2; exit 1
  fi
  record pad "$body"
  php -r '$d=json_decode($argv[1],true); printf("data.json を %d バイトにした（write %.1fms）\n", $d["bytes"], $d["write_ms"]);' "$body"
}

# POST /update を 1 回呼び、"code<TAB>total_s<TAB>read_ms<TAB>write_ms<TAB>put_ms" を返す（解析できなければ空欄）
post_update() { # post_update key value
  local out code total loc
  out=$(curl -sS "${auth[@]}" -o /dev/null -X POST --data-urlencode "key=$1" --data-urlencode "value=$2" -w '%{http_code}\t%{time_total}\t%{redirect_url}' "$BASE_URL/update")
  IFS=$'\t' read -r code total loc <<<"$out"
  php -r '
    [$code, $total, $loc] = [$argv[1], $argv[2], $argv[3]];
    $q = parse_url($loc, PHP_URL_QUERY) ?? ""; parse_str($q, $p);
    $r = $p["result"] ?? ""; $ok = preg_match("/read ([0-9.]+)ms \/ write ([0-9.]+)ms \/ put ([0-9.]+)ms/", $r, $m);
    printf("%s\t%.0f\t%s\t%s\t%s\n", $code, $total * 1000, $ok ? $m[1] : "", $ok ? $m[2] : "", $ok ? $m[3] : "");
  ' "$code" "$total" "$loc"
}

get_counter() { curl -sS "${auth[@]}" "$BASE_URL/" | php -r 'echo preg_match("/<th>counter<\/th>\s*<td><pre>(\d+)<\/pre>/", stream_get_contents(STDIN), $m) ? $m[1] : "";'; }

bench() {
  local n=${N:-3}
  echo "== /health の応答時間（基準。3 回）"
  for i in 1 2 3; do curl -sS "${auth[@]}" -o /dev/null -w '  %{http_code} %{time_total}s\n' "$BASE_URL/health"; done

  for size in $SIZES; do
    echo "== JSON ≈ $size バイト × $n 回"
    pad "$size"
    for i in $(seq 1 "$n"); do
      IFS=$'\t' read -r code total r w p < <(post_update bench "$size-$i")
      if [[ "$code" == "303" && -n "$p" ]]; then
        mbps=$(php -r 'printf("%.1f", $argv[1] / 1048576 / ($argv[2] / 1000));' "$size" "$p")
        echo "  #$i 303 total=${total}ms read=${r}ms write=${w}ms put=${p}ms (S3 ${mbps} MB/s)"
        record bench "{\"size\":$size,\"i\":$i,\"code\":$code,\"total_ms\":$total,\"read_ms\":$r,\"write_ms\":$w,\"put_ms\":$p}"
      else
        ng "size=$size #$i -> HTTP $code（内訳を読めない）"
        record bench "{\"size\":$size,\"i\":$i,\"code\":$code,\"total_ms\":$total}"
      fi
    done
  done
  echo "== pad を外す"; pad 0
  echo "1 回目の put には WIF の初回取得（新インスタンスのとき）が含まれる。ログの 'wif: credentials refreshed' と突き合わせる"
}

double_submit() {
  local n=${N:-5} before after expect i codes
  echo "== 二重送信: $n 本の POST /update を同時に投げる"
  before=$(get_counter); [[ -n "$before" ]] || { echo "counter を読めません（GET / を確認）" >&2; exit 1; }
  expect=$((before + n))
  codes=$(for i in $(seq 1 "$n"); do post_update dbl "$(date +%s)-$i" & done; wait)
  echo "$codes" | while IFS=$'\t' read -r code total r w p; do echo "  $code total=${total}ms read=${r}ms write=${w}ms put=${p}ms"; done
  after=$(get_counter)
  echo "  counter: $before -> $after（期待 $expect）"
  [[ "$(echo "$codes" | grep -c $'^303\t')" == "$n" ]] && pass "全 $n 本が 303" || ng "303 でない応答がある"
  [[ "$after" == "$expect" ]] && pass "counter がちょうど +$n（更新が失われていない）" || ng "counter が +$n でない（更新が失われた、または余計に進んだ）"
  code=$(curl -sS "${auth[@]}" -o /dev/null -w '%{http_code}' "$BASE_URL/"); [[ "$code" == "200" ]] && pass "GET / -> 200（JSON は壊れていない）" || ng "GET / -> $code"
  record double-submit "{\"n\":$n,\"before\":$before,\"after\":$after,\"expect\":$expect}"
  echo "各リクエストのロック待ちはログで確認: gcloud run services logs read <svc> --region asia-northeast1 --limit 50 | grep 'update key=dbl'"
}

case "$cmd" in
  bench) bench ;;
  double-submit) double_submit ;;
  reset) pad 0 ;;
  *) echo "usage: $0 [bench|double-submit|reset]" >&2; exit 2 ;;
esac

if [[ "$fail" == 0 ]]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
