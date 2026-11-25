#!/usr/bin/env bash
# 切换 Loki 的块存储后端（平台工单变量 LOKI_STORAGE_BACKEND：local | s3）
#
#   local —— 本地数据盘（默认，已在本仓实测跑通）
#   s3    —— 客户 backups 桶的 loki/ 前缀（对象存储）
#
# 用法：LOKI_STORAGE_BACKEND=s3 bash scripts/set_storage_backend.sh
#       （s3 需要先把 loki/loki-config.s3.yml 里的桶名/region/密钥填好）
set -euo pipefail
cd "$(dirname "$0")/.."

BACKEND="${LOKI_STORAGE_BACKEND:-local}"
case "${BACKEND}" in
  local)
    cp loki/loki-config.local.yml loki/loki-config.yml
    echo "已切到本地数据盘（loki/loki-config.local.yml → loki/loki-config.yml）"
    ;;
  s3)
    if grep -qE "REPLACE_ME" loki/loki-config.s3.yml; then
      echo "loki/loki-config.s3.yml 里还有 REPLACE_ME 占位（桶名/region/前缀），先填好再切" >&2
      exit 1
    fi
    cp loki/loki-config.s3.yml loki/loki-config.yml
    echo "已切到对象存储（loki/loki-config.s3.yml → loki/loki-config.yml）"
    echo "注意：切换后要重建 loki 容器并重新放行 compactor 的删除请求存储"
    ;;
  *) echo "LOKI_STORAGE_BACKEND 只能是 local 或 s3（现值：${BACKEND}）" >&2; exit 1;;
esac
