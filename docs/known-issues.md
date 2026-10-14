# 已知问题与验证记录

本文件记录 ProjeQtOr 容器化交付方案在真机验证过程中识别出的全部问题、证据与处置状态，
用于后续查阅与跟踪。新增问题请沿用本文编号规则（`P` = 需处置的缺陷（上游或本仓库交付侧），
`N` = 排查注意事项）。

| 项目 | 基线 |
|---|---|
| 镜像 | `ghcr.io/zzhkhyl/projeqtor:13.1.1`（多架构 amd64/arm64） |
| Chart | `projeqtor-0.1.0`（appVersion `13.1.1`） |
| 验证环境 | k3s 单节点 `<k3s 节点 IP>`，PostgreSQL 17.10（集群内 `projeqtor-postgres`） |
| 命名空间 | `projeqtor` |
| 报告日期 | 2026-10-14 |

状态图例：🔴 未处理 · 🟡 已定位待处置 · 🟢 已缓解/已验证 · ⚪ 说明性记录

---

## 1. 摘要

| 编号 | 问题 | 类别 | 严重度 | 影响范围 | 状态 |
|---|---|---|---|---|---|
| [P1](#p1--postgresql-下-v1301-升级脚本执行失败) | PostgreSQL 下 `V13.0.1` 升级脚本 3 条语句执行失败（MySQL 专有多表 `UPDATE`） | 上游缺陷 | 中 | 从 ≤13.0.0 升级且已有 `subtask` 数据的 PG 实例 | 🟢 已缓解 |
| [P2](#p2--缺少-user-agent-时请求被中断) | 缺失 `User-Agent` 的请求被应用错误处理器中断 | 上游缺陷 | 低 | 无头 HTTP 客户端（不含浏览器、不含本 Chart 探针） | 🟡 |
| [P3](#p3--可变版本-tag--ifnotpresent导致镜像更新不生效) | 可变版本 tag + `IfNotPresent`，导致镜像变更不会落到既有部署 | 交付侧 | 中 | 所有已部署实例在镜像重建后的升级 | 🟢 已缓解（本实例采用方案 1） |
| [P4](#p4--php-会话不在-pvc-上多副本不共享pod-重建掉登录) | `session.save_path` 未设置，PHP 会话落在容器 `/tmp`：Pod 重建即掉登录、多副本不共享 | 交付侧 | 中 | 所有实例（单副本升级掉登录；多副本共享失效） | 🟢 已修复（代码侧，待镜像重建生效） |
| [P5](#p5--files-目录可被-http-直读日志未认证可读附件绕过下载令牌) | `files/` 位于文档根内且未限制访问：日志未认证可读、附件绕过下载令牌 | 交付侧 | 中高 | 所有实例 | 🟢 已修复（代码侧，待镜像重建生效） |
| [P6](#p6--数据库未初始化时入口脚本生成的-parametersphp-不完整全站-0-字节白屏) | 数据库未初始化时生成残缺的 `parameters.php`（缺 `logFile`），`logTracing()` 直接 `exit()` → 全站 200 + 0 字节，且永远到不了登录页因而无法自愈 | 交付侧 | 高 | 所有数据库尚未初始化的实例（全新部署首次启动） | 🟢 已修复（代码侧，待镜像重建生效；本实例已实测恢复） |
| [N1](#n1--aes-加密类脱离框架不可用) | AES 加密类依赖 `pq_ord()` / `pq_substr()`，脱离框架无法直接调用 | 排查注意 | — | 仅影响外部调试脚本 | ⚪ |
| [N2](#n2--session-激活后无法再改-session-id) | `session_start()` 之后再调 `session_id()` 会报错 | 排查注意 | — | 仅影响外部调试脚本 | ⚪ |
| [N3](#n3--用户表名为-resource-而非-user) | 用户数据存于 `resource` 表，不存在 `user` 表 | 排查注意 | — | 仅影响 SQL 排查 | ⚪ |
| [N4](#n4--数据库不在-chart-内--自建-secret-的双键语义) | 数据库不在 Chart 内；自建 Secret 的 `POSTGRES_PASSWORD` / `PQ_DB_PASSWORD` 语义与轮换约束 | 部署知识 | — | 所有自备数据库的部署 | ⚪ |

**总体结论**：本次部署**功能正常**（全新安装、数据库升级、`admin/admin` 真实 HTTP 登录均验证通过）。
P1、P2 来自上游 ProjeQtOr 自身且都不阻断部署与使用；P1 已在本仓库侧提供幂等自愈缓解
（见 P1「处置记录」）。P3、P4、P5 属于本仓库交付侧：P3 是升级生效性问题，本实例已按方案 1
（固定不可变 tag）部署并验证生效，而 chart 与 CI 的默认行为未变 —— 新部署仍可能踩到；
P4 是「PHP 会话不在 PVC 上」、P5 是「`files/` 目录可被 HTTP 直读」，两者均已在镜像 /
模板 / 入口脚本侧修复，待重建镜像后生效与验证。P6 属本仓库交付侧且**严重度为高**：
它是「数据库尚未初始化」这一全新部署首次启动的必经状态下的致命缺陷（`smrd` 实例即因此白屏），
已在入口脚本侧修复，并在该实例上实测恢复（建库 357 张表 + `admin/admin` 真实登录通过）。

---

## 2. 验证基线

以下项目已验证通过，作为问题判断的背景基线。

| 验证项 | 结果 |
|---|---|
| Helm release | `projeqtor` / ns `projeqtor` / `deployed`（首轮验证时为 revision 1，后续滚动更新会使其递增） |
| Pod 状态 | `projeqtor-*` 与 `projeqtor-postgres-*` 均 `1/1 Running`，RESTARTS `0` |
| 镜像来源 | 确认为 CI 产出的 `ghcr.io/zzhkhyl/projeqtor:13.1.1`（非本地临时构建） |
| 数据库版本 | `parameter.dbVersion = V13.1.1`，与代码版本一致（故登录不会进入维护模式） |
| 数据库升级 | 全新安装 V0.0.0 → V13.1.1，遍历 182 个 `db/projeqtor_V*.sql` 版本脚本 / 357 张表，**唯一失败点为 P1** |
| 登录 | `admin/admin` 经真实 HTTP 全链路登录成功（见 [第 4 节](#4-登录验证方法可复现)） |
| 源码完整性 | 容器内 `tool/projeqtor.php`、`tool/getHash.php`、`tool/loginCheck.php`、`view/login.php`、`model/UserMain.php`、`model/Audit.php` 的 md5 与官方源码完全一致，无调试补丁残留 |
| 服务暴露 | Service `projeqtor:8080`（ClusterIP）；Ingress `<应用域名>`（traefik，80/443） |
| P1 数据回填 | 等价 PG 语句在真实库执行成功（`UPDATE 0` × 3 + `COMMIT`）；另在可回滚的隔离 schema 中验证语义正确（见 P1「处置记录」） |
| P1 自愈脚本 | `docker/pg-repair-subtask-idproject.php` 6 个用例全部通过（真实库幂等、修复生效、3 类异常路径均 exit 0） |
| 自愈逻辑上线 | 本实例以不可变 tag `sha-8a050b3` 滚动更新后，容器内 `PQ_PG_REPAIR=true`，启动日志出现 4 行 `[projeqtor-pg-repair]`（见 P3「处置记录」） |
| CI 触发范围 | 镜像输入未变更时不触发构建：以纯文档提交实测，该提交**不产生任何 Actions 运行**（按 `head_sha` 查询 `total_count=0`）；对照的前一次工作流自身变更提交正常触发构建（run #5，`Build and push` 步骤 success） |
| CI `paths` 完整性 | 逐个核对 Dockerfile 的 `COPY` 源（`docker/entrypoint`、`docker/healthz.php`、`docker/pg-repair-*.php`）均在 `docker/**` 之内，无构建上下文输入落在 `paths` 之外 |

---

## 3. 问题详情

### P1 · PostgreSQL 下 V13.0.1 升级脚本执行失败

**严重度**：中（数据一致性偏差；不阻断升级与使用）
**归属**：上游 ProjeQtOr 缺陷（脚本方言 + 补丁缺失）
**状态**：🟢 已缓解（上游缺陷仍在；本仓库已提供幂等自愈 + 已完成本实例数据回填）

#### 现象

首次安装（PG）完成后，日志出现：

```
2026-10-14 11:10:04.662 VERSION V13.0.1
2026-10-14 11:10:04.663 Error # 1 => SQL error while executing maintenance query for version V13.0.1 (see above message)
2026-10-14 11:10:04.663 Error # 2 => ...
2026-10-14 11:10:04.663 Error # 3 => ...
2026-10-14 11:10:04.664  WITH 3 ERRORS
2026-10-14 11:10:05.687 3 ERRORS DURING UPGRADE TO VERSION V13.1.1
```

全量升级日志中**仅此一处** `WITH N ERRORS`，即其余版本（含最新的 `V13.1.0`、`V13.1.1`）在 PG 上均为 `WITH NO ERROR`。

#### 证据

失败语句位于 `db/projeqtor_V13.0.1.sql:11-13`，为 **MySQL 专有的多表 UPDATE 语法**：

```sql
UPDATE `${prefix}subtask` s left join `${prefix}userstory` a on s.refType='UserStory' and s.refId=a.id SET s.idProject=a.idProject WHERE ...;
UPDATE `${prefix}subtask` s left join `${prefix}activity` a on s.refType='Activity' and s.refId=a.id SET s.idProject=a.idProject WHERE ...;
UPDATE `${prefix}subtask` s left join `${prefix}ticket` t on s.refType='Ticket' and s.refId=t.id SET s.idProject=t.idProject WHERE ...;
```

全项目 `db/projeqtor_V*.sql` 中，仅此一个文件使用该语法。

#### 根因

1. **升级脚本以 MySQL 方言编写**，PG 依赖字符串替换式转换器 `formatForDbType()`
   （`db/maintenanceFunctions.php:318`）在运行时翻译。该转换器覆盖反引号、
   `int(12) unsigned AUTO_INCREMENT`→`serial`、`datetime`→`timestamp`、`ENGINE/CHARSET` 剥离、
   `ALTER TABLE ... CHANGE` 重写、`STR_TO_DATE`→`to_timestamp` 等，
   但**没有多表 `UPDATE ... JOIN` 的转换规则**，语句被原样发往 PG → 语法错误。
2. **该版本漏配 PG 专用补丁**。上游采用「通用脚本 + 按需方言补丁」模式，
   `db/maintenance.php:175` 的主循环对每个中间版本执行 `projeqtor_V<版本>.sql`；
   对 PG 差异另有显式分支，例如 `db/maintenance.php:1567` 的
   `if (... and Sql::isPgsql()) runScript('V13.0.0.psql')`（对应文件 `projeqtor_V13.0.0.psql.sql`）。
   而 **V13.0.1 既无 `projeqtor_V13.0.1.psql.sql`，也无对应的 `isPgsql()` 分支**。

#### 影响

* **不阻断**：单条语句失败仅计错误数并回滚，随后继续（`db/maintenanceFunctions.php:72`），
  升级版本号照常推进至 `V13.1.1`，应用可正常启动与登录。
* **数据损失范围**：这三条语句本应把 `subtask.idProject` 与所属 UserStory / Activity / Ticket 的
  `idProject` 对齐。该回填在 PG 上**未执行**，`subtask.idProject` 可能残留与父对象不一致的值。
* **本实例实际影响为 0 行**：本实例是全新安装，`subtask` 表为空（0 行），无数据需要修正。
  风险只存在于「从 ≤13.0.0 升级、且升级前已存在 `subtask` 数据」的 PG 实例。

#### 处置记录

**① 本实例数据回填（已完成，2026-10-14）**

* 在真实 PG 实例执行等价语句：`UPDATE 0` × 3 → `COMMIT`（前后「与父对象不一致的行数」均为 0，
  与「全新安装、无数据」的结论一致）。
* 语义与边界验证（可回滚，零残留）：在隔离 schema 中造 4 行数据后执行同一组语句：

  ```text
  BEFORE : 1|UserStory|10|999   2|Activity|20|999   3|Ticket|30|400   4|UserStory|77|555
  UPDATE 1 / UPDATE 1 / UPDATE 0
  AFTER  : 1|UserStory|10|100   2|Activity|20|300   3|Ticket|30|400   4|UserStory|77|555
  立即重跑：UPDATE 0 × 3（幂等）
  ROLLBACK → 临时 schema 未保留
  ```

  结论：不一致行被正确修正；已一致行与孤立行（父对象不存在）保持不动，与上游 MySQL 语义一致。

**② 幂等启动自愈（已完成，2026-10-14）**

* 新增 `docker/pg-repair-subtask-idproject.php`：上述等价语句的 PG 实现。
* 接线：`docker/Dockerfile` 将其安装为 `/usr/local/bin/projeqtor-pg-repair.php`
  （**刻意放在 web 根目录之外**，避免出现可写数据库的未授权 HTTP 端点）；
  `docker/docker-entrypoint.sh` 在 Apache 启动前调用（步骤 4，非致命）。
* 开关：`PQ_PG_REPAIR`（默认 `true`，设为 `false` 关闭）。已登记到根 README 环境变量表、
  chart README 参数表与 `values.yaml` 的 `env` 注释，并确认经 ConfigMap `envFrom` 注入容器。
* 顺带修复：`charts/projeqtor/templates/configmap.yaml` 原先只硬编码渲染 6 个固定键，
  导致 `values.yaml` 中 `env` 下的其它键（含新增的 `PQ_PG_REPAIR`，以及 README 中提到的
  `PQ_DB_PREFIX`）**静默失效**；现改为遍历 `.Values.env` 全量渲染，与 values.yaml 的注释一致
  （已用 `helm lint` / `helm template --set env.PQ_PG_REPAIR=false` 校验）。
* 设计约束：仅当 `PQ_DB_TYPE=pgsql` 时生效；只发 `UPDATE`，不创建/修改/删除任何对象；
  配置缺失、类型不符、数据库不可达、表尚未建立等情形一律告警并 `exit 0`，绝不影响容器启动。

验证矩阵（在真实 Pod 内、对真实数据库执行）：

| 用例 | 条件 | 期望 | 实测 |
|---|---|---|---|
| T1 | 真实配置，数据已一致 | nothing to repair | ✅ 三条 `0 row(s)` + `nothing to repair`，exit 0 |
| T2 | `paramDbType=mysql` | skipped | ✅ `skipped (PostgreSQL only)`，exit 0 |
| T3 | 目标库中无相关表 | skipped | ✅ `table(s) not created yet (...) - skipped`，exit 0 |
| T4 | 数据库不可达 | 告警 + skipped | ✅ `WARNING: cannot connect ... - skipped`，exit 0 |
| T5 | 隔离 schema 含 2 行不一致 | 修复 2 行 | ✅ `UserStory 1 + Activity 1 + Ticket 0` = `2 row(s) realigned` |
| T6 | 紧接 T5 再次执行 | 幂等 0 行 | ✅ `nothing to repair` |

**③ 上游反馈（建议，未执行）**

向 ProjeQtOr 上游反馈：`db/projeqtor_V13.0.1.sql` 使用 MySQL 专有多表 `UPDATE`，
且该版本未提供 PG 补丁（对比 13.0.0 有 `projeqtor_V13.0.0.psql.sql`）。

> **生效前提**：自愈逻辑位于镜像内，需等 CI 用新代码重建镜像（push `main` 即触发）后才会进入运行实例；
> 且受 [P3](#p3--可变版本-tag--ifnotpresent导致镜像更新不生效) 影响，既有部署不会自动拉到新镜像。

> 补充：该缺口的破坏面是「PG 转换器未覆盖的语法」这一类，而非 PG 整体不可用。
> 实测中最新两个版本的脚本在 PG 上零错误。另一侧的事实是：MySQL 路径下
> `formatForDbType()` 对 `mysql` 直接原样返回（`db/maintenanceFunctions.php:323`），
> 因此上述 3 条语句在 MySQL 上不会失败——这是「无需翻译」而非「MySQL 支持更好」。
> 上游同样为 MySQL 提供专属补丁（如 `db/maintenance.php:1058` 的 `V8.6.0.mysql`、
> `:1176` 的 `V9.1.0.mysql`），双轨结构两边都存在。

---

### P2 · 缺少 User-Agent 时请求被中断

**严重度**：低（仅影响无头客户端）
**归属**：上游 ProjeQtOr 缺陷（PHP 8 兼容性）
**状态**：🟡 已定位

#### 现象

用 `curl` 模拟登录时认证**已通过**（日志出现 `NEW CONNECTED USER 'admin'`），
但响应体被替换为通用错误页，登录流程随即中断：

```
2026-10-14 11:43:50.892 ===== TRACE ===== [1] NEW CONNECTED USER 'admin'
2026-10-14 11:43:50.893 ***** ERROR ***** [V13.1.1] [1] on file '/var/www/html/model/Audit.php' at line (160)
2026-10-14 11:43:50.893 ***** ERROR ***** [V13.1.1] [1] cause = Undefined array key "HTTP_USER_AGENT"
```

#### 证据与根因

`model/Audit.php:160` 直接读取 `$_SERVER['HTTP_USER_AGENT']`，未做存在性判断：

```php
$audit->userAgent = $_SERVER ['HTTP_USER_AGENT'];
```

PHP 8 将其视为 warning，而应用启用的错误捕获会把该 warning 升级为致命错误，导致请求中断。

#### 影响

* **浏览器不受影响**：浏览器始终发送 `User-Agent`。
* **本 Chart 探针不受影响**：`docker/healthz.php` 刻意不加载框架，因此不经过 `Audit`。
* **受影响对象**：脚本化登录 / 合成监控 / 压测等无头客户端。补齐浏览器请求头即可（验证通过）。

#### 建议处置

无需修改 Chart。若后续要做合成登录检查或 E2E 用例，请务必携带浏览器请求头；
如需根治，可向上游反馈 `Audit.php:160` 增加存在性判断。

---

### P3 · 可变版本 tag + `IfNotPresent`，导致镜像更新不生效

**严重度**：中（不影响实例运行，但会让「重建镜像」的操作看起来无效）
**归属**：本仓库交付设计（CI 标签策略 × Chart 拉取策略相互作用）
**状态**：🟢 已缓解（本实例已改为固定不可变 tag 部署；chart/CI 的默认行为未变，见「处置记录」）

#### 现象

CI 对 `push` 到 `main` 的事件**不做**「tag 已存在则跳过」判断，即每次仓库（含 Dockerfile）变更都会
重建并推送同名版本 tag（如 `13.1.1`），版本 tag 实质是**可变**的；而 Chart 默认
`image.pullPolicy: IfNotPresent`。当节点已缓存同名 tag 的镜像时，即使远端已被新内容覆盖，
Pod 重建也不会拉取新镜像 —— 镜像变更静默不生效。

**本实例即为此情形**：Dockerfile / entrypoint 已加入 P1 自愈逻辑，但部署中的 `13.1.1`
仍是加入该逻辑之前的构建。

#### 证据

* `.github/workflows/docker-image.yml`：去重分支仅覆盖 `schedule|workflow_dispatch`
  （`case "$GITHUB_EVENT_NAME" in schedule|workflow_dispatch)`），push 事件必然构建并推送；
  标签规则为 `type=raw,value=<版本号>`、`latest`（仅上游最新版）、`type=sha,format=short,prefix=sha-`。
* `charts/projeqtor/values.yaml`：`image.pullPolicy: IfNotPresent`。

#### 影响

* 既有部署执行 `helm upgrade` 或 Pod 重建后，仍运行旧镜像内容（本次的自愈逻辑就是这种情况）。
* `sha-<7位>` 标签每次不同且可追溯到 commit，但当前未作为部署依据使用。

#### 建议处置（三选一）

1. 部署时固定不可变标签：`--set image.tag=sha-<commit>`（每次升级显式变更 tag）。
2. 改用 `--set image.pullPolicy=Always`（代价：每次启动回源校验，弱网/离线环境不利）。
3. CI 侧：对已发布的版本号 tag 不覆盖（push 事件同样做存在性判断，只推 `sha-` 标签）。

#### 处置记录（2026-10-14，采用方案 1）

* 本实例改为固定不可变 tag 部署：`image.tag: sha-8a050b3`（对应 commit `8a050b3`），
  经 `helm upgrade --atomic` 完成滚动更新。证据：Pod `imageID` 由
  `sha256:176067cb…` 变为 `sha256:4b58f471…`（证明确实拉取了新镜像）；启动日志出现
  4 行 `[projeqtor-pg-repair]` 输出；容器内 `PQ_PG_REPAIR=true`；`healthz=200`、`login.php=200`。
* 该实例的部署 values 存放在 k3s 主机上（仓库之外，不入库）。
* **仍未改变的部分**：chart 默认依然是 `pullPolicy: IfNotPresent` + `image.tag` 取
  `appVersion`，CI 也仍会覆盖同名版本 tag。所以「固定 sha tag」目前是本实例的**部署约定**，
  而不是 chart 的默认行为 —— 新部署若沿用例子里带版本号的 tag，仍会踩到本问题。

---

### P4 · PHP 会话不在 PVC 上（多副本不共享、Pod 重建掉登录）

**严重度**：中（单副本下表现为「升级即全员掉登录」；多副本下 chart 声明的
RWX 共享能力实际不成立）
**归属**：本仓库交付侧（镜像 / 入口脚本 / 文档）
**状态**：🟢 已修复（镜像侧 + 入口脚本，已在本地基镜像实测验证；**待重建镜像并滚动更新，
以在 k3s 上确认 Pod 重建后登录态保留**）

#### 现象

* Pod 重建（含 `helm upgrade` 滚动更新）后，所有已登录用户的会话丢失，需要重新登录。
* 多副本部署时，附件等经 `ReadWriteMany` 共享正常，但登录会在请求落到另一个 Pod
  时失效 —— 即「用 RWX 存储 `files/` 即可支持多副本」的既有说法并不成立。

#### 证据（基镜像 `php:8.1-apache-bookworm` 实测）

```
session.save_path=[]                      # 空值 → PHP 回落到 sys_get_temp_dir()
session.save_handler=files
Loaded Configuration File: (none)          # 官方 php 镜像不加载任何 php.ini
/var/lib/php/sessions: No such file or directory
/tmp: drwxrwxrwt root root                # 可写，但属于容器可写层
```

#### 根因

镜像与本仓库的 ini 都未设置 `session.save_path`，PHP 于是把会话文件写入
`/tmp` —— 那是**容器可写层**（节点上的 overlayfs 上层目录），既不在 PVC 上，
也不在节点本地 PV 上；每个 Pod 各写各的，Pod 一重建即消失。本仓库 4 处文档
（`values.yaml`、chart README、根 README）曾声明「PHP session 在 Pod 间共享」，
与实现不符。

#### 修复

* `docker/Dockerfile`：`zz-projeqtor.ini` 增加
  `session.save_path=/var/www/html/files/session`；把 `files/session` 加入镜像内
  预创建的可写目录（随后 `chown -R www-data:www-data`）。
* `docker/docker-entrypoint.sh`：运行时创建 `files/session`（PVC 挂载会遮住镜像内
  的目录），并写入 `.htaccess`（`Require all denied`）。
* 文档：`values.yaml`、chart README、根 README 的会话说明改为与实现一致。

#### 修复验证（本地基镜像实测 `php:8.1-apache-bookworm`）

按修复后的配置（ini + 目录 + `.htaccess`）实测：`session.save_path` 生效、会话真实写入
该目录、HTTP 侧不可达。对照矩阵：

| 场景 | 直接请求会话文件 | 请求目录（无索引文件） |
|---|---|---|
| 无 `.htaccess` | **200**（知道文件名即可下载 → 会话劫持向量） | 403 |
| 有 `.htaccess` | 403 | 403 |

* 目录列表 403 来自基镜像 `docker-php.conf` 的 `Options -Indexes`（Apache 日志：
  `server-generated directory index forbidden by Options directive`），即**无法枚举**
  会话文件名 —— 这也是加 `.htaccess` 仍然必要的原因：仅靠目录保护挡不住「已知文件名」。
* `.htaccess` 生效由 Apache 日志确认：`client denied by server configuration:
  /var/www/html/files/session/sess_…`（同时说明 `AllowOverride All` 有效）。
* `.htaccess` 存在时 PHP 仍能正常读写会话（纯文件系统操作，不经 HTTP）。
* 附带发现：该目录必须由以 `www-data` 运行的入口脚本创建（镜像 `USER www-data`）。
  若目录为 root 拥有且 0755，会出现
  `session_start(): open(...) failed: Permission denied`，登录直接不可用。

#### 残留注意

* PHP 文件会话使用**建议性锁**，NFS 上的并发写保证弱于本地文件系统。本修复解决的是
  「会话丢失」与「跨 Pod 不共享」，**不**改变「多 Pod 并发写同一会话文件」的锁语义；
  严格的多副本场景建议改用数据库会话或会话粘性。
* 会话文件位于文档根内（`files/session/`）。基镜像的 `docker-php.conf` 已对
  `/var/www/` 设 `Options -Indexes`（目录无法枚举），叠加 `.htaccess` 后 HTTP 侧
  不可达；会话文件只由 PHP 通过文件系统读写。
* 升级到本修复的镜像会让现有登录态失效一次（会话路径变更），属预期。

---

### P5 · files 目录可被 HTTP 直读（日志未认证可读、附件绕过下载令牌）

**严重度**：中高（日志文件名可预测 → 未认证即可读取；附件被绕过授权模型）
**归属**：本仓库交付侧（镜像内缺少 Apache 访问限制）
**状态**：🟢 已修复（镜像层 Apache 配置；**待重建镜像生效**）

#### 现象

`files/` 位于文档根内（`/var/www/html/files`），镜像未对它做任何访问限制，只有基镜像
自带的 `Options -Indexes`（挡住目录列举）。基镜像实测：

| 请求 | 结果 |
|---|---|
| `GET /files/logs/projeqtor_<date>.log` | **200 + 日志全文**（文件名可预测 → 未认证可读） |
| `GET /files/attach/<哈希名>` | 200，直取附件 |
| `GET /files/config/parameters.php` | 200 但 0 字节（交给 PHP 执行，不泄露） |
| `GET /files/config/parameters.php~`（或 `.bak`） | **200 + 明文数据库口令**（非 `.php` 后缀按静态文件下发） |
| `GET /files/logs/` | 403（`Options -Indexes`） |

#### 根因

* 附件在 UI 中一律经 `../tool/download.php?class=Attachment&id=...&token=...` 提供
  （`view/objectDetail.php:5398`、`view/galleryShow.php:126`），即**本应有鉴权与令牌校验**；
  同一份文件又以静态路径暴露，等于绕过该模型（利用门槛是先知道哈希文件名，目录无法枚举）。
* 日志文件名是 `projeqtor_<YYYYMMDD>.log`（`tool/config.php:331`），**可预测**，
  因此未认证即可读取。
* 上游 ProjeQtOr 的 `files/config/` 只带一个 `index.php`，没有 `.htaccess` 防护。

#### 修复

镜像内新增 `/etc/apache2/conf-available/zz-projeqtor-files.conf`（并 `a2enconf`），
对 `attach`、`config`、`cron`、`logs`、`report`、`import`、`session` 设 `Require all denied`；
`images` 与 `thumbs` 保持可达。

保留这两个目录是**源码核实**的结果：`files/images/` 被 HTML 直链引用
（`model/InputMailboxTicket.php:786` → `src="../files/images/<id>"`），`files/thumbs/`
由 `model/Affectable.php:225` 的 `getThumbUrl()` 拼成 URL 返回；其余目录只以文件系统
路径出现（`tool/config.php:291`、`model/persistence/SqlElement.php:2845` 等），无 URL 引用。

#### 残留注意

* 需重建镜像才能生效；生效后应实测「附件下载、头像/缩略图显示、日志查看页」三项仍正常。
* `files/session/` 同时受入口脚本写入的 `.htaccess`（见 P4）与本次 conf 覆盖，属有意冗余。
* 该 conf 依赖 `Require all denied` 的**更具体路径优先**规则生效；与之对照的
  `/var/www/` 段（`apache2.conf`、`docker-php.conf`）授予访问，该行为已实测确认。

---

### P6 · 数据库未初始化时入口脚本生成的 `parameters.php` 不完整，全站 0 字节白屏

**严重度**：高（应用完全不可用，且无法自愈）
**归属**：本仓库交付侧（`docker/docker-entrypoint.sh` 生成的参数文件缺少框架启动必需项）
**状态**：🟢 已修复（入口脚本补全 + 可原地修复既有部署；本实例已实测恢复）

#### 现象

数据库尚未初始化的部署，访问**任何**加载框架的入口都返回 `HTTP 200` + `Content-Length: 0`：
无 HTML、无 PHP 报错、`files/logs/` 也始终为空。很容易被误判为镜像 / Ingress / 探针问题。

| 请求 | 结果 |
|---|---|
| `GET /`、`GET /index.php` | 200，**0 字节** |
| `GET /view/index.php`、`GET /view/login.php`、`GET /tool/*.php` | 200，**0 字节** |
| `GET /healthz.php`（不加载框架） | 200，正常 |

响应头里带 `Set-Cookie: PHPSESSID`，说明 `session_start()` 已经执行过。

#### 根因

`tool/projeqtor.php` 每次请求都会调用 `scriptLog()`，它进入 `logTracing()`：

```php
$logFile=Parameter::getGlobalParameter('logFile');
if (!$logFile or $logFile=='' or $level==9) {
    exit();                 // tool/projeqtor.php:3248-3251
}
```

`Parameter::getGlobalParameter('logFile')` 的取值顺序是"先看参数文件定义的全局变量，再查数据库"
（`model/Parameter.php:1631-1675`）。而：

* 入口脚本生成的 `parameters.php` 只写了 7 个 `$paramDb*`（`docker/docker-entrypoint.sh`）；
* 数据库尚未初始化，没有 `parameter` 表可查 —— 且该查询被 `enableCatchErrors()` /
  `enableSilentErrors()` **静默吞掉**。

于是 `logFile` 恒为空 → `logTracing()` 直接 `exit()`：**输出为空、无 PHP 错误、不写日志**，
与观测到的现象完全吻合。

**为什么空库会走到这一步**：入口脚本会预先生成 `tool/parametersLocation.php`，
使 `tool/projeqtor.php:94` 走「已安装」分支，从而**跳过** `tool/projeqtor.php:110-115`
的配置向导分支（向导在 `scriptLog()` 之前，所以向导路径不受影响），直达 `scriptLog()`。

**这构成死锁**：应用永远无法启动 → 永远到不了登录页 → 也就永远无法通过
「首次以 `admin`/`admin` 登录触发 `db/maintenance.php`」完成建库。

> 对照：ProjeQtOr 自带的 web 向导会把**全部**参数写入 `parameters.php`
> （`tool/configCheck.php:213-217`），其中 `logFile`、`logLevel` 都是必填项
> （`tool/config.php:331,338`）。入口脚本手写的参数文件漏掉了它们 —— 这是与上游契约的偏差。

#### 证据（实测 2026-10-14，实例 `smrd/projeqtor-*`）

同一引导链的四组对照实验：

| 变体 | 条件 | 结果 |
|---|---|---|
| A | 置 `$noScriptLog=true`（跳过 `scriptLog`） | **存活**，并打印 `logFile='' logLevel=''` |
| B | 预置 `$logFile` | **存活** |
| C | 原样 | 在 `projeqtor.php` 内 `exit()`，`[SHUTDOWN] clean`（无任何 PHP 错误） |
| D | 预置 `$logFile`+`$logLevel` 后跑完整 `index.php` | 200 / 3810 字节，输出正常启动页 |

#### 修复

* `docker/docker-entrypoint.sh` 生成的 `parameters.php` 补齐两个框架启动必需项
  （取值与上游向导默认值一致），并支持 `PQ_LOG_FILE` / `PQ_LOG_LEVEL` 覆盖：
  ```php
  $logFile = '../files/logs/projeqtor_${date}.log';
  $logLevel = '2';
  ```
* **附带对既有部署的原地修复**：参数文件从不被覆盖，因此老部署升级后仍是残缺文件。
  入口脚本现在会检查这两个键，缺失则**追加**（幂等；文件含 `?>` 时只告警不改，
  避免把代码追加到 PHP 块之外）。

#### 验证

| 验证项 | 方法 | 结果 |
|---|---|---|
| 入口脚本语法 | `bash -n` | 通过 |
| 新生成 / 修复既有文件 / 幂等 / 保留自定义值 / `?>` 保护 / 环境变量覆盖 / 未设 `PQ_DB_HOST` 不生成 | 本地 7 场景 19 条断言 | **19/19 通过** |
| 真实镜像行为 | 用交付镜像起一次性 Pod（不挂 PVC、不碰生产对象）跑同一脚本 | **14/14 通过**，含反向对照（抽掉 `logFile` 立即复现静默退出，修复脚本再加回即恢复） |
| 生产端到端 | 在本实例 Pod 内执行新的入口脚本逻辑 | `/` 由 0 字节 → 3812 字节；`files/logs/projeqtor_20261014.log` 开始写入（此前恒为空） |
| 建库 | 触发 `db/maintenance.php` | `parameter` 表建立，**`tables=357`**，**`dbVersion=V13.1.1`**，`files/cron/MIGRATION` 已自动清理 |
| 真实登录 | AES 全链路 `admin`/`admin` | `Login accepted` / `validated=OK`；`/view/main.php` 返回 741 304 字节完整界面（`menuBar` 存在） |

> 注意事项：热修参数文件后，受 opcache `revalidate_freq` 窗口影响，页面可能仍为 0 字节约数秒。
> 镜像重建后由入口脚本在 Apache 启动**之前**写文件，不存在该窗口。

#### 影响与操作

* 受影响：**所有数据库尚未初始化的实例**（即全新部署最常见的首次启动）。
* 首次启动后仍需一次人工步骤：登录 `admin`/`admin` 即会自动建库（上游既有设计，
  `tool/loginCheck.php:56-62`），耗时较长属正常现象。
* 该修复位于镜像内的入口脚本，需要**重建镜像**才能交付，见
  [P3](#p3--可变版本-tag--ifnotpresent导致镜像更新不生效)。

---

### N1 · AES 加密类脱离框架不可用

在容器内编写独立脚本复现登录流程时，`AesCtr::encrypt()` 报
`Call to undefined function pq_ord()`。

**原因**：`external/phpAES/aesctr.class.php` 依赖 `pq_ord()` 与 `pq_substr()`
（定义在 `tool/projeqtor_string.php`）。独立脚本需自行补齐这两个函数，或先加载框架引导文件。

### N2 · session 激活后无法再改 session id

在容器内脚本中先 `session_id(...)` + `session_start()`，再 `require tool/projeqtor.php`
（其内部再次 `session_start()`）会报：

```
session_id(): Session ID cannot be changed when a session is active
```

**规避**：不要手动启动 session；由框架引导文件负责启动，盐值经 `getSessionValue('sessionSalt')` 获取。

### N3 · 用户表名为 `resource` 而非 `user`

ProjeQtOr 的用户（含 `admin`）存于 **`resource`** 表，数据库中**不存在** `user` 表；
直接 `select ... from "user"` 会报 `relation "user" does not exist`。

`admin` 记录形态（已验证）：`id=1, idProfile=1(ADM), idle=0, locked=0, crypto=md5, salt=''`，
且 `password = md5('admin') = <已省略>` —— 说明「salt 为空 + crypto=md5」
是默认安装的正常形态，登录是**真实口令校验通过**，而非绕过。

### N4 · 数据库不在 Chart 内 + 自建 Secret 的双键语义

**Chart 不含数据库部署与数据库镜像**。`helm template` 的渲染结果只有 ConfigMap /
Deployment / Service / Ingress / ServiceAccount / 应用侧 PVC（外加可选的 Secret 与
CronJob）；模板中的 `image:` 只有两处 —— 应用镜像（`deployment.yaml`）与 CronJob 保活
用的 `alpine:3.20`（`cronjob.yaml`），**没有**任何 PG/MySQL 镜像。本集群的
`projeqtor-postgres`（镜像来自私有镜像仓库的 `postgres:17.10-bookworm`，
PVC `projeqtor-postgres-data`）是独立 `kubectl apply` 创建的：无 Helm 标签、无
`ownerReferences`，不属于 release。

`values.yaml` 默认 `env.PQ_DB_TYPE: mysql` + `env.PQ_DB_HOST: projeqtor-mysql` 只是命名
约定，Chart 不会创建它 —— 数据库未就绪就部署会连接失败，而 Pod 仍会 Ready，因为
`docker/healthz.php` 刻意不加载框架、不依赖数据库。

**自建 Secret 时的双键语义**（以 PostgreSQL 为例）：

| 键 | 谁读 | 生效时机 |
|---|---|---|
| `POSTGRES_PASSWORD` | 数据库容器的 `POSTGRES_PASSWORD`（`secretKeyRef`） | **仅首次 initdb**；既有 PGDATA 之后不再读它 |
| `PQ_DB_PASSWORD` | 应用容器（`envFrom` 整个 Secret → `parameters.php` 的 `$paramDbPassword`） | **每次启动都读** |

* 两键**不必强制相等**，但建议保持一致；唯一硬约束是 `PQ_DB_PASSWORD` 必须等于数据库里
  该角色的当前口令（本实例两键同值，已用 sha256 校验）。
* **只改 `POSTGRES_PASSWORD` 等于没改**：应用不读它，它只是被 `envFrom` 顺带注入成一个
  无用环境变量；应用连接参数只由 `PQ_DB_PASSWORD` 决定。
* **两键不一致 + 数据库 PVC 重建**（PGDATA 为空）→ 容器用陈旧值初始化 → 应用认证失败。
* 改用 Chart 托管口令时（`database.password` 且 `existingSecret` 留空），Chart 只生成
  `PQ_DB_PASSWORD` 一个键，不存在双键问题。
* `stringData` 只合并、不删除 `data` 中的旧键（已实测，见下方操作说明）。

完整的操作步骤（轮换顺序、`ALTER USER`、`stringData` 删键的显式 patch）见
`charts/projeqtor/README.md` 的「数据库与 Secret（重要）」章节。

---

## 4. 登录验证方法（可复现）

ProjeQtOr 登录不是明文 POST，而是：

1. `GET /view/login.php` → 建立 PHP session；页面内联 `var aesLoginHash="<md5(session_id)>"`
   （`view/login.php:134`）与 `var aesKeyLength`（`view/login.php:137`）。
2. `GET /tool/getHash.php?username=<AesCtr::encrypt(用户名, md5(session_id), aesKeyLength)>`
   → 返回 `crypto;userSalt;sessionSalt`，同时把 `sessionSalt` 写入 session
   （`tool/getHash.php:36,49-55`）。
3. 客户端按 `view/js/projeqtor.js:5458` 的 `cryptData()` 计算：
   * `login` = `AesCtr::encrypt(用户名, sessionSalt, aesKeyLength)`
   * `password` = `md5(md5(密码 + userSalt) + sessionSalt)`（`crypto=md5` 时；
     `crypto=sha256` 则改用 sha256 双层哈希；其他则 `AesCtr::encrypt(密码, sessionSalt, ...)`）
4. `POST /tool/loginCheck.php`（字段 `login`、`password`），服务端用
   `getSessionValue('sessionSalt')` 解密校验（`tool/loginCheck.php:41,52`；
   `model/UserMain.php:1590-1607`）。成功响应含 `validated ... OK`。

**关键注意点**：全程必须携带 `User-Agent`（见 [P2](#p2--缺少-user-agent-时请求被中断)），
且四步必须共用同一个 cookie jar，否则 `sessionSalt` 与 session 不一致会导致校验失败。

本次实测结果：

```
STEP1 ok: login page http=200  md5(session_id)=08cda77d...  aesKeyLength=128
STEP2 ok: getHash http=200  crypto=md5  userSalt=  sessionSalt=92db1dc3...
STEP4: POST /tool/loginCheck.php http=200
RESULT: LOGIN SUCCESS (admin/admin)
```

---

## 5. 环境与操作事实（供后续排查参考）

* **集群访问**：开发容器内**没有** kubectl/k3s，需经 `ssh <k3s 主机>`（`<k3s 节点 IP>`）执行，
  并设置 `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`。
* **关键标签**：应用 Pod 用 `app.kubernetes.io/name=projeqtor`（容器名 `projeqtor`，监听 `127.0.0.1:8080`）；
  数据库 Pod 用 `app=projeqtor-postgres`。
* **首次安装触发方式**（本行曾描述有误，已更正）：entrypoint 生成
  `files/config/parameters.php` 与 `tool/parametersLocation.php`
  （`docker/docker-entrypoint.sh`），**不**主动触发安装。安装由**首次以 `admin`/`admin`
  登录**触发（`tool/loginCheck.php:56-62` → `include "../db/maintenance.php"`），
  遍历 182 个 `db/projeqtor_V*.sql`、建成 357 张表，耗时较长属正常现象。
  ⚠️ 注意：登录**之前**必须先能打开登录页；数据库未初始化时若参数文件残缺会直接白屏，
  见 [P6](#p6--数据库未初始化时入口脚本生成的-parametersphp-不完整全站-0-字节白屏)。
* **白屏排查（200 + 0 字节）**：先看是否 [P6](#p6--数据库未初始化时入口脚本生成的-parametersphp-不完整全站-0-字节白屏)；
  判据是响应头有 `Set-Cookie: PHPSESSID`（说明已过 `session_start()`）且 `files/logs/` 为空。
  `Parameter::getGlobalParameter('logFile')` 为空时 `logTracing()` 会静默 `exit()`，
  此时 `display_errors` 不会产出任何信息，**不要**据此判断为镜像或 Ingress 故障。
* **查询数据库版本**：`select parametercode, parametervalue from parameter where parametercode='dbVersion'` → `V13.1.1`。
* **日志位置**：容器内 `/var/www/html/files/logs/projeqtor_<YYYYMMDD>.log`；
  升级错误用 `grep -E "WITH [0-9]+ ERROR|ERROR \*+"` 定位。
* **查看自愈脚本运行情况**：`kubectl -n projeqtor logs <pod> -c projeqtor | grep projeqtor-pg-repair`
  （正常启动时打印三条 `N row(s) realigned` 与最终结论）。
* **确认镜像是否真的更新**：比对 `kubectl -n projeqtor get pod -o jsonpath='{.status.containerStatuses[0].imageID}'`
  与 ghcr 上该 tag 的 digest；注意 [P3](#p3--可变版本-tag--ifnotpresent导致镜像更新不生效)。
* **Chart 与数据库的边界**：Chart 不含任何数据库工作负载与镜像（渲染证据见
  [N4](#n4--数据库不在-chart-内--自建-secret-的双键语义)）；本集群数据库为独立
  Deployment `projeqtor-postgres`（PVC `projeqtor-postgres-data`），不属于 Helm release。
* **Secret 键语义与口令轮换**：见 [N4](#n4--数据库不在-chart-内--自建-secret-的双键语义)
  与 `charts/projeqtor/README.md` 的「数据库与 Secret（重要）」章节；当前实例
  `POSTGRES_PASSWORD` 与 `PQ_DB_PASSWORD` 同值（sha256 已校验）。
* **k3s 主机上的交付物**（仓库之外，均为本机运维文件，不入库）：部署 values、
  Secret 导出（含 `stringData` 明文版）、升级用 chart 副本、Ingress TLS 证书文件。

---

## 6. 待决事项

| # | 事项 | 关联 | 状态 |
|---|---|---|---|
| 1 | PG 实例上回填 `subtask.idProject` | P1 | ✅ 已完成（2026-10-14；本实例无数据，已在隔离 schema 验证语义） |
| 2 | 镜像 / entrypoint 侧幂等自愈并随 Chart 交付 | P1 | ✅ 已完成（脚本 + 接线 + 开关 + 文档；6 用例验证通过） |
| 3 | 是否向 ProjeQtOr 上游反馈 `V13.0.1` 脚本方言与缺失 PG 补丁 | P1 | 待决定 |
| 4 | 是否反馈 `Audit.php:160` 缺少 `HTTP_USER_AGENT` 判断 | P2 | 待决定 |
| 5 | 是否用 MySQL/MariaDB 做一次对照实测（同一套 Chart、同样全新安装，检查 `WITH N ERRORS`） | P1 | 待决定 |
| 6 | 让自愈逻辑真正生效：等 CI 用新代码重建镜像并完成滚动更新（受 P3 影响） | P1 / P3 | ✅ 已完成（2026-10-14；以 `sha-8a050b3` 滚动更新，启动日志出现 4 行 `[projeqtor-pg-repair]`、`PQ_PG_REPAIR=true`） |
| 7 | 选择 P3 的处置方式（不可变 tag / `Always` / CI 不覆盖版本 tag） | P3 | ✅ 已完成（2026-10-14；采用方案 1 固定不可变 tag，见 P3「处置记录」） |
| 8 | 重建镜像并在 k3s 上验证 P4 修复（Pod 重建后登录态保留；多副本下会话跨 Pod 共享） | P4 | 待执行（代码与文档已改、本地基镜像实测通过；需 CI 构建新镜像并更新部署 tag） |
| 9 | 重建镜像并验证 P5 加固（附件下载、头像/缩略图、日志查看页仍正常；`files/logs` 等目录返回 403） | P5 | 待执行（同上，可与 P4 同一次镜像重建与升级一并验证） |
| 10 | 在非生产环境验证 `seccompProfile: RuntimeDefault` 下 Apache/PHP 正常（chart 默认已启用） | 安全加固 | 待执行（仅有本地旁证：Docker 默认 seccomp 下一切正常） |
| 11 | 重建镜像并验证 P6：全新空库部署首次启动不再白屏；既有部署升级后参数文件被原地修复 | P6 | 待执行（代码与文档已改；本地 19/19、真实镜像一次性 Pod 14/14、生产实例端到端手工验证均已通过） |

---

## 7. 附：修订记录

| 日期 | 变更 |
|---|---|
| 2026-10-14 | 首次建立：记录 P1、P2 与 N1–N3，附部署与登录验证基线 |
| 2026-10-14 | 执行 P1 处置：本实例数据回填（0 行）+ 新增幂等启动自愈脚本 `PQ_PG_REPAIR`（6 用例验证通过）；新增 P3（可变版本 tag + `IfNotPresent`）；修复 `configmap.yaml` 仅渲染固定 env 键导致新增键静默失效的问题；补全验证矩阵与生效前提 |
| 2026-10-14 | 新增 [N4](#n4--数据库不在-chart-内--自建-secret-的双键语义)：Chart 不含数据库部署与镜像（附渲染证据）、自建 Secret 的双键语义与轮换约束；chart README 增加「数据库与 Secret（重要）」章节；根 README 增加数据库归属提示；环境事实补充 k3s 主机交付物清单 |
| 2026-10-14 | CI 增加 `paths` 过滤（仅 `docker/**`、`.dockerignore`、工作流自身触发），并以纯文档提交实测确认不再触发构建（该提交无 Actions 运行，对照的工作流变更提交触发 run #5 构建成功）；P3 处置：本实例改用固定不可变 tag `sha-8a050b3` 滚动更新并验证生效，状态 🟡 → 🟢，摘要表 / 总体结论 / 待决事项 / 验证基线同步更新 |
| 2026-10-14 | 新增 [P4](#p4--php-会话不在-pvc-上多副本不共享pod-重建掉登录)：实测基镜像确认 `session.save_path` 为空、会话落在容器 `/tmp`（不在 PVC）；修复为镜像 ini 指向 `files/session` + 入口脚本创建该目录并写入 `.htaccess`；修正 `values.yaml` / chart README / 根 README 共 4 处错误的「会话在 Pod 间共享」说法；摘要表、总体结论、待决事项新增相应条目 |
| 2026-10-14 | 安全加固：新增 [P5](#p5--files-目录可被-http-直读日志未认证可读附件绕过下载令牌) 并修复（镜像内 Apache 对 `attach/config/cron/logs/report/import/session` 设 `Require all denied`，保留 `images`、`thumbs`）；工作流补顶层最小权限（`contents: read` + detect job 的 `packages: read`）；关闭应用 Pod 与 CronJob 的 `automountServiceAccountToken`；`podSecurityContext` 增加 `seccompProfile: RuntimeDefault`；chart README 增加「口令会落到哪些地方（安全提示）」；`.gitignore` 增加根目录 `/*values*.yaml`、`/*secret*.yaml` 防误提交；Chart 版本 `0.1.0` → `0.2.0` |
| 2026-10-14 | 新增 [P6](#p6--数据库未初始化时入口脚本生成的-parametersphp-不完整全站-0-字节白屏)（`smrd` 实例白屏根因）并修复：`docker/docker-entrypoint.sh` 生成的 `parameters.php` 补齐上游向导必填的 `$logFile` / `$logLevel`（支持 `PQ_LOG_FILE` / `PQ_LOG_LEVEL` 覆盖），并新增对既有残缺参数文件的幂等原地修复；更正第 5 节「首次安装触发方式」的错误描述（实为 `admin`/`admin` 登录触发 `db/maintenance.php`）并补充「200 + 0 字节」白屏判据；chart README / NOTES 补充首次启动步骤与日志参数；Chart 版本 `0.2.0` → `0.2.1` |
