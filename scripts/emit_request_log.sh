#!/usr/bin/env bash
# 打一条带 request_id 的请求，打印 request_id（供后续检查用）
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
REQ_ID="${1:-3192-$(date +%s)-$$}"
curl -sS -H "X-Request-ID: ${REQ_ID}" "${APP_URL}/work?phone=1" >/dev/null
curl -sS -H "X-Request-ID: ${REQ_ID}" "${APP_URL}/work?phone=1" >/dev/null
echo "${REQ_ID}"
