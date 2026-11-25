#!/usr/bin/env bash
# AC3：Loki 标签列表 API 只返回 env / host / service / level
set -euo pipefail
cd "$(dirname "$0")"; . ./lib.sh
loki_get "${LOKI_URL}/loki/api/v1/labels" > /tmp/ac3.json
python3 - <<PY
import json
d=json.load(open("/tmp/ac3.json"))
labels=sorted(d.get("data",[]))
expect=["env","host","level","service"]
print("Loki 标签列表 API 返回 :", labels)
print("期望（低基数四标签）   :", expect)
if labels!=expect: raise SystemExit("FAIL AC3：标签集合不符，实际=%s" % labels)
print("PASS AC3：标签集合恰为 env/host/service/level")
PY
