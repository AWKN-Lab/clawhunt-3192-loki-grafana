#!/usr/bin/env bash
# 一键复跑四条验收（fail closed：任一不过即非零退出）
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh

echo "########## 0. 前置检查（应用在跑 / 日志文件可读 / Loki ready）"
curl -sS -o /dev/null -w "  app  HTTP %{http_code}\n" "${APP_URL}/healthz" || true
curl -sS -o /dev/null -w "  loki HTTP %{http_code}\n" "${LOKI_URL}/ready"
[ -r "${APP_LOG_FILE:-/var/log/clawhunt-app/app-json.log}" ] || \
  { echo "FAIL 前置：应用日志文件不可读（${APP_LOG_FILE:-/var/log/clawhunt-app/app-json.log}）" >&2; exit 1; }
echo "  应用日志行数：$(wc -l < "${APP_LOG_FILE:-/var/log/clawhunt-app/app-json.log}")"
sleep 6

echo
echo "########## AC1 按 request_id 查全部日志行"
./query_by_request_id.sh "$(./emit_request_log.sh | tail -1)"
echo; echo "########## AC2 兜底脱敏（手机号/身份证/Bearer）"
./check_masked_phone.sh
echo; echo "########## AC3 标签集合"
./check_labels.sh
echo; echo "########## AC4 团队数据源可见性"
./check_team_access.sh
echo
echo "ALL CHECKS PASSED"
