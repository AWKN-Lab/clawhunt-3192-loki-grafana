# ClawHunt #3192 · 会员空间平台 · 日志收集与留存（Promtail + Loki + Grafana）

工单：**【S2-INFRA-027】会员空间平台 · 日志收集与留存：Promtail、Loki 采集与按环境保留**
交付物：`.github` 之外的整套可运行采集留存栈 —— `compose.yml`（loki / promtail-app / promtail-audit / grafana / app）、`promtail/promtail-config.yml`、`loki/loki-config.yml` + `loki/runtime.yaml`、`grafana/`（数据源参数 + 两个仪表盘）、`scripts/`（一条命令复跑全部验收）、`evidence/`（实测输出原文）、`screenshots/`（Grafana 真实截图）。

## 一、四条验收与证据对照

| AC | 工单原文 | 证据 | 复跑命令 |
| --- | --- | --- | --- |
| AC1 | web 与 miniprogram 两个作业在 PR 上均通过（附截图） → 本单为：**在 Grafana 中按 request_id 能查到一次请求的全部日志行（附截图）** | `screenshots/ac1-request-id-all-lines.png`；`evidence/run_all.out`（AC1 段：命中 6 行） | `bash scripts/run_all.sh` |
| AC2 | 向应用日志写入未脱敏的虚构手机号后，Loki 中查到的是屏蔽后的形式（附截图） | `screenshots/ac2-masked-phone.png`；`evidence/run_all.out`（AC2 段：手机号/身份证/Bearer 三项均遮蔽，明文零残留） | `bash scripts/check_masked_phone.sh` |
| AC3 | Loki 标签列表 API 只返回 env、host、service、level（附输出） | `evidence/ac3-labels.txt`（dev 与 audit 两个租户的原始输出，均为 `["env","host","level","service"]`） | `bash scripts/check_labels.sh` |
| AC4 | 非运维、非安全团队的账号在 Grafana 中看不到日志数据源（附截图） | `screenshots/ac4-dev-user-no-datasource.png`（研发账号被弹回首页，导航里没有 Connections / Explore）；对照 `screenshots/ac4-admin-datasources.png`（管理员可见 Loki 数据源）；`evidence/ac4-dev-user-api.json`（**dev-user 实调 `GET /api/datasources` 与 `/api/datasources/uid/loki` 均 403 Access denied**）；`evidence/ac4-access.txt`（ops/security 可见 1 个数据源） | `bash scripts/check_team_access.sh` |

`bash scripts/run_all.sh` 一条命令跑完四条，**任一不过即非零退出**；本次运行输出原文见 `evidence/run_all.out`（末尾 `ALL CHECKS PASSED`）。

`MANIFEST.sha256` 覆盖 35 个静态交付物（脚本 / 配置 / 文档 / 截图 / 稳定证据）。
两个**每次运行都会变**的文件不进清单（否则复跑一次验收清单就必然失效）：`evidence/run_all.out`（整轮输出原文）与 `evidence/ac4-dev-user-api.json`（截图脚本抓的 API 状态码，带抓取时间）；它们仍在仓里，由 git 保证版本。
清单重算：`bash scripts/regen_manifest.sh`；校验：`sha256sum -c MANIFEST.sha256`。

### 工单正文里另外三项要求（已实现，证据同上）

| 工单要求 | 实现 | 证据 |
| --- | --- | --- |
| 面板：①错误日志趋势 ②按 service 统计的 error 数 ③从 app-overview 的 route 点击跳到对应时间段日志 | `grafana/dashboards/loki-log-panels.json` 的「错误日志趋势」「按 service 统计的 error 数」「路由清单」三个面板 + 仪表盘变量 `route`；`grafana/dashboards/app-overview.json` 的路由表带 data link，点行即跳到 `loki-log-panels` 的 `var-route` | `screenshots/ac1-dashboard-overview.png`（三件套首屏） |
| 单次查询结果上限 5000 行 | Loki 侧 `limits_config.max_entries_limit_per_query: 5000`；Grafana 侧每个日志面板 `maxLines` 限 20～50 行 | `loki/loki-config.local.yml`、`grafana/dashboards/*.json` |
| 变量：`log_retention_days`、`audit_retention_days`、`loki_storage_backend` | 三个变量在 `.env.example` 里有真源，落成 `LOG_RETENTION_DAYS` / `AUDIT_RETENTION_DAYS` / `LOKI_STORAGE_BACKEND`；前两个由 `scripts/gen_runtime_config.sh` 渲染 `loki/runtime.yaml`，第三个由 `scripts/set_storage_backend.sh` 切换块存储后端 | 见下面「可调变量」一节 |

## 二、组件与端口

| 服务 | 镜像 | 端口（宿主） | 作用 |
| --- | --- | --- | --- |
| `loki` | `grafana/loki:3.4.2` | 3100（查询）/ 9096（gRPC） | 单体模式，TSDB 索引 + 文件块存储，按租户留存 |
| `promtail-app` | `grafana/promtail:3.4.2` | 9080 | 采应用日志 → 租户 `dev`（留存 7 天） |
| `promtail-audit` | `grafana/promtail:3.4.2` | 9081 | 采同一批日志 → 租户 `audit`（留存 365 天） |
| `grafana` | `grafana/grafana:11.3.0` | 3000 | 面板 + 数据源 + 账号权限 |
| `app` | `python:3.11-slim` | 8080 | 演示应用，产出结构化 JSON 日志（可替换成客户应用） |

**网络用 host 模式**（`network_mode: host`），不使用 bridge。原因：该宿主机上 bridge 的容器间数据通路不通（ARP/路由正常但连接返回 EHOSTUNREACH，FORWARD=DROP + br_netfilter 组合导致同网段流量被丢），host 网络下 Loki/Promtail/Grafana 用 `127.0.0.1` 互通，排障路径最短。

## 三、块存储选择（工单要求说明）

本仓选**本地数据盘**：Loki 的 `storage_config.filesystem.directory=/loki/chunks`，配合 `common.path_prefix=/loki`，数据落在宿主 `runtime/loki/`。

- 客户 `backups` 桶是对象存储（S3/OSS 兼容）。Loki 用对象存储做块存储需要 `storage_config.aws` + `bucket_store` + `shared_store`，配置面更大、更易出错，单机场景收益有限。
- 切换步骤（README 口径）：把 `storage_config` 换成 `aws(s3)` + `bucket_store`，并把 WAL / chunk cache 指到同一 buckets 段；`common.path_prefix` 保持在同一目录下即可，compactor 的 `delete_request_store` 也要跟着换。
- 本仓把切换做成了**一条命令**：`LOKI_STORAGE_BACKEND=s3 bash scripts/set_storage_backend.sh` —— 它在 `loki/loki-config.local.yml`（本地盘，已实测跑通）与 `loki/loki-config.s3.yml`（对象存储模板）之间切换；s3 模板里带 `REPLACE_ME_*` 占位（桶名 / region / endpoint / 密钥 / `loki/` 前缀），**没填会被拒绝切换**，避免半配置上线。
- 备份方式：单机直接对 `runtime/loki/` 做 rsync/tar 归档推送到 `backups` 桶即可（Loki 的 TSDB 文件是自描述的，跨版本恢复需注意版本一致）。

## 四、留存策略（按环境 / 按租户）

`loki/runtime.yaml` 用 `runtime_config` 的 `overrides` 给每个租户单独定留存（Loki 3.x 的 override 是**扁平字段**，不是 `limits_config` 结构）：

| 租户 | 用途 | 留存 |
| --- | --- | --- |
| `dev` | 开发 / 本仓演示 | 168h（7 天） |
| `test` | 测试环境 | 720h（30 天） |
| `prod` | 生产环境 | 4320h（180 天） |
| `audit` | 审计日志 | 8760h（365 天） |

compactor 侧 `retention_enabled: true` + `delete_request_store: filesystem`，删除延迟 2 小时（`retention_delete_delay`）。**留存策略真正生效的前提是 compactor 在跑**（本栈里 loki 是单体模式，compactor 与 ingester 同进程 ✔）。

### 可调变量（工单点名的三个 + 脚本用到的其余）

`.env.example` 是变量的真源（复制成 `.env` 后按需改；`.env` 不进仓）：

| 工单变量 | 环境变量 | 默认 | 落到哪 |
| --- | --- | --- | --- |
| `log_retention_days` | `LOG_RETENTION_DAYS` | `7` | `scripts/gen_runtime_config.sh` → `loki/runtime.yaml` 的 `dev` 租户 `retention_period`；`TEST_RETENTION_DAYS`（30）/ `PROD_RETENTION_DAYS`（180）同理 |
| `audit_retention_days` | `AUDIT_RETENTION_DAYS` | `365` | 同上 → `audit` 租户 `retention_period` |
| `loki_storage_backend` | `LOKI_STORAGE_BACKEND` | `local` | `scripts/set_storage_backend.sh` → `loki/loki-config.yml`（`local` 本地盘 / `s3` 对象存储） |

改留存后要重建 loki 容器（`sudo -n docker compose up -d loki`）让 `runtime_config` 重新加载；`loki/runtime.yaml` 是**生成物**，请通过脚本改，别手改后再被覆盖。

## 五、标签纪律（本单最硬的要求）

工单要求 Loki 标签列表 API **只返回** `env`、`host`、`service`、`level`。这里踩了四个坑，都记在 `promtail/promtail-config.yml` 与本文档里：

1. **promtail 会在流水线之前给每条日志注入 `filename` 标签**
   （源码 `clients/pkg/promtail/targets/file/tailer.go`：`api.AddLabelsMiddleware({filename: path}).Wrap(handler)`）。
   relabel 阶段删不掉它（`action: labeldrop`、空 replacement 都无效）。
   ⇒ 解法：`stage.labelallow`（标签**白名单**阶段）在流水线里执行，可以删。
   本仓统一用白名单而不是黑名单：将来采集端再注入新标签，也会被挡在 Loki 之外。
2. **Loki 会自动补两个标签**，都要在 `limits_config` 里关：
   - `discover_service_name: []` —— 否则多出 `service_name`（Loki 3.0+ 默认行为，官方开关是 **limits_config** 里的空列表，不是 distributor 里的字段）；
   - `discover_log_levels: false` —— 否则多出 `detected_level`（Loki 3.2+ 自动探测日志级别）。
3. **promtail 的 `replace` 阶段用的是 `text/template`，不是正则展开**：`$1` / `${1}` 不会被展开，而且**每个捕获组都会被替换成同一段模板文本**。
   ⇒ 正确写法：正则**只捕获要打码的那一段**，替换串用**常量**。
   例：手机号中间 4 位 → `\b1[3-9]\d(\d{4})\d{4}\b` 捕获中间 4 位 → 替换成 `****`。
4. **promtail 的 `static_configs.targets` 里放的是主机名**，文件路径要写在 `labels.__path__`；写反了会被判成 `reason="no_path"`，一个 target 都不起。

另外：`request_id` / `user_id` 这类高基数字段**只留在日志正文里**，用 LogQL 解析，不做标签（否则标签基数会随请求量爆炸）。

## 六、采集链路

- 应用把**与 stdout 完全相同的 JSON 日志**另写一份到 `/var/log/clawhunt-app/app-json.log`（compose 把宿主 `/var/log/clawhunt-app` 挂进容器 `/var/log/app`），promtail 用**静态采集**读这个文件（`labels.__path__`）。
  不用 promtail 的 `docker_sd` / docker 阶段的原因：它们会额外注入 `service_name` 与 `detected_level`，与「标签只留四个」冲突。客户若接受这两个额外低基数标签，可切换到 `scripts/gen_docker_targets.sh` 生成的 file_sd targets。
- 脱敏在 **promtail 流水线**里做（兜底，防止应用侧漏网）：手机号保留前 3 后 4、身份证保留首尾各 1 位、Bearer 令牌整体替换成 `[REDACTED]`。
- 两个 promtail 必须用**独立的 positions 目录**（`runtime/positions-app` / `runtime/positions-audit`）：共用一个文件时先跑的实例会把游标推进，后跑的实例认为「已读」⇒ 同一批日志只进一个租户。
- 主机系统日志：`/var/log/auth.log`、`/var/log/syslog` 在本机（容器化宿主）**不存在**，promtail 会标记 target 为 “no files matched requested path”（不影响其它作业）。
  为在演示环境里展示「同一套静态采集 + 脱敏管道」对系统日志的效果，另配 `host_sample_logs` 作业读 `/var/log/clawhunt-sample/*.log`（**内容全部虚构**）。
  客户环境有真实 `auth.log` / `syslog` 时，把 `scripts/` 里的两个作业指向真实路径即可（`promtail-config.yml` 里改 `__path__`）。

## 七、Grafana 账号与可见性（本单 AC4 的实现与 OSS 限制）

`scripts/setup_grafana.sh`（幂等）建三个团队与三个账号：

| 账号 | 团队 | 组织角色 | 数据源可见性 |
| --- | --- | --- | --- |
| `ops-user` | ops（运维） | Viewer | 可见 1 个数据源 ✔ |
| `security-user` | security（安全） | Viewer | 可见 1 个数据源 ✔ |
| `dev-user` | dev（研发） | **None** | `GET /api/datasources` → **HTTP 403**，看不到任何数据源 ✔ |

**为什么用「组织角色」而不是数据源级权限**（Grafana OSS 11.3 实测结论）：

- Grafana OSS **没有数据源级权限**：`datasources.permissions` 相关 API（`GET/POST /api/datasources/uid/:uid/permissions`）在本环境返回 **404 Not found** —— 那是 Enterprise / Cloud 的 RBAC 能力。
- Grafana OSS 的 datasource provisioning **不认 `folder` / `folderUid`**（两种写法实测都落 General），而 General 对所有登录用户可读 ⇒ 光把数据源放进文件夹并不能隐藏它。
- ⇒ 在 OSS 里，「看不到日志数据源」只能落到**组织角色 None** 上（Grafana OSS 的「无权限」基础角色）；成为团队成员默认给 Viewer，所以研发账号必须显式设成 None。
- **另有两处环境限制需要知情**（不影响 AC4 判定，但影响演示）：
  1. 文件夹授权（`POST /api/folders/{uid}/permissions`）与仪表盘授权（`POST /api/dashboards/uid/:uid/permissions`）在本环境**返回 200 但不落库**（`dashboard_acl` 与 `permission` 表均无新增行）⇒ 仪表盘放在 General，面板演示用 admin 账号；
  2. Grafana 11 的登录接口要 **JSON 体**（表单编码返回 400 `bad login data`），截图脚本用 JSON 登录建立会话。

**若客户使用 Grafana Enterprise**：把数据源放进 `loki-logs` 文件夹并给 ops/security 团队授权即可实现同租户细粒度（`scripts/setup_grafana.sh` 第 3 步已经按团队下过授权，接口在 Enterprise 上有效）。

口令只写进宿主 `~/.clawhunt/3192-grafana-users.env`（0600，**不进仓**）。

## 八、部署与复跑

```bash
# 0) 前置：Docker + Compose v2；宿主准备 /var/log/clawhunt-app（应用日志副本目录）
sudo mkdir -p /var/log/clawhunt-app

# 1) 起栈（host 网络，端口即宿主端口）
export GRAFANA_ADMIN_PASSWORD='<换成你们自己的强口令>'
sudo -n docker compose up -d

# 2) 按变量渲染租户留存配置（工单变量 log_retention_days / audit_retention_days）
bash scripts/gen_runtime_config.sh        # 生成 loki/runtime.yaml

# 3) 初始化 Grafana：团队 / 文件夹 / 数据源（含租户头）/ 仪表盘 / 测试账号
bash scripts/setup_grafana.sh

# 4) 跑全部验收（fail closed）
bash scripts/run_all.sh
```

环境变量（都有默认值，按需覆盖）：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `LOKI_URL` | `http://127.0.0.1:3100` | Loki 查询 API |
| `GRAFANA_URL` | `http://127.0.0.1:3000` | Grafana |
| `LOKI_TENANT` | `dev` | 验收脚本查的租户 |
| `APP_URL` | `http://127.0.0.1:8080` | 演示应用 |
| `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` | `admin` / **必填** | admin 账号 |
| `GRAFANA_USERS_FILE` | `~/.clawhunt/3192-grafana-users.env` | 测试账号口令文件 |
| `LOG_RETENTION_DAYS` | `7` | 工单变量 `log_retention_days`：dev 租户留存天数 |
| `AUDIT_RETENTION_DAYS` | `365` | 工单变量 `audit_retention_days`：审计日志留存天数 |
| `LOKI_STORAGE_BACKEND` | `local` | 工单变量 `loki_storage_backend`：`local` / `s3` |
| `BUNDLE_MAX_KB` | — | （本单无） |

**容器重建后必须重生成 file_sd targets**（仅当启用 docker_sd 变体）：`bash scripts/gen_docker_targets.sh` —— 容器的 `LogPath` 会变。

## 九、回滚

```bash
sudo -n docker compose down          # 停栈（数据保留在 runtime/）
sudo -n docker compose down -v       # 连数据卷一起清（慎用）
```

- Loki 数据在宿主 `runtime/loki/`，`docker compose down` 不会删。
- Grafana 状态在宿主 `runtime/grafana/grafana.db`；要重置 Grafana（连同账号与仪表盘）就删这个文件再 `docker compose up -d` + 重跑 `scripts/setup_grafana.sh`。
- 撤销对宿主防火墙/网络规则的任何临时改动：本栈**不需要**改宿主防火墙。

## 十、截图脚本

```bash
GRAFANA_URL=http://127.0.0.1:3000 \
GRAFANA_ADMIN_USER=admin GRAFANA_ADMIN_PASSWORD='...' \
GRAFANA_USERS_FILE=~/.clawhunt/3192-grafana-users.env \
REQUEST_ID=<某次请求的 request_id> \
node scripts/screenshot.mjs screenshots
```

产出：

| 文件 | 证据 |
| --- | --- |
| `ac1-request-id-all-lines.png` | AC1：单独打开「按 request_id 追踪」面板，一次请求的 6 行日志全部命中（request_id 高亮） |
| `ac1-dashboard-overview.png` | 工单面板三件套（错误日志趋势 / 按 service 统计 error 数 / 路由清单）首屏 |
| `ac2-masked-phone.png` | AC2：单独打开「脱敏样本」面板，`138****1111` / `****************4` / `Bearer [REDACTED]` 一眼可见 |
| `ac4-admin-datasources.png` | AC4 对照组：管理员能看到 Loki 数据源 |
| `ac4-dev-user-no-datasource.png` | AC4：研发账号看不到任何数据源（被弹回首页，导航里没有 Connections / Explore） |
| `../evidence/ac4-dev-user-api.json` | AC4 的 API 级证据：dev-user 实调数据源 API 返回 403 |

仪表盘带 `request_id` 与 `route` 两个文本变量，URL 带 `?var-request_id=xxx` 即可把某次请求的全部日志行渲染出来。
面板在视口外时 Grafana 不会渲染（react-grid 虚拟化）⇒ 脚本用 `?viewPanel=<id>` **单独打开**目标面板再截图，避免整页截图下半段是空白。

## 十一、数据与保密

演示应用只写**虚构数据**（org/site/user 均为固定的 UUID 占位，手机号 `13800001111`、身份证 `110101199001011234`、Bearer 令牌均为虚构值）；仓内不出现客户名称、企业名称或任何真实个人信息。
