# 验收对照 · ClawHunt #3192

单子：**【S2-INFRA-027】会员空间平台 · 日志收集与留存：Promtail、Loki 采集与按环境保留**
交付：Promtail + Loki + Grafana 采集留存栈（公开仓，本目录即交付树）
运行环境：宿主 `8.134.179.161`（容器化，host 网络），Loki 3.4.2 / Promtail 3.4.2 / Grafana 11.3.0 / Python 3.11
复跑命令：`bash scripts/run_all.sh`（fail closed，任一不过即非零退出）

## 验收标准原文（逐字引用）

1. 在 Grafana 中按 request_id 能查到一次请求的全部日志行（附截图）
2. 向应用日志写入未脱敏的虚构手机号后，Loki 中查到的是屏蔽后的形式（附截图）
3. Loki 标签列表 API 只返回 env、host、service、level（附输出）
4. 非运维、非安全团队的账号在 Grafana 中看不到日志数据源（附截图）

## 验收 1：按 request_id 能查到一次请求的全部日志行

**通过。** 一次请求在应用侧写 3 行（request started / handled / finished），本仓演示应用因脚本连打两次共 6 行，全部落在 Loki 同一条流里。

- 截图：`screenshots/ac1-request-id-all-lines.png`（Grafana 仪表盘「Loki 日志面板」；顶部是 `request_id` 文本变量，下方「按 request_id 追踪：一次请求的全部日志行（AC1）」面板逐行展示同一 request_id 的 6 行）
- 实测输出：`evidence/run_all.out` 的 AC1 段

```
request_id      : 3192-1795593933-1590728
命中日志行数     : 6
标签             : ['env', 'host', 'level', 'service']
PASS AC1：一次请求的全部日志行可按 request_id 查到（6 行）
```

- 复现：`bash scripts/emit_request_log.sh` 打一次请求拿到 request_id，再 `bash scripts/query_by_request_id.sh <request_id>`。
  脚本会**轮询等待** promtail 采集（默认 1s sync period），避免「打完立刻查」造成误判。

## 验收 2：写入未脱敏的虚构手机号后，Loki 里是屏蔽后的形式

**通过。** 应用写的 JSON 日志里手机号 / 身份证 / Bearer 令牌**都是明文**；脱敏发生在 promtail 流水线（兜底）。实测输出原文见 `evidence/run_all.out` 的 AC2 段：

```
手机号明文            13800001111                                    出现=False（期望 否）
手机号屏蔽形式          138****1111                                    出现=True（期望 是）
身份证明文            110101199001011234                             出现=False（期望 否）
身份证屏蔽形式          1****************4                             出现=True（期望 是）
Bearer 令牌明文      eyJhbGciOiJIUzI1NiJ9...                        出现=False（期望 否）
Bearer 屏蔽形式          Bearer [REDACTED]                              出现=True（期望 是）
PASS AC2：Loki 中查到的是屏蔽后的形式（手机号/身份证/Bearer 三项均已遮蔽，明文零残留）
```

- 截图：`screenshots/ac2-masked-phone.png`（Grafana 日志面板里逐行可见 `"customer_phone": "138****1111"`、`"customer_id_no": "1****************4"`、`"authorization": "Bearer [REDACTED]"`）
- 复现：`bash scripts/check_masked_phone.sh`

## 验收 3：Loki 标签列表 API 只返回 env、host、service、level

**通过。** dev 与 audit 两个租户的标签列表 API 原始输出（`evidence/ac3-labels.txt`）：

```
$ curl -s -H 'X-Scope-OrgID: dev'   http://127.0.0.1:3100/loki/api/v1/labels
{"status":"success","data":["env","host","level","service"]}
$ curl -s -H 'X-Scope-OrgID: audit' http://127.0.0.1:3100/loki/api/v1/labels
{"status":"success","data":["env","host","level","service"]}
```

- 复现：`bash scripts/check_labels.sh`
- 实现要点（为什么能恰好四个）：
  - promtail 侧用 `stage.labelallow` 白名单（env/host/service/level），挡掉 promtail 自动注入的 `filename`；
  - Loki 侧关掉两个自动标签：`limits_config.discover_service_name: []`（否则多 `service_name`）、`limits_config.discover_log_levels: false`（否则多 `detected_level`）。

## 验收 4：非运维、非安全团队的账号看不到日志数据源

**通过。**

- `evidence/ac4-access.txt`（三个账号的原始输出）：
  - `ops-user` → HTTP 200，可见 1 个数据源（Loki）
  - `security-user` → HTTP 200，可见 1 个数据源（Loki）
  - `dev-user` → **HTTP 403**，看不到任何数据源；直取 `GET /api/datasources/uid/loki` 也是 403
- 截图（对照）：
  - `screenshots/ac4-admin-datasources.png` —— 管理员在 Connections → Data sources 能看到 Loki 数据源
  - `screenshots/ac4-dev-user-datasources.png`、`screenshots/ac4-dev-user-explore.png` —— 研发账号登录后导航里**没有 Connections / Explore**，访问数据源页被弹回首页
- 复现：`bash scripts/check_team_access.sh`
- 实现与边界：Grafana OSS 11.3 **没有数据源级权限**（相关 API 返回 404，属 Enterprise 能力），且 datasource provisioning 不认 `folder`/`folderUid` ⇒ 本单用**组织角色**落地可见性：ops/security = Viewer，dev = **None**（Grafana OSS 的「无权限」基础角色）。详见 README 第七节。

## 一次性跑完全部验收的输出

`evidence/run_all.out`（末尾 `ALL CHECKS PASSED`，退出码 0）。
