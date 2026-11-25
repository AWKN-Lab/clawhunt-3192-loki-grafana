#!/usr/bin/env bash
# 重新生成 MANIFEST.sha256（交付物清单）
#
# 口径：清单只覆盖**静态交付物**（脚本 / 配置 / 文档 / 截图 / 稳定的证据文件）。
# 每次运行都会变的「运行产物」不进清单，否则复跑一次验收清单就失效、校验必然报 FAILED：
#   evidence/run_all.out          —— 整轮验收的输出原文（含时间戳与耗时）
#   evidence/ac4-dev-user-api.json —— 截图脚本抓的 dev-user API 状态码（含抓取时间）
# 这两个文件仍然在仓里（是证据），但由 git 保证版本、不由 MANIFEST 保证字节。
set -euo pipefail
cd "$(dirname "$0")/.."

find . -type f \
  -not -path "./.git/*" \
  -not -name "MANIFEST.sha256" \
  -not -path "./evidence/run_all.out" \
  -not -path "./evidence/ac4-dev-user-api.json" \
  | sed 's|^\./||' | LC_ALL=C sort | xargs sha256sum > MANIFEST.sha256

echo "已重算 MANIFEST.sha256：$(wc -l < MANIFEST.sha256) 个文件"
sha256sum -c MANIFEST.sha256 | grep -v ': OK' || echo "全部 OK"
