#!/usr/bin/env bash
# gcsfuse マウント領域（DATA_DIR）での JSON 読み書きを検証する（Issue #7、docs/05）。
# アプリの POST /fs-check（FS_CHECK=1 のときだけ有効）を case ごとに呼び、結果を jsonl に追記しつつ要点を表示する。
#
# 使い方:
#   BASE_URL=https://poc-app-xxxx.a.run.app scripts/fs-check.sh [all|restart-mark|restart-verify|external|cleanup]
#     all            (a) rmw / (b) rename と原子性 / (c) lock と直列化 / (d) append / (f) サイズ別 / 追加項目（既定）
#     restart-mark   (e) の前半: POST /update して counter とインスタンス ID を記録する
#     restart-verify (e) の後半: インスタンスが入れ替わった後に counter が最新か確認する
#     external       追加: アプリ以外（gcloud storage cp）で書き換えた data.json の見え方（stat cache TTL）
#     cleanup        DATA_DIR/fs-check/ を削除する
#   環境変数:
#     TOKEN   Authorization: Bearer に使う ID トークン。未指定で BASE_URL が run.app なら gcloud auth print-identity-token
#     SIZES   size case のバイト数（既定 "102400 1048576 10485760"。50MB を足すなら "... 52428800"）
#     OUT     結果の jsonl（既定 fs-check-results.jsonl。gitignore 済み）
#     BUCKET  external で書き換える作業領域バケット（既定 terraform output bucket_name）
#   ローカル（PHP 内蔵サーバー）で試すときは PHP_CLI_SERVER_WORKERS=4 で起動する（既定は 1 ワーカーで並行リクエストが
#   サーバー側で直列化され、(b) 原子性と (c) 直列化の並行が成立しない）
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
TOKEN="${TOKEN:-}"
SIZES="${SIZES:-102400 1048576 10485760}"
OUT="${OUT:-fs-check-results.jsonl}"
BUCKET="${BUCKET:-}"
cmd="${1:-all}"

cd "$(dirname "$0")/.."

if [[ -z "$TOKEN" && "$BASE_URL" == *.run.app* ]]; then
  TOKEN=$(gcloud auth print-identity-token)
fi
auth=()
[[ -n "$TOKEN" ]] && auth=(-H "Authorization: Bearer $TOKEN")

fail=0
pass() { echo "PASS: $*"; }
ng() { echo "FAIL: $*"; fail=1; }

# JSON から値を取り出す（jq が無ければ php）
jget() { # jget '<json>' key
  if command -v jq >/dev/null 2>&1; then jq -r ".$2 | if . == null then \"\" else . end" <<<"$1"; else php -r '$d=json_decode($argv[1],true); $v=$d[$argv[2]]??null; echo is_bool($v)?($v?"true":"false"):(string)$v;' "$1" "$2"; fi
}

# POST /fs-check を呼び、結果の JSON を OUT に追記して標準出力に返す
call() { # call <case> [k=v ...]
  local case=$1; shift
  local data=(--data-urlencode "case=$case")
  for kv in "$@"; do data+=(--data-urlencode "$kv"); done
  local body code
  body=$(curl -sS "${auth[@]}" -X POST "${data[@]}" -w '\n%{http_code}' "$BASE_URL/fs-check")
  code=${body##*$'\n'}
  body=${body%$'\n'*}
  if [[ "$code" != "200" ]]; then
    echo "FAIL: /fs-check case=$case -> HTTP $code: $body" >&2
    fail=1
    echo '{}'
    return 0
  fi
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$case" "$body" >>"$OUT"
  echo "$body"
}

# 結果の要点を 1 行で表示する
show() { # show '<json>' key...
  local json=$1; shift
  local line="  [$(jget "$json" case)] ok=$(jget "$json" ok)"
  for k in "$@"; do line+=" $k=$(jget "$json" "$k")"; done
  echo "$line"
}

get_index() { curl -sS "${auth[@]}" "$BASE_URL/"; }
index_value() { # index_value '<html>' key  → 表の <th>key</th><td><pre>value</pre></td>
  php -r '$h=$argv[1]; $k=preg_quote($argv[2],"/"); echo preg_match("/<th>$k<\/th>\s*<td><pre>(.*?)<\/pre>/s",$h,$m)?html_entity_decode($m[1]):"";' "$1" "$2"
}

run_all() {
  echo "== 環境（info）"
  r=$(call info); show "$r" instance revision data_dir write_mode uid gid is_writable memory_limit
  echo "  mount: $(jget "$r" mount)"

  echo "== (a) read-modify-write（rmw ×3）"
  for i in 1 2 3; do r=$(call rmw); show "$r" counter read_ms write_ms reread_ms reread_matches; [[ "$(jget "$r" ok)" == true ]] || ng "rmw #$i"; done

  echo "== (b) 一時ファイル + rename（1MB）"
  r=$(call rename size=1048576); show "$r" write_ms rename_ms read_ms tmp_remains content_matches rename_error
  [[ "$(jget "$r" ok)" == true ]] && pass "rename" || ng "rename"

  echo "== (b) 原子性: read-loop（10 秒）を先に始め、0.5 秒後から rename-loop（30 回 × 1MB、100ms 間隔）を並行"
  wr=$( (call read-loop seconds=10) & (sleep 0.5; call rename-loop n=30 size=1048576 interval=100) & wait)
  # 2 つの JSON が順不同で来るので case で振り分ける
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$(jget "$line" case)" in
      rename-loop) show "$line" iterations interval_ms failed rename_ms_min rename_ms_avg rename_ms_max ;;
      read-loop) show "$line" reads missing_before_first missing invalid_json torn distinct_seq
                 [[ "$(jget "$line" ok)" == true ]] && pass "read-loop: 途中の内容も欠落も見えない" || ng "read-loop: torn / invalid / missing あり" ;;
    esac
  done <<<"$wr"

  echo "== (c) file_put_contents(LOCK_EX) と flock の戻り値"
  r=$(call lock); show "$r" written put_error flock_ex flock_ex_nb_same_handle flock_un flock_sh_nb_other_handle put_ms flock_ms
  [[ "$(jget "$r" ok)" == true ]] && pass "lock" || ng "lock"

  echo "== (c) 直列化: lock-hold 3 秒と、0.5 秒後の lock-hold 0 秒を並行（後着の wait_ms ≈ 3000 なら直列化）"
  wr=$( (call lock-hold seconds=3) & (sleep 0.5; call lock-hold seconds=0) & wait)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    show "$line" locked wait_ms held_seconds released
    if [[ "$(jget "$line" held_seconds)" == 0 ]]; then
      w=$(jget "$line" wait_ms); w=${w%.*}
      if (( w >= 2000 )); then pass "lock-hold: 後着が ${w}ms 待った（同一インスタンス内で直列化）"; else ng "lock-hold: 後着の待ち ${w}ms（直列化されていない）"; fi
    fi
  done <<<"$wr"

  echo "== (d) FILE_APPEND（1KB ×3、1MB ×1）"
  for s in 1024 1024 1024 1048576; do r=$(call append size=$s); show "$r" appended size_before size_after append_ms; [[ "$(jget "$r" ok)" == true ]] || ng "append $s"; done

  echo "== (f) サイズ別（create / overwrite / tmp+rename / read）: $SIZES"
  for s in $SIZES; do r=$(call size size=$s); show "$r" size create_ms overwrite_ms tmp_write_ms rename_ms read_ms content_matches; [[ "$(jget "$r" ok)" == true ]] || ng "size $s"; done

  echo "== 追加: chmod / is_writable / touch / glob / scandir / mkdir"
  r=$(call misc); show "$r" chmod perms_after_chmod is_writable is_writable_dir touch mtime_applied glob_count glob_ms scandir_count scandir_ms mkdir mkdir_is_dir rmdir

  echo
  echo "結果は $OUT に追記しました。DATA_DIR/fs-check/ を消すには: $0 cleanup"
}

restart_mark() {
  local ts html counter r
  ts=$(date +%s)
  code=$(curl -sS "${auth[@]}" -o /dev/null -w '%{http_code}' -X POST --data-urlencode "key=fs-check" --data-urlencode "value=$ts" "$BASE_URL/update")
  [[ "$code" == "303" ]] && pass "POST /update -> 303" || ng "POST /update -> $code"
  html=$(get_index)
  counter=$(index_value "$html" counter)
  r=$(call info)
  printf '%s\trestart-mark\t{"counter":%s,"value":"%s","instance":"%s","revision":"%s"}\n' "$(date -u +%FT%TZ)" "${counter:-null}" "$ts" "$(jget "$r" instance)" "$(jget "$r" revision)" >>"$OUT"
  echo "記録: counter=$counter fs-check=$ts instance=$(jget "$r" instance) revision=$(jget "$r" revision)"
  cat <<EOF

次に新しいインスタンスを起こしてから '$0 restart-verify' を実行する。方法はどちらか:
  - 15 分以上放置する（アイドルでインスタンスが終了し、次のリクエストで新しいインスタンスが起動する）
  - 新しいリビジョンを作る（Terraform に差分が出るので、検証後の terraform apply で戻る）:
      gcloud run services update \$(terraform -chdir=terraform/gcp output -raw service_name) --region asia-northeast1 --update-env-vars FS_CHECK_RESTART=$ts
EOF
}

restart_verify() {
  local mark html counter value r
  mark=$(grep -P '\trestart-mark\t' "$OUT" | tail -1 | cut -f3) || true
  [[ -n "$mark" ]] || { echo "restart-mark の記録が $OUT にありません。先に '$0 restart-mark' を実行してください" >&2; exit 1; }
  r=$(call info)
  html=$(get_index)
  counter=$(index_value "$html" counter)
  value=$(index_value "$html" fs-check)
  echo "記録: counter=$(jget "$mark" counter) fs-check=$(jget "$mark" value) instance=$(jget "$mark" instance) revision=$(jget "$mark" revision)"
  echo "現在: counter=$counter fs-check=$value instance=$(jget "$r" instance) revision=$(jget "$r" revision)"
  if [[ "$(jget "$r" instance)" != "$(jget "$mark" instance)" ]]; then pass "インスタンスが入れ替わっている"; else ng "インスタンスが同じ（まだ入れ替わっていない）"; fi
  if [[ "$counter" == "$(jget "$mark" counter)" && "$value" == "$(jget "$mark" value)" ]]; then pass "新インスタンスで読んだ JSON が最新（counter / fs-check が一致）"; else ng "新インスタンスで読んだ JSON が古い"; fi
  printf '%s\trestart-verify\t{"counter":%s,"value":"%s","instance":"%s","revision":"%s","instance_changed":%s,"fresh":%s}\n' \
    "$(date -u +%FT%TZ)" "${counter:-null}" "$value" "$(jget "$r" instance)" "$(jget "$r" revision)" \
    "$([[ "$(jget "$r" instance)" != "$(jget "$mark" instance)" ]] && echo true || echo false)" \
    "$([[ "$counter" == "$(jget "$mark" counter)" && "$value" == "$(jget "$mark" value)" ]] && echo true || echo false)" >>"$OUT"
}

external() {
  [[ -n "$BUCKET" ]] || BUCKET=$(terraform -chdir=terraform/gcp output -raw bucket_name)
  local ts html before after1 after2
  ts=$(date +%s)
  # 1. アプリに読ませて stat cache を温める
  before=$(index_value "$(get_index)" message)
  echo "書き換え前: message=$before"
  # 2. アプリを通さずにオブジェクトを差し替える（message だけ変える）
  gcloud storage cat "gs://$BUCKET/data.json" | php -r '$d=json_decode(stream_get_contents(STDIN),true); $d["message"]="external-".$argv[1]; echo json_encode($d, JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES)."\n";' "$ts" \
    | gcloud storage cp - "gs://$BUCKET/data.json"
  # 3. 直後と TTL（60 秒）経過後に読む
  after1=$(index_value "$(get_index)" message)
  echo "直後:       message=$after1"
  echo "65 秒待つ..."; sleep 65
  after2=$(index_value "$(get_index)" message)
  echo "65 秒後:    message=$after2"
  [[ "$after1" == "external-$ts" ]] && echo "直後から見える（stat cache が効いていないか、TTL 内でも再検証されている）" || echo "直後は古い内容（stat cache TTL 内）"
  [[ "$after2" == "external-$ts" ]] && pass "TTL 経過後に見える" || ng "65 秒後も古い内容"
  printf '%s\texternal\t{"before":"%s","immediately":"%s","after_65s":"%s","expected":"external-%s"}\n' "$(date -u +%FT%TZ)" "$before" "$after1" "$after2" "$ts" >>"$OUT"
}

case "$cmd" in
  all) run_all ;;
  restart-mark) restart_mark ;;
  restart-verify) restart_verify ;;
  external) external ;;
  cleanup) r=$(call cleanup); show "$r" removed dir_removed ;;
  *) echo "usage: $0 [all|restart-mark|restart-verify|external|cleanup]" >&2; exit 2 ;;
esac

if [[ "$fail" == 0 ]]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
