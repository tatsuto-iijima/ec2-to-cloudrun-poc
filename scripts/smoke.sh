#!/usr/bin/env bash
# サンプルアプリのスモークテスト。
#   1. GET /health が 200 で {"status":"ok"}
#   2. GET / が 200
#   3. POST /update が 303 で / にリダイレクトし、更新した値が表示される
#   4. DATA_DIR/DATA_FILE（指定時）に更新した値が書かれている
#   5. S3 オブジェクト（aws CLI があり S3_BUCKET 指定時）に同じ内容が入っている
#
# 使い方: BASE_URL=http://localhost:8080 DATA_DIR=./data scripts/smoke.sh
#   Cloud Run（IAM 認証）に向ける場合: BASE_URL が *.run.app なら gcloud auth print-identity-token で ID トークンを付ける
#   （TOKEN 環境変数で明示も可）。DATA_DIR は空にし、S3 の確認は実バケットと AWS_PROFILE で行う:
#   BASE_URL=$URL DATA_DIR= S3_ENDPOINT= S3_BUCKET=$(terraform -chdir=terraform/aws output -raw bucket_name) scripts/smoke.sh
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
DATA_DIR="${DATA_DIR:-}"
DATA_FILE="${DATA_FILE:-data.json}"
S3_BUCKET="${S3_BUCKET:-}"
S3_KEY_PREFIX="${S3_KEY_PREFIX:-}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
TOKEN="${TOKEN:-}"

if [[ -z "$TOKEN" && "$BASE_URL" == *.run.app* ]]; then
  TOKEN=$(gcloud auth print-identity-token)
fi
auth=()
[[ -n "$TOKEN" ]] && auth=(-H "Authorization: Bearer $TOKEN")

key="smoke"
value="ok-$(date +%s)"
fail=0

pass() { echo "PASS: $*"; }
ng() { echo "FAIL: $*"; fail=1; }

# 1. health
body=$(curl -sS "${auth[@]}" -w '\n%{http_code}' "$BASE_URL/health")
code=${body##*$'\n'}
if [[ "$code" == "200" && "$body" == *'"status":"ok"'* ]]; then pass "GET /health -> 200"; else ng "GET /health -> $code"; fi

# 2. index
code=$(curl -sS "${auth[@]}" -o /dev/null -w '%{http_code}' "$BASE_URL/")
if [[ "$code" == "200" ]]; then pass "GET / -> 200"; else ng "GET / -> $code"; fi

# 3. update（303 → / に更新後の値が出る）
code=$(curl -sS "${auth[@]}" -o /dev/null -w '%{http_code}' -X POST --data-urlencode "key=$key" --data-urlencode "value=$value" "$BASE_URL/update")
if [[ "$code" == "303" ]]; then pass "POST /update -> 303"; else ng "POST /update -> $code"; fi
if curl -sS "${auth[@]}" "$BASE_URL/" | grep -q "$value"; then pass "GET / に更新後の値が表示される"; else ng "GET / に更新後の値が無い"; fi

# 4. DATA_DIR のファイル
if [[ -n "$DATA_DIR" ]]; then
  if grep -q "\"$key\": \"$value\"" "$DATA_DIR/$DATA_FILE"; then pass "$DATA_DIR/$DATA_FILE に書かれている"; else ng "$DATA_DIR/$DATA_FILE に無い"; fi
fi

# 5. S3 オブジェクト（任意）
if [[ -n "$S3_BUCKET" ]] && command -v aws >/dev/null 2>&1; then
  endpoint_opt=()
  [[ -n "$S3_ENDPOINT" ]] && endpoint_opt=(--endpoint-url "$S3_ENDPOINT")
  # 取得の失敗（aws CLI の認証など）と内容の不一致は区別して表示する
  if s3_body=$(aws "${endpoint_opt[@]}" s3 cp "s3://$S3_BUCKET/$S3_KEY_PREFIX$DATA_FILE" - 2>&1); then
    if grep -q "\"$key\": \"$value\"" <<<"$s3_body"; then
      pass "s3://$S3_BUCKET/$S3_KEY_PREFIX$DATA_FILE に同じ内容がある"
    else
      ng "s3://$S3_BUCKET/$S3_KEY_PREFIX$DATA_FILE の内容が一致しない"
    fi
  else
    ng "s3://$S3_BUCKET/$S3_KEY_PREFIX$DATA_FILE を取得できない（aws CLI の認証を確認: unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; export AWS_PROFILE=<profile>; aws sso login）: $(head -n1 <<<"$s3_body")"
  fi
fi

if [[ "$fail" == "0" ]]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
