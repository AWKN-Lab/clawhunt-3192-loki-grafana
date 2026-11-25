"""#3192 演示应用：产生结构化 JSON 日志（每个请求多行，带同一个 request_id）。

仅用标准库。用途：
- AC1：一次请求的**全部日志行**用同一个 request_id 串起来，可在 Grafana 按 request_id 查到；
- AC2：故意把**未脱敏的虚构手机号**写进日志正文，验证 Promtail 的兜底脱敏 pipeline。

数据全部虚构，不含任何真实个人信息或企业信息。
"""
import json
import os
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

ENV = os.environ.get("APP_ENV", "dev")
SERVICE = os.environ.get("APP_SERVICE", "app")
HOST = os.environ.get("APP_HOST", "3192-demo")
PORT = int(os.environ.get("APP_PORT", "8080"))
# 与 stdout 完全相同的 JSON 日志副本（供 promtail 采集）
LOG_FILE = os.environ.get("APP_LOG_FILE", "/var/log/app/app-json.log")
# 虚构样本：13800001111 是工单里公开的虚构测试号，不对应任何真实用户
SAMPLE_PHONE = "13800001111"
SAMPLE_ID = "110101199001011234"
SAMPLE_BEARER = "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4eXoifQ.c2FtcGxlLXNpZ25hdHVyZQ"


def log(level, msg, request_id, route, status, duration_ms, extra=None):
    rec = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + ".%03dZ" % (int(time.time() * 1000) % 1000),
        "level": level,
        "logger": "app.request",
        "msg": msg,
        "request_id": request_id,
        "org_id": "00000000-0000-4000-8000-000000000001",
        "site_id": "00000000-0000-4000-8000-000000000002",
        "user_id": "00000000-0000-4000-8000-000000000003",
        "route": route,
        "status": status,
        "duration_ms": duration_ms,
        "env": ENV,
        "service": SERVICE,
        "host": HOST,
    }
    if extra:
        rec.update(extra)
    line = json.dumps(rec, ensure_ascii=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()
    # 同一份 JSON 日志再落一份到挂载的文件（供 promtail 静态采集）：
    # 这样 Loki 的标签集合可以精确控制为 env/host/service/level 四个
    # （promtail 的 docker 阶段会额外注入 service_name 与 detected_level 两个标签）。
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # 静音默认访问日志（我们自己出结构化日志）
        pass

    def do_GET(self):
        started = time.time()
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        request_id = self.headers.get("X-Request-ID") or str(uuid.uuid4())
        route = parsed.path
        log("INFO", "request started", request_id, route, 200, 0)

        extra = None
        if query.get("phone"):
            # AC2：未脱敏的虚构手机号 + 身份证 + Bearer 令牌，故意写进正文
            extra = {
                "customer_phone": SAMPLE_PHONE,
                "customer_id_no": SAMPLE_ID,
                "authorization": SAMPLE_BEARER,
            }
        if route == "/error":
            log("ERROR", "simulated downstream failure", request_id, route, 500, 0, extra)
            body = b'{"status":"error"}'
            status = 500
        else:
            log("INFO", "request handled", request_id, route, 200, 0, extra)
            body = b'{"status":"ok"}'
            status = 200
        duration_ms = round((time.time() - started) * 1000, 3)
        log("INFO", "request finished", request_id, route, status, duration_ms, extra)

        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Request-ID", request_id)
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
