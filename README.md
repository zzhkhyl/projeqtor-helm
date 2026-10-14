# projeqtor-helm

[ProjeQtOr](https://www.projeqtor.org) 的容器化交付方案：

- **GitHub Actions**：每日自动探测 [SourceForge](https://sourceforge.net/projects/projectorria/)
  上的 ProjeQtOr 最新版本，构建多架构（amd64/arm64）Docker 镜像并推送到
  `ghcr.io/zzhkhyl/projeqtor`（tag 与上游版本严格一致，最新版附带 `latest`）
- **Dockerfile**：`php:8.1-apache`，编译 ProjeQtOr 所需的全部 PHP 扩展，
  非 root 运行，通过 `PQ_DB_*` 环境变量注入数据库配置
- **Helm Chart**：参数化部署到 Kubernetes（Deployment/Service/Ingress/
  ConfigMap/Secret/PVC/可选 CronJob）

本仓库**不包含** ProjeQtOr 源码：镜像在构建时从 SourceForge 官方发布渠道
下载对应版本的 zip。仓库中的 `projeqtor/` 目录（如有）仅为本地开发参考，
已被 `.gitignore` 排除。

## 目录结构

```
.
├── .github/workflows/docker-image.yml   # CI：版本探测、构建、推送
├── docker/
│   ├── Dockerfile                       # 镜像定义（构建期下载源码）
│   ├── docker-entrypoint.sh             # 入口：环境变量 → parameters.php
│   └── healthz.php                      # 健康检查端点
├── charts/projeqtor/                    # Helm Chart
│   ├── Chart.yaml
│   ├── values.yaml                      # 全量可配置参数
│   ├── README.md                        # 参数表 + 安装/升级/卸载
│   └── templates/                       # K8s 资源模板
├── docs/known-issues.md                 # 已知问题与验证记录（含证据与处置状态）
└── README.md
```

## CI 工作流

`.github/workflows/docker-image.yml`：

| 触发条件 | 行为 |
|---|---|
| `schedule`（每日 06:00 UTC） | 探测上游最新版本，ghcr 没有该版本 tag 才构建 |
| `push` 到 `main`（仅镜像输入变更） | 重新构建并更新 `latest` |
| `pull_request`（仅镜像输入变更） | 仅构建 amd64 验证，不登录、不推送 |
| `workflow_dispatch` | 手动构建，可指定版本号（如 `12.1.0`）或强制重建 |

**只有镜像输入变更时才构建**：`docker/**`、`.dockerignore` 以及工作流自身
（`.github/workflows/docker-image.yml`）。`docs/`、`charts/`、`README` 等文档类改动
不会触发多架构构建（镜像内容与它们无关），`workflow_dispatch` 不受此限制。
新增被 Dockerfile `COPY` 或影响构建上下文的文件时，需同步加入工作流的 `paths`。

镜像标签规则：

- `<版本号>`：与 ProjeQtOr 上游版本严格一致，如 `13.1.1`
- `latest`：构建上游最新版本时追加
- `sha-<7位>`：同版本多次构建可追溯到本仓库 commit

无需配置任何 Secret：推送使用 Actions 自带的 `GITHUB_TOKEN`
（工作流已声明 `packages: write` 权限）。

## 快速开始

### Helm 部署（推荐）

```bash
helm install projeqtor ./charts/projeqtor \
  --namespace projeqtor --create-namespace \
  --set env.PQ_DB_HOST=projeqtor-mysql.projeqtor.svc.cluster.local \
  --set env.PQ_DB_NAME=projeqtor \
  --set env.PQ_DB_USER=projeqtor \
  --set database.password='YourDbPassword' \
  --set ingress.enabled=true \
  --set ingress.hosts[0].host=projeqtor.example.com
```

升级 / 卸载及完整参数说明见
[charts/projeqtor/README.md](charts/projeqtor/README.md)。

> **数据库不在本 Chart 内**：Chart 不会创建 MySQL/PostgreSQL 实例，也不包含任何
> 数据库镜像与存储，需自备（Chart 只注入 `PQ_DB_*` 环境变量并按需管理口令 Secret）。
> 自建口令 Secret 时 `POSTGRES_PASSWORD` 与 `PQ_DB_PASSWORD` 的语义、以及口令
> 轮换顺序见
> [数据库与 Secret](charts/projeqtor/README.md#数据库与-secret重要)。

### 本地 Docker 运行

```bash
docker build -f docker/Dockerfile --build-arg PROJEQTOR_VERSION=13.1.1 -t projeqtor:13.1.1 .
docker run -d -p 8080:8080 \
  -e PQ_DB_HOST=mysql -e PQ_DB_NAME=projeqtor -e PQ_DB_USER=projeqtor -e PQ_DB_PASSWORD=secret \
  -v projeqtor_files:/var/www/html/files \
  projeqtor:13.1.1
# 打开 http://localhost:8080，首次登录 admin / admin（请立即修改）
```

## 环境变量（镜像契约）

| 变量 | 说明 | 默认值 |
|---|---|---|
| `PQ_DB_TYPE` | `mysql`（MySQL/MariaDB）或 `pgsql` | `mysql` |
| `PQ_DB_HOST` | 数据库主机（设置后才生成配置文件） | 空 → 进入 Web 安装向导 |
| `PQ_DB_PORT` | 数据库端口 | `3306` |
| `PQ_DB_NAME` | 数据库名 | `projeqtor` |
| `PQ_DB_USER` | 数据库用户 | `projeqtor` |
| `PQ_DB_PASSWORD` | 数据库密码 | 空 |
| `PQ_DB_PREFIX` | 表前缀 | 空 |
| `TZ` | 容器时区 | `UTC` |
| `PQ_PG_REPAIR` | PostgreSQL 启动数据自愈开关（幂等、非致命，见 [docs/known-issues.md](docs/known-issues.md) P1） | `true` |

未设置 `PQ_DB_HOST` 时，首次访问会进入 ProjeQtOr 自带的 Web 安装向导。

## 后台任务（cron）

ProjeQtOr 的 cron 负责提醒邮件、告警检查等后台任务，需在管理界面
（Administration → cron）**手动启动一次**，之后进程内自动重启。
Helm Chart 提供可选的 CronJob（`cronJob.enabled=true`），在 Pod 重启后
自动调用 `tool/cronRelaunch.php` 重新拉起 cron。

## 多副本注意

`files/`（附件、日志、PHP session）在 Pod 间共享，副本数 > 1 时必须使用
`ReadWriteMany` 存储（`persistence.accessModes`）。

## 已知问题

真机验证（PostgreSQL 17）中识别出的全部问题、证据与处置状态见
[docs/known-issues.md](docs/known-issues.md)。当前已记录 2 项上游缺陷
（PG 升级脚本方言兼容性、缺失 `User-Agent` 时请求中断），均不阻断部署与使用。

## 开源协议

- **本仓库代码**（GitHub Actions 工作流、Dockerfile、入口脚本、Helm Chart
  及文档）采用 [MIT License](LICENSE)，Copyright (c) 2026 zhihao.wang。
- **ProjeQtOr 本体**采用 [GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.html)（AGPL-3.0）。
  通过本仓库构建的 Docker 镜像包含 ProjeQtOr 代码，因此**镜像整体受
  ProjeQtOr 的 AGPL-3.0 协议约束**（镜像 OCI label 亦标注为
  `AGPL-3.0-only`）；部署、分发或二次分发该镜像时请遵守 AGPL-3.0 的要求
  （包括向使用者提供获取完整对应源码的途径）。
