#!/usr/bin/env bash
# AC1：按 request_id 查到一次请求的**全部日志行**
# 注意：promtail 按 sync_period（默认 1s）轮询采集，打完请求必须**轮询等待**
# 日志落到 Loki，否则会误判成「查不到」。
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
REQ_ID="${1:?用法: query_by_request_id.sh <request_id>}"
LOGQL="{service=\"app\"} |= \"${REQ_ID}\""

hits=0
for i in $(seq 1 20); do
  python3 ./loki_query.py "${TENANT}" "${LOGQL}" 3600 > /tmp/ac1.json
  hits="$(python3 -c "
import json
d=json.load(open('/tmp/ac1.json'))
print(sum(len(s.get('values',[])) for s in d.get('data',{}).get('result',[])))")"
  echo "  第 ${i} 次查询命中 ${hits} 行"
  [ "${hits}" -ge 3 ] && break
  sleep 2
done

python3 - <<PY
import json
d=json.load(open("/tmp/ac1.json"))
res=d.get("data",{}).get("result",[])
lines=[v[1] for s in res for v in s.get("values",[])]
print("request_id      : ${REQ_ID}")
print("命中日志行数     :", len(lines))
print("标签             :", sorted({k for s in res for k in s.get("stream",{})}))
for l in sorted(lines): print("  ", l)
if len(lines)<1: raise SystemExit("FAIL AC1：按 request_id 没查到任何日志行")
if len(lines)<3: raise SystemExit("FAIL AC1：一次请求应有多行日志（started/handled/finished），实测 %d 行" % len(lines))
print("PASS AC1：一次请求的全部日志行可按 request_id 查到（%d 行）" % len(lines))
PY
