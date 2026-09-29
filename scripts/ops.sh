#!/usr/bin/env bash
# 運用コマンド（Issue #10、docs/08）。ログの確認、リビジョンの確認、切り戻し、アラートの動作確認をまとめる。
# Dev Container 内で実行する（gcloud の認証と terraform の state が必要）。
#
# 使い方: scripts/ops.sh <サブコマンド> [引数]
#   logs [N]            アプリのログ（stdout = Apache の access ログ、stderr = Apache の error ログと PHP の error_log）を
#                       新しい方から N 件（既定 50）取り、時系列で表示する
#   errors [N]          エラーだけ: stderr の "error " / "PHP Fatal" / "PHP Warning" 行と、5xx を返したリクエスト
#   requests [N]        Cloud Run のリクエストログ（時刻、ステータス、レイテンシ、メソッド、URL）
#   revisions [N]       新しい方から N 件（既定 10）のリビジョン（作成時刻、イメージのタグ）と現在のトラフィック配分。
#                       Cloud Run はイメージをダイジェストで記録するので、Artifact Registry からタグ（= コミットの短縮 SHA）を引く
#   rollback REVISION   緊急の切り戻し: トラフィックを 100% そのリビジョンへ（Terraform の外の操作。解除は to-latest）
#   to-latest           切り戻しの解除: トラフィックを最新リビジョンへ戻す（次の terraform apply の前に必ず戻す）
#   alert-test [N]      5xx アラートの動作確認: POST /fs-check case=alert-test を N 回（既定 3）投げて 500 を出す
#                       （FS_CHECK=1 のときだけ。無効なら 404）
#   環境変数: SVC（既定 terraform output service_name）、REGION（既定 asia-northeast1）、FRESHNESS（ログの範囲。既定 1d）、
#             BASE_URL / TOKEN（alert-test 用。BASE_URL の既定は terraform output service_url）
set -euo pipefail

cd "$(dirname "$0")/.."

REGION="${REGION:-asia-northeast1}"
FRESHNESS="${FRESHNESS:-1d}"
cmd="${1:-}"
shift || true

# サービス名はメインのシェルで 1 回だけ解決する（コマンド置換の中で失敗しても止まらないため）
resolve_svc() {
  if [[ -z "${SVC:-}" ]]; then
    SVC=$(terraform -chdir=terraform/gcp output -raw service_name 2>/dev/null) || true
  fi
  if [[ -z "${SVC:-}" || "$SVC" == *$'\n'* ]]; then
    echo "サービス名を取得できません（SVC=... で指定するか、terraform/gcp を apply 済みか・ADC が切れていないか確認）" >&2
    exit 1
  fi
}
svc() { echo "$SVC"; }

# Cloud Logging を新しい方から N 件読み、時系列（古い順）に並べ直して出す
read_logs() { # read_logs <filter> <N> <format>
  gcloud logging read "$1" --freshness="$FRESHNESS" --order=desc --limit="$2" --format="$3" | tac
}

base_filter() { echo "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$(svc)\""; }

logs() {
  local n="${1:-50}"
  read_logs "$(base_filter) AND (logName:\"run.googleapis.com%2Fstdout\" OR logName:\"run.googleapis.com%2Fstderr\")" "$n" \
    'value(timestamp.date("%Y-%m-%d %H:%M:%S"),resource.labels.revision_name,textPayload)'
}

errors() {
  local n="${1:-50}"
  read_logs "$(base_filter) AND ((logName:\"run.googleapis.com%2Fstderr\" AND (textPayload:\"error \" OR textPayload:\"PHP Fatal\" OR textPayload:\"PHP Warning\")) OR (logName:\"run.googleapis.com%2Frequests\" AND httpRequest.status>=500))" "$n" \
    'value(timestamp.date("%Y-%m-%d %H:%M:%S"),resource.labels.revision_name,httpRequest.status,httpRequest.requestUrl,textPayload)'
}

requests() {
  local n="${1:-50}"
  read_logs "$(base_filter) AND logName:\"run.googleapis.com%2Frequests\"" "$n" \
    'value(timestamp.date("%Y-%m-%d %H:%M:%S"),httpRequest.status,httpRequest.latency,httpRequest.requestMethod,httpRequest.requestUrl)'
}

revisions() {
  local n="${1:-10}" s image images
  s=$(svc)
  # ダイジェスト → タグの対応表。引けなければ空（ダイジェストの短縮表示になる）
  image=$(terraform -chdir=terraform/gcp output -raw image_uri 2>/dev/null) || image=""
  images="[]"
  if [[ -n "$image" && "$image" != *$'\n'* ]]; then
    images=$(gcloud artifacts docker images list "$image" --include-tags --format=json 2>/dev/null) || images="[]"
  fi
  echo "== リビジョン（新しい順に $n 件）"
  gcloud run revisions list --service "$s" --region "$REGION" --limit "$n" --format=json \
    | IMAGES="$images" php -r '
        $tags = [];
        foreach (json_decode((string) getenv("IMAGES"), true) ?: [] as $i) {
          $t = $i["tags"] ?? [];
          $t = is_array($t) ? $t : array_filter(explode(",", (string) $t));
          if ($t !== [] && isset($i["version"])) { $tags[$i["version"]] = implode(",", $t); }
        }
        foreach (json_decode(stream_get_contents(STDIN), true) ?: [] as $r) {
          $img = (string) ($r["spec"]["containers"][0]["image"] ?? "");
          $digest = str_contains($img, "@") ? substr($img, strpos($img, "@") + 1) : "";
          $label = $digest === "" ? basename($img) : (isset($tags[$digest]) ? "tag=" . $tags[$digest] : substr($digest, 0, 19));
          printf("  %-24s %s  %s\n", $r["metadata"]["name"] ?? "?", substr((string) ($r["metadata"]["creationTimestamp"] ?? ""), 0, 16), $label);
        }'
  echo "== トラフィック"
  gcloud run services describe "$s" --region "$REGION" --format=json \
    | php -r '
        $d = json_decode(stream_get_contents(STDIN), true) ?: [];
        foreach ($d["status"]["traffic"] ?? [] as $t) {
          printf("  %3d%%  %s%s\n", $t["percent"] ?? 0, $t["revisionName"] ?? "?", !empty($t["latestRevision"]) ? "（最新に追従）" : "（固定）");
        }
        $fixed = array_filter($d["spec"]["traffic"] ?? [], fn($t) => empty($t["latestRevision"]) && ($t["percent"] ?? 0) > 0);
        if ($fixed) { echo "  注意: トラフィックが特定のリビジョンに固定されています。次の terraform apply の前に scripts/ops.sh to-latest で戻してください\n"; }'
  echo "（リビジョンは設定も含む。戻す前に gcloud run revisions describe <REV> --region $REGION で環境変数を確認）"
}

rollback() {
  local rev="${1:-}"
  [[ -n "$rev" ]] || { echo "usage: $0 rollback <REVISION>（候補は $0 revisions）" >&2; exit 2; }
  gcloud run services update-traffic "$(svc)" --region "$REGION" --to-revisions="$rev=100"
  echo "トラフィックを $rev に固定しました。原因を直したら $0 to-latest で戻してから terraform apply してください"
}

to_latest() {
  gcloud run services update-traffic "$(svc)" --region "$REGION" --to-latest
}

alert_test() {
  local n="${1:-3}" url="${BASE_URL:-}" t="${TOKEN:-}" auth=() i code
  [[ -n "$url" ]] || url=$(terraform -chdir=terraform/gcp output -raw service_url)
  if [[ -z "$t" && "$url" == *.run.app* ]]; then t=$(gcloud auth print-identity-token); fi
  [[ -n "$t" ]] && auth=(-H "Authorization: Bearer $t")
  for i in $(seq 1 "$n"); do
    # 存在しない case で FsCheck が例外を投げ、index.php の例外処理が 500 を返す
    code=$(curl -sS "${auth[@]}" -o /dev/null -w '%{http_code}' -X POST -d 'case=alert-test' "$url/fs-check")
    echo "  #$i POST /fs-check case=alert-test -> $code"
    if [[ "$code" == 404 ]]; then
      echo "FS_CHECK が無効です（404）。terraform.tfvars に fs_check = true を書いて apply してから実行してください" >&2
      exit 1
    fi
  done
  echo "5xx を $n 回出しました。数分でアラートのメールが届きます（Cloud Monitoring > アラート でインシデントも確認できる）"
}

case "$cmd" in
  logs | errors | requests | revisions | rollback | to-latest) resolve_svc ;;
esac

case "$cmd" in
  logs) logs "$@" ;;
  errors) errors "$@" ;;
  requests) requests "$@" ;;
  revisions) revisions "$@" ;;
  rollback) rollback "$@" ;;
  to-latest) to_latest ;;
  alert-test) alert_test "$@" ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 2 ;;
esac
