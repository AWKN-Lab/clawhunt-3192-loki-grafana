#!/usr/bin/env bash
# 生成 file_sd 的 targets 文件：写入**容器真实的 docker json 日志文件路径** + 四个标签
# （由 docker inspect 取容器 id → /var/lib/docker/containers/<id>/<id>-json.log）
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
CONTAINER="${APP_CONTAINER:-clawhunt-3192-app-1}"
OUT="${PROMTAIL_TARGETS_FILE:-/etc/promtail/targets/docker.json}"
# 用 docker 自己给的 .LogPath（别自己拼：docker root 可配，驱动也可换）
path="$(sudo -n docker inspect -f '{{.LogPath}}' "${CONTAINER}" 2>/dev/null || true)"
[ -n "$path" ] || { echo "取不到容器 ${CONTAINER} 的 LogPath" >&2; exit 1; }
sudo -n test -f "$path" || { echo "容器 json 日志文件不存在：${path}" >&2; exit 1; }
mkdir -p "$(dirname "${OUT}")"
printf '[{"targets": ["%s"], "labels": {"env": "dev", "host": "3192-demo", "service": "app"}}]\n' "$path" > "${OUT}.tmp"
mv "${OUT}.tmp" "${OUT}"
echo "已写入 ${OUT}："
echo "  ${path}"
