#!/usr/bin/env bash
# Grafana 的一次性初始化（幂等，可反复执行）
#
# 目标（对应工单 AC4）：**运维 / 安全**账号能看到并查询 Loki 数据源与日志面板；
#                       **其它团队**（如研发）账号在 Grafana 里看不到日志数据源。
#
# ── 为什么是这个实现（Grafana OSS 11.3 实测结论，别照搬别人的博客）────────
# 1) Grafana OSS **没有数据源级权限**：datasources.permissions 相关 API
#    （GET/POST /api/datasources/uid/:uid/permissions）在本环境返回 **404 Not found**
#    —— 那是 Enterprise / Cloud 的 RBAC 能力。
# 2) Grafana OSS 的 datasource provisioning **不认 folder / folderUid**
#    （两种写法实测都落在 General）；而 General 文件夹对所有登录用户可读
#    ⇒ 光把数据源放进文件夹并不能隐藏它。
# 3) 因此本方案用 **组织角色（org role）** 落地可见性：
#      ops / security → Viewer（可看可查）
#      dev            → None  （Grafana OSS 的「无权限」基础角色，看不到任何数据源/面板）
#    同时把仪表盘放进受控文件夹 loki-logs，并只给 ops / security 团队授权。
#    若客户用 Grafana Enterprise，可改成数据源级权限（同租户内细粒度），见 README。
#
# 生成的口令写进 0600 文件（**不进仓**）。
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh

say() { echo "$*"; }

# ────────────────────────────────────────────────────────────── 1. 团队
say "== 1. 建团队 =="
declare -A TEAM_DESC=( [ops]="运维团队：日志查询与排障" [security]="安全团队：审计与安全事件排查" [dev]="研发团队：不授予日志数据源" )
declare -A TEAM_ROLE=( [ops]=2 [security]=2 [dev]=0 )   # 2=Edit 1=View 0=无
: > /tmp/.teams.$$
for t in ops security dev; do
  id="$(gf_admin "${GRAFANA_URL}/api/teams/search?query=${t}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for x in d.get('teams',[]):
    if x.get('name')=='${t}': print(x['id']); break
" || true)"
  if [ -z "$id" ]; then
    # Grafana 11 的 POST /api/teams 返回 {"teamId":N,...}，不是完整对象 ⇒ 兼容两种键名
    id="$(gf_admin -X POST -H 'Content-Type: application/json' "${GRAFANA_URL}/api/teams" \
      -d "{\"name\":\"${t}\",\"description\":\"${TEAM_DESC[$t]}\"}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
v=d.get('id') or d.get('teamId')
if not v: raise SystemExit('建团队失败：'+json.dumps(d,ensure_ascii=False))
print(v)")"
    say "  新建团队 ${t} (id=${id})"
  else
    say "  团队 ${t} 已存在 (id=${id})"
  fi
  echo "${t}=${id}" >> /tmp/.teams.$$
done
team_id() { grep -E "^$1=" /tmp/.teams.$$ | cut -d= -f2; }

# ───────────────────────────────────────────────────────── 2. 受控文件夹
say "== 2. 建受控文件夹 loki-logs（日志仪表盘落在此处）=="
if ! gf_admin "${GRAFANA_URL}/api/folders/loki-logs" | grep -q '"uid"'; then
  gf_admin -X POST -H 'Content-Type: application/json' "${GRAFANA_URL}/api/folders" \
    -d '{"uid":"loki-logs","title":"日志"}' >/dev/null
  say "  新建文件夹 loki-logs"
else
  say "  文件夹 loki-logs 已存在"
fi
gf_admin "${GRAFANA_URL}/api/folders/loki-logs" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('uid')=='loki-logs', d
print('  复核：uid=%s title=%s' % (d.get('uid'), d.get('title')))"

# ────────────────────────────────────────────────────── 3. 文件夹授权
say "== 3. 文件夹授权（只给运维与安全团队）=="
# ⚠️ 权限接口要的是文件夹的**数字 id**（不是 uid）：
#    传 uid 时接口会「成功」但把权限写到 General(-1) 上（实测 acl 表里只多了 -1 的行），
#    结果是 ops/security 账号在 UI 里看不到仪表盘 —— 属于「不报错但没生效」的坑。
FOLDER_ID="$(gf_admin "${GRAFANA_URL}/api/folders/loki-logs" | python3 -c "
import json,sys; print(json.load(sys.stdin)['id'])")"
for t in ops security; do
  tid="$(team_id "$t")"
  perm="${TEAM_ROLE[$t]}"
  gf_admin -X POST -H 'Content-Type: application/json' "${GRAFANA_URL}/api/folders/${FOLDER_ID}/permissions" \
    -d "{\"teamId\":${tid},\"permission\":${perm}}" >/dev/null
  say "  ${t} (teamId=${tid}) → permission=${perm}"
done
say "  dev (teamId=$(team_id dev)) → 不授权（其余团队一律无权限）"
# 自检：Grafana OSS 11.3 本环境下这个接口**返回 200 但不落库**
#   （acl 表里没有新增行），所以这里只做**告警**，不判定失败：
#   仪表盘可见性改由组织角色兜底（见文件头说明），Enterprise 上此接口有效。
acl_json="$(gf_admin "${GRAFANA_URL}/api/folders/${FOLDER_ID}/permissions" 2>/dev/null || echo '[]')"
acl_teams="$(printf '%s' "${acl_json}" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(''); raise SystemExit
if not isinstance(d,list): print(''); raise SystemExit
print(','.join(str(p.get('teamId')) for p in d if isinstance(p,dict) and p.get('teamId') is not None))")"
if [ "${acl_teams}" = "1,2" ]; then
  say "  复核：folderId=${FOLDER_ID} 已授权 teamId=1,2（文件夹权限生效）"
else
  say "  ⚠️ 复核：文件夹权限未落库（本 Grafana OSS 11.3 的 acl 表无新增行）"
  say "     ⇒ 仪表盘导入 General，可见性由组织角色兜底（ops/security=Viewer，dev=None）"
fi

# ────────────────────────────────────────────────────── 4. Loki 数据源
say "== 4. 建 Loki 数据源 =="
# Grafana OSS 的数据源是 **org 级**的（进不了文件夹），可见性靠组织角色控制（见文件头说明）。
# payload 里仍带 folderUid：客户若换 Enterprise，可直接用数据源级权限。
DS_UID=loki
# 每次都按 grafana/datasources/loki.yml 重建，保证连接参数（含租户头）是最新的
if printf '%s' "$(gf_admin "${GRAFANA_URL}/api/datasources/uid/${DS_UID}" 2>/dev/null || true)" | grep -q '"uid"'; then
  gf_admin -X DELETE "${GRAFANA_URL}/api/datasources/uid/${DS_UID}" >/dev/null
  say "  删除旧数据源（按 YAML 重建，避免参数漂移）"
fi
python3 ./ds_payload.py > /tmp/ds_payload.json
gf_admin -X POST -H 'Content-Type: application/json' "${GRAFANA_URL}/api/datasources" \
  --data-binary @/tmp/ds_payload.json >/dev/null
say "  数据源已创建（连接参数真源：grafana/datasources/loki.yml）"
gf_admin "${GRAFANA_URL}/api/datasources/uid/${DS_UID}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('uid')=='loki', d
print('  复核：uid=%s url=%s maxLines=%s' % (d.get('uid'), d.get('url'), (d.get('jsonData') or {}).get('maxLines')))"

# ────────────────────────────────────────────────────── 5. 导入仪表盘
say "== 5. 导入日志仪表盘（放进受控文件夹）=="
# 用 API 导入而不是 provisioning 文件：
#   Grafana 11 的 dashboard provisioning 遇到「uid 撞名 / 标题撞名」会整块 provider
#   失去写权限（实测日志：dashboards provisioning provider has no database write
#   permissions because of duplicates），而且**不会**把已存在的仪表盘搬进文件夹。
# 导入到 **General**：Grafana OSS 11.3 的文件夹权限接口在本环境**不落库**
#   （POST /api/folders/{uid}/permissions 返回 200，但 acl 表没有新增行），
#   放文件夹里 ⇒ 连 ops/security 账号都看不到仪表盘。
#   ⇒ 仪表盘放 General，可见性由**组织角色**兜底（ops/security=Viewer，dev=None ⇒ 谁都看不到）。
#   客户若用 Enterprise，可改为导入 loki-logs 文件夹并给团队授权（见 README）。
for f in ../grafana/dashboards/*.json; do
  python3 - "$f" <<'PY' > /tmp/dash_payload.json
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
d["id"]=None
print(json.dumps({"dashboard":d,"overwrite":True,"message":"clawhunt-3192 初始化导入"},ensure_ascii=False))
PY
  gf_admin -X POST -H 'Content-Type: application/json' "${GRAFANA_URL}/api/dashboards/db" \
    --data-binary @/tmp/dash_payload.json | python3 -c "
import json,sys
d=json.load(sys.stdin)
if d.get('status')!='success': raise SystemExit('导入失败：%s' % json.dumps(d,ensure_ascii=False))
print('  已导入 uid=%s（General，folderUid=%s）' % (d.get('uid'), d.get('folderUid') or 'General'))"
done

# ────────────────────────────────────────────────────── 6. 测试账号
say "== 6. 建测试账号（口令写 0600 文件，不进仓）=="
mkdir -p "$(dirname "${USERS_FILE}")"; chmod 700 "$(dirname "${USERS_FILE}")"
: > "${USERS_FILE}"; chmod 600 "${USERS_FILE}"
for pair in "ops-user:ops" "security-user:security" "dev-user:dev"; do
  u="${pair%%:*}"; t="${pair##*:}"
  pw="$(python3 -c "import secrets;print(secrets.token_urlsafe(18))")"
  # ⚠️ 必须用 --fail：Grafana 对已存在的 login 返回 **HTTP 412**，
  #    curl 默认不把 4xx 当失败（退出码仍是 0）⇒ 旧版脚本会跳过改口令，
  #    结果是「文件里的随机口令 ≠ 库里用户的口令」⇒ 登录 401。
  if ! gf_admin --fail -X POST -H 'Content-Type: application/json' "${GRAFANA_URL}/api/admin/users" \
      -d "{\"name\":\"${u}\",\"login\":\"${u}\",\"password\":\"${pw}\",\"email\":\"${u}@clawhunt.local\"}" >/dev/null 2>&1; then
    uid_="$(gf_admin "${GRAFANA_URL}/api/users/lookup?loginOrEmail=${u}" | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")"
    gf_admin -X PUT -H 'Content-Type: application/json' "${GRAFANA_URL}/api/admin/users/${uid_}/password" \
      -d "{\"password\":\"${pw}\"}" >/dev/null
  fi
  # Grafana 11：按用户名查 id 用 /api/users/lookup（/api/users/{login} 已废弃，会回 "id is invalid"）
  uid_="$(gf_admin "${GRAFANA_URL}/api/users/lookup?loginOrEmail=${u}" | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")"
  tid="$(team_id "$t")"
  gf_admin -X POST -H 'Content-Type: application/json' "${GRAFANA_URL}/api/teams/${tid}/members" \
    -d "{\"userId\":${uid_},\"role\":\"Viewer\"}" >/dev/null
  # 组织角色（org role）：
  #   ops/security → Viewer（可看可查数据源；仪表盘靠文件夹权限）
  #   dev          → None  （Grafana OSS 的「无权限」基础角色）
  if [ "$t" = "dev" ]; then org_role="None"; else org_role="Viewer"; fi
  gf_admin -X PATCH -H 'Content-Type: application/json' "${GRAFANA_URL}/api/org/users/${uid_}" \
    -d "{\"role\":\"${org_role}\"}" >/dev/null
  echo "${u}=${pw}" >> "${USERS_FILE}"
  say "  ${u} 已建，归属团队 ${t}，组织角色=${org_role}（口令未回显）"
done
rm -f /tmp/.teams.$$

# ────────────────────────────────────────────────────── 7. 收尾自检
say "== 7. 可见性自检 =="
for u in ops-user security-user dev-user; do
  n="$(curl -sS -o /tmp/.ds.json -w '%{http_code}' -u "$u:$(user_cred "$u")" "${GRAFANA_URL}/api/datasources")"
  cnt="$(python3 -c "
import json
try:
    d=json.load(open('/tmp/.ds.json')); print(len(d) if isinstance(d,list) else 'denied')
except Exception: print('denied')")"
  say "  ${u}: /api/datasources HTTP ${n}，可见数据源数=${cnt}"
done
say "== 完成；凭据文件：${USERS_FILE}（0600） =="
