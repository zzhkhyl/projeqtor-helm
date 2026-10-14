# 已知问题与验证记录

本文件记录 ProjeQtOr 容器化交付方案在真机验证过程中识别出的全部问题、证据与处置状态，
用于后续查阅与跟踪。新增问题请沿用本文编号规则（`P` = 产品/上游缺陷，`N` = 排查注意事项）。

| 项目 | 基线 |
|---|---|
| 镜像 | `ghcr.io/zzhkhyl/projeqtor:13.1.1`（多架构 amd64/arm64） |
| Chart | `projeqtor-0.1.0`（appVersion `13.1.1`） |
| 验证环境 | k3s 单节点 `<k3s 节点 IP>`，PostgreSQL 17.10（集群内 `projeqtor-postgres`） |
| 命名空间 | `projeqtor` |
| 报告日期 | 2026-10-14 |

状态图例：🔴 未处理 · 🟡 已定位待处置 · 🟢 已验证无问题 · ⚪ 说明性记录

---

## 1. 摘要

| 编号 | 问题 | 类别 | 严重度 | 影响范围 | 状态 |
|---|---|---|---|---|---|
| [P1](#p1--postgresql-下-v1301-升级脚本执行失败) | PostgreSQL 下 `V13.0.1` 升级脚本 3 条语句执行失败（MySQL 专有多表 `UPDATE`） | 上游缺陷 | 中 | 任意 PG 实例从 ≤13.0.0 升级到 ≥13.0.1 | 🟡 |
| [P2](#p2--缺少-user-agent-时请求被中断) | 缺失 `User-Agent` 的请求被应用错误处理器中断 | 上游缺陷 | 低 | 无头 HTTP 客户端（不含浏览器、不含本 Chart 探针） | 🟡 |
| [N1](#n1--aes-加密类脱离框架不可用) | AES 加密类依赖 `pq_ord()` / `pq_substr()`，脱离框架无法直接调用 | 排查注意 | — | 仅影响外部调试脚本 | ⚪ |
| [N2](#n2--session-激活后无法再改-session-id) | `session_start()` 之后再调 `session_id()` 会报错 | 排查注意 | — | 仅影响外部调试脚本 | ⚪ |
| [N3](#n3--用户表名为-resource-而非-user) | 用户数据存于 `resource` 表，不存在 `user` 表 | 排查注意 | — | 仅影响 SQL 排查 | ⚪ |

**总体结论**：本次部署**功能正常**（全新安装、数据库升级、`admin/admin` 真实 HTTP 登录均验证通过），
未发现由本仓库的 Helm Chart 或镜像构建引入的缺陷。P1、P2 均来自上游 ProjeQtOr 自身，
且**均不阻断部署、启动与日常使用**。

---

## 2. 验证基线

以下项目已验证通过，作为问题判断的背景基线。

| 验证项 | 结果 |
|---|---|
| Helm release | `projeqtor` / ns `projeqtor` / revision 1 / `deployed` |
| Pod 状态 | `projeqtor-*` 与 `projeqtor-postgres-*` 均 `1/1 Running`，RESTARTS `0` |
| 镜像来源 | 确认为 CI 产出的 `ghcr.io/zzhkhyl/projeqtor:13.1.1`（非本地临时构建） |
| 数据库版本 | `parameter.dbVersion = V13.1.1`，与代码版本一致（故登录不会进入维护模式） |
| 数据库升级 | 全新安装 V0.0.0 → V13.1.1，遍历 182 个 `db/projeqtor_V*.sql` 版本脚本 / 357 张表，**唯一失败点为 P1** |
| 登录 | `admin/admin` 经真实 HTTP 全链路登录成功（见 [第 4 节](#4-登录验证方法可复现)） |
| 源码完整性 | 容器内 `tool/projeqtor.php`、`tool/getHash.php`、`tool/loginCheck.php`、`view/login.php`、`model/UserMain.php`、`model/Audit.php` 的 md5 与官方源码完全一致，无调试补丁残留 |
| 服务暴露 | Service `projeqtor:8080`（ClusterIP）；Ingress `<应用域名>`（traefik，80/443） |

---

## 3. 问题详情

### P1 · PostgreSQL 下 V13.0.1 升级脚本执行失败

**严重度**：中（数据一致性偏差；不阻断升级与使用）
**归属**：上游 ProjeQtOr 缺陷（脚本方言 + 补丁缺失）
**状态**：🟡 已定位，未修复

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
* **实际损失**：这三条语句本应把 `subtask.idProject` 与所属 UserStory / Activity / Ticket 的
  `idProject` 对齐。PG 实例上该回填**未执行**，`subtask.idProject` 可能残留与父对象不一致的值，
  属潜伏的数据一致性偏差。

#### 建议处置（三选一，尚未决定）

1. 在 PG 实例上手动执行一次等价语句（一次性数据修复）：

   ```sql
   UPDATE subtask s SET idProject = a.idProject FROM userstory a WHERE s.refType='UserStory' AND s.refId=a.id AND s.idProject <> a.idProject;
   UPDATE subtask s SET idProject = a.idProject FROM activity  a WHERE s.refType='Activity'  AND s.refId=a.id AND s.idProject <> a.idProject;
   UPDATE subtask s SET idProject = t.idProject FROM ticket    t WHERE s.refType='Ticket'    AND s.refId=t.id AND s.idProject <> t.idProject;
   ```

2. 在镜像 / entrypoint 侧增加一次幂等的启动自愈（可随 Chart 交付，属主动修改上游数据，需评估）。
3. 仅记录为已知上游缺陷，并向 ProjeQtOr 上游反馈（任何 PG 用户从 ≤13.0.0 升级都会命中）。

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
* **首次安装触发方式**：entrypoint 仅生成 `files/config/parameters.php` 与
  `tool/parametersLocation.php`（`docker/docker-entrypoint.sh:39-68`），**不**主动触发安装；
  安装 / 升级由首次 HTTP 请求（`index.php`）触发，耗时较长，属正常现象。
* **查询数据库版本**：`select parametercode, parametervalue from parameter where parametercode='dbVersion'` → `V13.1.1`。
* **日志位置**：容器内 `/var/www/html/files/logs/projeqtor_<YYYYMMDD>.log`；
  升级错误用 `grep -E "WITH [0-9]+ ERROR|ERROR \*+"` 定位。

---

## 6. 待决事项

| # | 事项 | 关联 | 状态 |
|---|---|---|---|
| 1 | PG 实例上是否手动回填 `subtask.idProject`（等价语句见 P1） | P1 | 待决定 |
| 2 | 是否在镜像 / entrypoint 侧增加幂等自愈逻辑并随 Chart 交付 | P1 | 待决定 |
| 3 | 是否向 ProjeQtOr 上游反馈 `V13.0.1` 脚本方言与缺失 PG 补丁 | P1 | 待决定 |
| 4 | 是否反馈 `Audit.php:160` 缺少 `HTTP_USER_AGENT` 判断 | P2 | 待决定 |
| 5 | 是否用 MySQL/MariaDB 做一次对照实测（同一套 Chart、同样全新安装，检查 `WITH N ERRORS`） | P1 | 待决定 |

---

## 7. 附：修订记录

| 日期 | 变更 |
|---|---|
| 2026-10-14 | 首次建立：记录 P1、P2 与 N1–N3，附部署与登录验证基线 |
