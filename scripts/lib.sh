#!/usr/bin/env bash
# #3192 公共配置：所有检查脚本共用（fail closed，不兜底默认值）
set -euo pipefail
LOKI_URL="${LOKI_URL:-http://127.0.0.1:3100}"
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3000}"
TENANT="${LOKI_TENANT:-dev}"
APP_URL="${APP_URL:-http://127.0.0.1:8080}"
ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
ADMIN_PASS="${GRAFANA_ADMIN_PASSWORD:?必须显式提供 GRAFANA_ADMIN_PASSWORD（fail closed）}"
USERS_FILE="${GRAFANA_USERS_FILE:-$HOME/.clawhunt/3192-grafana-users.env}"
# file_sd 的 targets 文件（compose 把仓库的 runtime/promtail-targets 挂到容器 /etc/promtail/targets）
PROMTAIL_TARGETS_FILE="${PROMTAIL_TARGETS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../runtime/promtail-targets" 2>/dev/null && pwd)/docker.json}"
export LOKI_URL GRAFANA_URL TENANT APP_URL ADMIN_USER ADMIN_PASS USERS_FILE

loki_get() { curl -sS -H "X-Scope-OrgID: ${TENANT}" "$@"; }
gf_admin() { curl -sS -u "${ADMIN_USER}:${ADMIN_PASS}" "$@"; }
# 取脚本用户凭据（由 setup_grafana.sh 生成，0600，不进仓）
user_cred() { # $1=用户名
  local line
  line="$(grep -E "^${1}=" "${USERS_FILE}" | head -1 || true)"
  [ -n "$line" ] || { echo "缺少用户 ${1} 的凭据（${USERS_FILE}）" >&2; return 1; }
  printf '%s' "${line#*=}"
}
gf_user() { # $1=用户名 $2=路径
  curl -sS -u "$1:$(user_cred "$1")" "$2"
}
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*" >&2; exit 1; }
