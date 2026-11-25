#!/usr/bin/env python3
"""Loki 查询助手（避免 shell 里的 URL 编码陷阱）。

用法:
  loki_query.py <tenant> <query> [start_seconds_ago] [end_seconds_ago]
输出: JSON（与 Loki /loki/api/v1/query_range 的 data 字段同构）

为什么不用 curl + 手拼 URL：
  - query 里有 `{service="app"} |= "req-123"` 这种带引号和管道的 LogQL，
    手拼 URL 极易出现「编码一次对、编码两次就 400」的坑；
  - 这里统一用 urllib.parse.urlencode 编码一次，失败时打印原始响应，便于排障。
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

LOKI_URL = os.environ.get("LOKI_URL", "http://127.0.0.1:3100")


def query(tenant, logql, start_ago=600, end_ago=0, limit=5000, direction=None):
    now = int(time.time() * 1e9)
    params = {
        "query": logql,
        "start": now - int(start_ago * 1e9),
        "end": now - int(end_ago * 1e9),
        "limit": str(limit),
    }
    if direction:
        params["direction"] = direction
    url = LOKI_URL + "/loki/api/v1/query_range?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"X-Scope-OrgID": tenant})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        raise SystemExit("Loki 查询失败 HTTP %s: %s\nURL: %s" % (e.code, body[:400], url))


def main():
    if len(sys.argv) < 3:
        raise SystemExit("用法: loki_query.py <tenant> <logql> [start_ago_s] [end_ago_s]")
    tenant, logql = sys.argv[1], sys.argv[2]
    start_ago = float(sys.argv[3]) if len(sys.argv) > 3 else 600
    end_ago = float(sys.argv[4]) if len(sys.argv) > 4 else 0
    print(json.dumps(query(tenant, logql, start_ago, end_ago), ensure_ascii=False))


if __name__ == "__main__":
    main()
