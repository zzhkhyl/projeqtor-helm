# ProjeQtOr Helm Chart

将 [ProjeQtOr](https://www.projeqtor.org) 协作项目管理软件部署到 Kubernetes。

镜像由本仓库的 GitHub Actions 工作流自动构建并推送到
`ghcr.io/zzhkhyl/projeqtor`，tag 与上游 ProjeQtOr 版本严格一致
（如 `13.1.1`），最新版附带 `latest`。

## 安装

```bash
# 添加本地 chart 目录（或先打包：helm package charts/projeqtor）
helm install projeqtor ./charts/projeqtor \
  --namespace projeqtor --create-namespace \
  --set env.PQ_DB_HOST=projeqtor-mysql.projeqtor.svc.cluster.local \
  --set env.PQ_DB_NAME=projeqtor \
  --set env.PQ_DB_USER=projeqtor \
  --set database.password='YourDbPassword'
```

或使用自定义 values 文件：

```bash
cp charts/projeqtor/values.yaml my-values.yaml
# 编辑 my-values.yaml ...
helm install projeqtor ./charts/projeqtor -f my-values.yaml -n projeqtor --create-namespace
```

安装完成后访问（默认 Ingress 关闭，使用端口转发）：

```bash
kubectl -n projeqtor port-forward svc/projeqtor 8080:8080
# 浏览器打开 http://localhost:8080，首次登录 admin / admin（请立即修改）
```

> **首次启动 = 建库（重要）**：Chart 不创建数据库结构。入口脚本只写入连接参数，
> **数据库的建表与初始化由首次以 `admin` / `admin` 登录触发**
> （`tool/loginCheck.php` → `db/maintenance.php`，遍历 182 个版本脚本、建成 357 张表），
> 整个过程耗时较长属正常现象。因此首次部署后请务必完成一次登录，否则库一直是空的。
>
> 相关背景（含「访问任何页面都是 200 + 0 字节白屏」这一历史缺陷）见
> [docs/known-issues.md](../../docs/known-issues.md) 的
> [P6](../../docs/known-issues.md#p6--数据库未初始化时入口脚本生成的-parametersphp-不完整全站-0-字节白屏)。

> **注意**：后台任务（cron）需要在管理界面手动启动一次
> （Administration → cron）。设置 `cronJob.enabled=true` 后，Pod 重启时
> CronJob 会自动将其重新拉起。

## 升级

```bash
# 升级到 chart 新版本（保留数据库配置：parameters.php 已存在于 PVC 中不会被覆盖）
helm upgrade projeqtor ./charts/projeqtor -f my-values.yaml -n projeqtor

# 升级镜像到新的 ProjeQtOr 版本
helm upgrade projeqtor ./charts/projeqtor -n projeqtor --reuse-values \
  --set image.tag=13.2.0
```

## 卸载

```bash
helm uninstall projeqtor -n projeqtor

# PVC 默认不会被删除，确认无需保留数据后手动清理：
kubectl -n projeqtor delete pvc projeqtor-files
```

## 参数

| 参数 | 说明 | 默认值 |
|---|---|---|
| `replicaCount` | Pod 副本数（>1 需要 RWX 存储） | `1` |
| `image.repository` | 镜像仓库 | `ghcr.io/zzhkhyl/projeqtor` |
| `image.tag` | 镜像 tag，留空取 `appVersion` | `""` |
| `image.pullPolicy` | 镜像拉取策略 | `IfNotPresent` |
| `imagePullSecrets` | 私有仓库拉取密钥 | `[]` |
| `nameOverride` / `fullnameOverride` | 名称覆盖 | `""` |
| `serviceAccount.create` | 创建专用 ServiceAccount | `true` |
| `serviceAccount.annotations` | SA 注解（云 IAM 等） | `{}` |
| `serviceAccount.name` | SA 名称 | `""` |
| `env.PQ_DB_TYPE` | 数据库类型：`mysql`/`pgsql` | `mysql` |
| `env.PQ_DB_HOST` | 数据库主机 | `projeqtor-mysql` |
| `env.PQ_DB_PORT` | 数据库端口 | `"3306"` |
| `env.PQ_DB_NAME` | 数据库名 | `projeqtor` |
| `env.PQ_DB_USER` | 数据库用户 | `projeqtor` |
| `env.TZ` | 容器时区 | `UTC` |
| `env.PQ_PG_REPAIR` | PostgreSQL 启动数据自愈（幂等、非致命，见 [docs/known-issues.md](../../docs/known-issues.md) P1） | `"true"` |
| `env.PQ_LOG_FILE` | 覆盖写入 `parameters.php` 的 `$logFile`（ProjeQtOr 启动必需项，见 P6） | `../files/logs/projeqtor_${date}.log` |
| `env.PQ_LOG_LEVEL` | 覆盖写入 `parameters.php` 的 `$logLevel`（同上） | `"2"` |
| `database.password` | 数据库密码（chart 托管 Secret） | `""` |
| `database.existingSecret` | 使用已有 Secret 名 | `""` |
| `database.existingSecretKey` | 已有 Secret 中的 key | `PQ_DB_PASSWORD` |
| `parameters.mount` | 挂载自定义 parameters.php | `false` |
| `parameters.content` | 自定义 parameters.php 内容 | `""` |
| `extraEnv` | 额外环境变量列表 | `[]` |
| `service.type` | Service 类型 | `ClusterIP` |
| `service.port` | Service 端口 | `8080` |
| `service.annotations` | Service 注解 | `{}` |
| `ingress.enabled` | 启用 Ingress | `false` |
| `ingress.className` | IngressClass | `""` |
| `ingress.annotations` | Ingress 注解（cert-manager 等） | `{}` |
| `ingress.hosts` | Ingress 主机与路径 | 见 values.yaml |
| `ingress.tls` | TLS 配置 | `[]` |
| `persistence.enabled` | 启用 PVC 持久化 `files/` | `true` |
| `persistence.existingClaim` | 使用已有 PVC | `""` |
| `persistence.storageClassName` | StorageClass（空=默认） | `""` |
| `persistence.accessModes` | 访问模式（多副本需 RWX） | `[ReadWriteMany]` |
| `persistence.size` | 存储容量 | `10Gi` |
| `resources` | 资源 requests/limits | 见 values.yaml |
| `podSecurityContext` | Pod 安全上下文 | `runAsNonRoot: true, runAsUser: 33` |
| `securityContext` | 容器安全上下文 | `drop ALL` |
| `probes.*` | 探针时间参数 | 见 values.yaml |
| `strategy` | 更新策略 | `RollingUpdate` |
| `nodeSelector` / `tolerations` / `affinity` | 调度约束 | `{}` / `[]` / `{}` |
| `podAnnotations` / `podLabels` | Pod 注解/标签 | `{}` |
| `cronJob.enabled` | 启用 cron 保活 CronJob | `false` |
| `cronJob.schedule` | CronJob 调度表达式 | `*/5 * * * *` |
| `cronJob.image` | CronJob 使用的镜像 | `alpine:3.20` |
| `cronJob.protocol` | 访问 Service 的协议 | `http` |

## 配置说明

- **数据库**：本 Chart **不含**任何数据库工作负载与数据库镜像（不会创建
  MySQL/PostgreSQL 实例、PVC 或镜像配置），需你自备并自行运维。Chart 只把
  `env.PQ_DB_*` 注入容器，由入口脚本写入 `files/config/parameters.php`（位于 PVC 上，
  重复启动/升级不会覆盖）。详见 [数据库与 Secret](#数据库与-secret重要)。
- **持久化**：`files/` 目录整体挂载 PVC，内含附件（`attach/`）、内嵌图片
  （`images/`）、缩略图（`thumbs/`）、报告（`report/`）、日志（`logs/`）、
  cron 标志（`cron/`）、**PHP 会话（`session/`）** 与生成的配置
  （`config/parameters.php`）。单副本可用 `ReadWriteOnce`；多副本必须使用
  `ReadWriteMany`（NFS、CephFS、Longhorn 等），因为附件与会话都在这个卷上。
  会话目录由入口脚本创建，并写入 `.htaccess` 拒绝 HTTP 访问（会话文件仅由
  PHP 通过文件系统读写）。注意 PHP 文件会话使用建议性锁，NFS 上的并发保证
  弱于本地文件系统，严格的多副本场景建议改用数据库会话或会话粘性。
- **安全**：容器以 `www-data`（uid 33）非 root 运行，Apache 监听 8080，
  已丢弃全部 Linux capabilities。

## 数据库与 Secret（重要）

### Chart 不包含数据库

渲染结果只有 ConfigMap、Deployment、Service、Ingress、ServiceAccount、应用侧 PVC，
以及（可选）口令 Secret 与 CronJob。**不存在** MySQL/PostgreSQL 的镜像、
StatefulSet、Deployment、Service 或 PVC —— 数据库的镜像、版本、副本、备份、
存储全部在 Chart 之外。

Chart 对数据库只做两件事：

1. 把 `env.PQ_DB_*` 注入应用容器，由入口脚本写入 `files/config/parameters.php`；
2. 按需引用或创建口令 Secret（见下）。

> **注意默认值**：`values.yaml` 默认 `env.PQ_DB_TYPE: mysql` +
> `env.PQ_DB_HOST: projeqtor-mysql`，这只是命名约定，**Chart 不会创建它**。
> 数据库未就绪就部署，应用会连接失败（Pod 仍会 Ready，因为健康检查端点
> `healthz.php` 不加载框架、不依赖数据库）。

### 口令 Secret 的两种模式

| 模式 | 配置 | Secret 内容 | 谁创建 |
|---|---|---|---|
| 引用已有 Secret（推荐） | `database.existingSecret` + `database.existingSecretKey` | 必须含 `PQ_DB_PASSWORD` | 你自行创建 |
| Chart 托管 | `database.password`（`existingSecret` 留空） | Chart 只生成 `PQ_DB_PASSWORD` 一个键 | Chart |

两种模式下，应用都是通过 `envFrom` 取 Secret 中的 `PQ_DB_PASSWORD`，
再由它生成 `parameters.php` 的 `$paramDbPassword`。

### 自建 Secret 时的双键语义（以 PostgreSQL 为例）

| 键 | 谁读 | 生效时机 |
|---|---|---|
| `POSTGRES_PASSWORD` | 数据库容器的 `POSTGRES_PASSWORD`（`secretKeyRef`） | **仅首次 initdb** 写入初始口令；既有 PGDATA 之后不再读它 |
| `PQ_DB_PASSWORD` | 应用容器（`envFrom` 整个 Secret） | **每次启动都读**，必须始终等于数据库中该角色的当前口令 |

由此有三条容易踩坑的结论：

1. **两键不必强制相等，但强烈建议保持一致**。唯一的硬约束是：
   `PQ_DB_PASSWORD` 必须等于数据库里该角色的当前口令。
2. **只改 `POSTGRES_PASSWORD` 等于没改**：应用并不读它（它只是被 `envFrom`
   顺带注入成一个无用环境变量），应用连接参数只由 `PQ_DB_PASSWORD` 决定。
   反过来，只改 `PQ_DB_PASSWORD` 而不改数据库，应用会立刻认证失败。
3. **两键不一致的隐患**：若数据库 PVC 被删除或重建（PGDATA 为空），容器会用
   Secret 中那个陈旧（可能已过期）的 `POSTGRES_PASSWORD` 重新初始化，与应用的
   `PQ_DB_PASSWORD` 不一致 → 应用连接失败。因此轮换时两键都应更新。

### 口令轮换顺序（不能颠倒）

PostgreSQL 的用户口令只在首次 initdb 时由 `POSTGRES_PASSWORD` 写入，此后改 Secret
不会改变数据库中的实际口令。正确顺序：

```bash
# 1) 生成新口令
NEWPW=$(openssl rand -base64 24)
# 2) 先在数据库里改（这一步才真正改变口令）
kubectl -n <ns> exec -i deploy/<postgres> -- \
  psql -U <user> -d <db> -c "ALTER USER <user> PASSWORD '$NEWPW';"
# 3) 更新 Secret：POSTGRES_PASSWORD 与 PQ_DB_PASSWORD 都改为新口令
# 4) 应用 Secret
kubectl apply -f secret.yaml
# 5) 滚动重启应用（数据库 Deployment 的 POSTGRES_PASSWORD 只影响全新初始化，
#    已有 PGDATA 不受影响；为保持 Secret 与配置一致可一并重启）
kubectl -n <ns> rollout restart deploy/<release>
# 6) 验证：访问 UI 登录，并观察 Pod 就绪
```

> **`stringData` 的坑（已实测）**：`stringData` 是"只写"字段，apply 时只会**合并**
> 进 `data`，不会删除 `data` 中的旧键。实测：先 apply `{A,B}`，再 apply 只含 `{A}`
> 的版本，`data` 中的 `B` 依然存在。需要删键时必须显式执行
> `kubectl patch secret <name> --type=json -p='[{"op":"remove","path":"/data/<KEY>"}]'`。

### 口令会落到哪些地方（安全提示）

Chart 不会主动泄露口令，但下面几种用法会让口令出现在本意之外的位置：

| 用法 | 口令落到哪里 | 建议 |
|---|---|---|
| `--set database.password=<口令>` | 集群内的 Helm release Secret（`sh.helm.release.v1.*`，base64 存放、**非加密**），以及你的 shell 历史 | 改用 `database.existingSecret`，或用权限受限的 values 文件 |
| `parameters.mount=true` + `parameters.content` | `parameters.php` 来自 **ConfigMap**（与 `env` 同一个 ConfigMap 的 `data.parameters.php`），而它必须含 `$paramDbPassword`；ConfigMap 以明文存于 etcd，且通常比 Secret 更容易被读到 | 需要自定义 parameters 时改用 Secret 挂载；**不要**把口令写进 `parameters.content` |
| Chart 托管 Secret（`database.password`） | Chart 生成的 Secret，`stringData` 写入 `data`（base64） | 正常用法；注意 `stringData` 只合并不删键（见上） |

另外，生成的 `files/config/parameters.php` 位于 PVC 上，入口脚本不会覆盖已存在的文件；
该目录已由镜像层 Apache 配置拒绝 HTTP 访问（见
[docs/known-issues.md](../../docs/known-issues.md) 的 P5）。
