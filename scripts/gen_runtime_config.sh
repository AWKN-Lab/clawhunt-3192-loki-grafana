#!/usr/bin/env bash
# 按环境变量渲染 Loki 的租户级留存配置（loki/runtime.yaml）
#
# 平台工单要求的三个变量在这里落地两个：
#   LOG_RETENTION_DAYS     —— dev/test/prod 的默认留存天数（按用途分档，见下）
#   AUDIT_RETENTION_DAYS   —— service=audit 的审计日志留存天数
# 第三个变量 LOKI_STORAGE_BACKEND（local | s3）决定用哪份 Loki 配置，
#   见 scripts/set_storage_backend.sh 与 README「块存储切换」一节。
#
# 用法：
#   LOG_RETENTION_DAYS=7 AUDIT_RETENTION_DAYS=365 bash scripts/gen_runtime_config.sh
set -euo pipefail
cd "$(dirname "$0")/.."

LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"          # dev 默认 7 天
TEST_RETENTION_DAYS="${TEST_RETENTION_DAYS:-30}"       # test 30 天
PROD_RETENTION_DAYS="${PROD_RETENTION_DAYS:-180}"      # prod 180 天
AUDIT_RETENTION_DAYS="${AUDIT_RETENTION_DAYS:-365}"    # audit 365 天

case "${LOG_RETENTION_DAYS}" in ''|*[!0-9]*) echo "LOG_RETENTION_DAYS 必须是非负整数" >&2; exit 1;; esac
case "${AUDIT_RETENTION_DAYS}" in ''|*[!0-9]*) echo "AUDIT_RETENTION_DAYS 必须是非负整数" >&2; exit 1;; esac

mkdir -p loki
cat > loki/runtime.yaml <<YAML
# 租户级留存覆盖（由 loki/runtime.yaml 加载；Loki 3.x 的 override 是扁平字段）
# 本文件由 scripts/gen_runtime_config.sh 生成 —— 变量真源见 .env.example：
#   LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS} / TEST_RETENTION_DAYS=${TEST_RETENTION_DAYS}
#   PROD_RETENTION_DAYS=${PROD_RETENTION_DAYS} / AUDIT_RETENTION_DAYS=${AUDIT_RETENTION_DAYS}
overrides:
  dev:
    retention_period: ${LOG_RETENTION_DAYS}h
  test:
    retention_period: ${TEST_RETENTION_DAYS}h
  prod:
    retention_period: ${PROD_RETENTION_DAYS}h
  audit:
    retention_period: ${AUDIT_RETENTION_DAYS}h
YAML
echo "已生成 loki/runtime.yaml：dev=${LOG_RETENTION_DAYS}h test=${TEST_RETENTION_DAYS}h prod=${PROD_RETENTION_DAYS}h audit=${AUDIT_RETENTION_DAYS}h"
