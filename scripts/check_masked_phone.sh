#!/usr/bin/env bash
# AC2：应用侧写入未脱敏的虚构手机号 / 身份证 / Bearer 令牌
#       → Loki 中查到的是屏蔽后的形式（且明文一个都不许出现）
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
REQ_ID="3192-mask-$(date +%s)-$$"
curl -sS -H "X-Request-ID: ${REQ_ID}" "${APP_URL}/work?phone=13800001111" >/dev/null
LOGQL="{service=\"app\"} |= \"${REQ_ID}\""

n=0
for i in $(seq 1 20); do
  python3 ./loki_query.py "${TENANT}" "${LOGQL}" 3600 > /tmp/ac2.json
  n="$(python3 -c "
import json
d=json.load(open('/tmp/ac2.json'))
print(sum(len(s.get('values',[])) for s in d.get('data',{}).get('result',[])))")"
  [ "${n}" -ge 3 ] && break
  sleep 2
done

python3 - <<PY
import json
d=json.load(open("/tmp/ac2.json"))
lines=[v[1] for s in d.get("data",{}).get("result",[]) for v in s.get("values",[])]
raw_phone="13800001111"; masked_phone="138****1111"
raw_id="110101199001011234"; masked_id="1****************4"
raw_bearer="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4eXoifQ.c2FtcGxlLXNpZ25hdHVyZQ"; masked_bearer="Bearer [REDACTED]"
print("request_id  : ${REQ_ID}")
print("Loki 命中行 :", len(lines))
for l in sorted(lines): print("  ", l)
blob="\n".join(lines)
checks=[
  ("手机号明文", raw_phone, False),
  ("手机号屏蔽形式", masked_phone, True),
  ("身份证明文", raw_id, False),
  ("身份证屏蔽形式", masked_id, True),
  ("Bearer 令牌明文", raw_bearer, False),
  ("Bearer 屏蔽形式", masked_bearer, True),
]
bad=[]
for name,needle,want in checks:
    hit = needle in blob
    print("%-16s %-46s 出现=%s（期望 %s）" % (name, needle, hit, "是" if want else "否"))
    if hit != want: bad.append(name)
if bad: raise SystemExit("FAIL AC2：以下检查不通过：%s" % ", ".join(bad))
print("PASS AC2：Loki 中查到的是屏蔽后的形式（手机号/身份证/Bearer 三项均已遮蔽，明文零残留）")
PY
