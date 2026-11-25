#!/usr/bin/env python3
"""生成 Grafana 数据源的创建请求体（POST /api/datasources）。

连接参数的唯一真源是 grafana/datasources/loki.yml。

为什么不用 Grafana 的 provisioning 目录来放数据源：
  - Grafana 11.3 的 datasource provisioning **不认 folder / folderUid**（实测落 General）；
  - 而且 provision 出来的数据源是**只读**的（"Cannot update read-only data source"），
    后面再用 API 调整就会撞 "Cannot update read-only data source"。
⇒ 数据源统一由 setup_grafana.sh 用 API 建（见 scripts/setup_grafana.sh）。

用法: ds_payload.py > /tmp/ds_payload.json
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
YML = os.path.join(HERE, "..", "grafana", "datasources", "loki.yml")


def val(raw, key, default=None):
    m = re.search(r"^\s*%s:\s*(.+)$" % re.escape(key), raw, re.M)
    if not m:
        return default
    v = m.group(1).strip()
    if v.startswith('"') and v.endswith('"'):
        v = v[1:-1]
    return v


def main():
    raw = open(YML, encoding="utf-8").read()
    payload = {
        "uid": val(raw, "uid", "loki"),
        "name": val(raw, "name", "Loki"),
        "type": val(raw, "type", "loki"),
        "access": val(raw, "access", "proxy"),
        "url": val(raw, "url", "http://127.0.0.1:3100"),
        # ★ 落到受控文件夹：只有被授权的运维/安全团队可见（AC4）
        "folderUid": "loki-logs",
        "isDefault": True,
        "editable": True,
        "jsonData": {
            "maxLines": 5000,
            "timeout": 60,
            # ★ Loki 多租户：Grafana 侧必须带 X-Scope-OrgID，否则查询报
            #   "no org id" / 400（面板全红）。dev 是演示租户（保留 7 天）。
            "httpHeaderName1": "X-Scope-OrgID",
            "derivedFields": [
                {
                    "name": "RequestID",
                    "matcherRegex": '"request_id":"([^"]+)"',
                    "url": "$${__value.raw}",
                }
            ],
        },
        "secureJsonData": {"httpHeaderValue1": "dev"},
    }
    if not payload["url"]:
        raise SystemExit("解析不到 url：%s" % YML)
    print(json.dumps(payload, ensure_ascii=False))


if __name__ == "__main__":
    main()
