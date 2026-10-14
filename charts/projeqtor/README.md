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

- **数据库**：本 Chart 不包含数据库。ProjeQtOr 使用外部
  MySQL/MariaDB/PostgreSQL，通过 `env.PQ_DB_*` + `database.password` 配置。
  容器首次启动时会将其写入 `files/config/parameters.php`（位于 PVC 上，
  重复启动/升级不会覆盖）。
- **持久化**：`files/` 目录（附件、日志、报告、生成的配置）整体挂载 PVC。
  单副本可用 `ReadWriteOnce`；多副本必须使用 `ReadWriteMany`
  （NFS、CephFS、Longhorn 等），因为附件与 PHP session 在 Pod 间共享。
- **安全**：容器以 `www-data`（uid 33）非 root 运行，Apache 监听 8080，
  已丢弃全部 Linux capabilities。
