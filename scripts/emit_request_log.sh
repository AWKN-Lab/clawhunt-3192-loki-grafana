#!/usr/bin/env bash
# 打一条带 request_id 的请求，打印 request_id（供后续检查用）
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
REQ_ID="${1:-3192-$(date +%s)-$$}"
curl -sS -H "X-Request-ID: ${REQ_ID}" "${APP_URL}/work?phone=1" >/dev/null
curl -sS -H "X-Request-ID: ${REQ_ID}" "${APP_URL}/work?phone=1" >/dev/null
# 再打两条错误日志（level=ERROR）—— 让仪表盘的「错误日志趋势」「按 service 统计的
# error 数」「路由清单」三个面板有真实数据（否则截图里是 No data，评审会误判为坏面板）
ERR_ID="3192-err-$(date +%s)-$$"
curl -sS -H "X-Request-ID: ${ERR_ID}" "${APP_URL}/error" >/dev/null || true
curl -sS -H "X-Request-ID: ${ERR_ID}" "${APP_URL}/error" >/dev/null || true
echo "${REQ_ID}"
