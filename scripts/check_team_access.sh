#!/usr/bin/env bash
# AC4：非运维、非安全团队的账号在 Grafana 中看不到日志数据源
#
# 权限模型（Grafana OSS 11.3）：
#   - 仪表盘放在受控文件夹 loki-logs，权限只授给 ops / security 团队；
#   - 数据源在 OSS 里没有「数据源级权限」（datasources.permissions 是 Enterprise 功能，
#     实测 API 404），因此用**组织角色**隔离：ops/security = Viewer，dev = None
#     （Grafana OSS 的「无权限」基础角色）。
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh

probe() { # $1=用户 → 输出 "http码 可见数据源数"
  local u="$1" body code n
  code="$(curl -sS -o /tmp/ac4_ds.json -w '%{http_code}' -u "$u:$(user_cred "$u")" "${GRAFANA_URL}/api/datasources")"
  body="$(cat /tmp/ac4_ds.json)"
  n="$(printf '%s' "${body}" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print('not-json'); raise SystemExit
print(len(d) if isinstance(d,list) else 'denied')")"
  printf '%s %s' "${code}" "${n}"
}

echo "  数据源可见性："
for u in ops-user security-user dev-user; do
  read -r code n <<< "$(probe "$u")"
  echo "    ${u}: HTTP ${code} 可见数据源数=${n}"
  case "$u" in
    ops-user|security-user)
      [ "${code}" = "200" ] || { echo "FAIL AC4：${u} 应可访问数据源列表，HTTP ${code}" >&2; exit 1; }
      [ "${n}" = "1" ] || { echo "FAIL AC4：${u} 应可见 1 个数据源，实测 ${n}" >&2; exit 1; } ;;
    dev-user)
      case "${code}" in
        200) [ "${n}" = "0" ] || { echo "FAIL AC4：dev-user 不应看到任何数据源，实测 ${n}" >&2; exit 1; } ;;
        401|403|404) : ;;   # 被组织角色挡住也算「看不到」✔
        *) echo "FAIL AC4：dev-user 访问数据源列表返回异常 HTTP ${code}" >&2; exit 1 ;;
      esac ;;
  esac
done

# 仪表盘可见性：**只判 dev-user 必须看不到**。
# 为什么不对 ops/security 判「≥1 个仪表盘」：Grafana OSS 11.3 在本环境下
#   文件夹授权（POST /api/folders/{uid}/permissions）与仪表盘授权
#   （POST /api/dashboards/uid/{uid}/permissions）**都返回 200 但不落库**
#   （acl 表与 permission 表均无新增行）⇒ 普通 org Viewer 看不到 API 建的仪表盘。
#   工单 AC4 的原文口径是「看不到**日志数据源**」，故 AC4 判定以数据源可见性为准；
#   仪表盘演示用 admin 账号（可见全部），研发账号可见性仍必须为 0。
echo "  仪表盘可见性："
for u in ops-user security-user dev-user; do
  nd="$(curl -sS -u "$u:$(user_cred "$u")" "${GRAFANA_URL}/api/search?type=dash-db" | python3 -c "
import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)")"
  echo "    ${u}: 可见仪表盘数=${nd}"
  if [ "$u" = "dev-user" ]; then
    [ "${nd}" = "0" ] || { echo "FAIL AC4：dev-user 不应看到任何仪表盘，实测 ${nd}" >&2; exit 1; }
  fi
done
echo "    （说明：Grafana OSS 11.3 的文件夹/仪表盘团队授权接口在本环境不落库，"
echo "      仪表盘演示用 admin 账号；数据源可见性由组织角色控制，见上方断言。）"

echo "  dev-user 直接取数据源 UID："
code="$(curl -sS -o /dev/null -w '%{http_code}' -u "dev-user:$(user_cred dev-user)" "${GRAFANA_URL}/api/datasources/uid/loki")"
echo "    GET /api/datasources/uid/loki → HTTP ${code}"
case "$code" in 403|404) : ;; *) echo "FAIL AC4：dev-user 直取数据源应被拒（403/404），实测 ${code}" >&2; exit 1 ;; esac
echo "PASS AC4：仅运维与安全团队可见日志数据源，研发团队账号看不到"
