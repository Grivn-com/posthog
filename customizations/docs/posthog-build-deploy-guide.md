# PostHog 商用版编译打包与部署方案

## Context

基于 `pujun` 分支开发自己的商用版软件，需要了解整个项目如何编译打包，以及最终以何种方式部署到生产环境。PostHog 是一个复杂的多语言 monorepo（Python/TypeScript/Rust），最终产物是 Docker 镜像，部署方式为 Docker Compose（单机）。

---

## 一、项目整体架构

PostHog 由以下核心组件构成：

| 组件 | 语言/框架 | 职责 |
|------|-----------|------|
| Web 应用 | Python/Django | API 服务、后台管理、数据查询 |
| 前端 | TypeScript/React | 用户界面（SPA） |
| Plugin Server | Node.js/TypeScript | 事件处理、插件执行、CDP webhook |
| Capture 服务 | Rust | 高性能事件采集（HTTP → Kafka） |
| Feature Flags 服务 | Rust | 特性开关评估 |
| Celery Worker | Python | 后台异步任务 |
| Temporal Worker | Python | 长时间运行的工作流（批量导出、数据仓库同步等） |

**基础设施依赖：**
- **PostgreSQL 15** — 主关系型数据库
- **ClickHouse 24+** — OLAP 分析数据库
- **Redis 7** — 缓存、消息队列
- **Kafka** — 事件流（通过 Redpanda 或 Apache Kafka）
- **Zookeeper** — Kafka/ClickHouse 协调
- **MinIO** — S3 兼容对象存储（会话录制、文件导出）
- **Temporal** — 工作流引擎

---

## 二、编译打包流程

### 2.1 主 Docker 镜像构建（`/Dockerfile`）

这是最核心的构建文件，采用 **多阶段构建（multi-stage build）**，最终产出一个约 2GB 的 Docker 镜像。

#### Stage 1: 前端构建 (`frontend-build`)
```
基础镜像: node:24.13.0-bookworm-slim
工具: pnpm + turbo
输入: frontend/, products/, common/ 中的 TypeScript/React 代码
输出: /frontend/dist/ (HTML, CSS, JS 静态文件)
命令: bin/turbo --filter=@posthog/frontend build
```

#### Stage 2: Node.js 脚本构建 (`node-scripts-build`)
```
基础镜像: node:24.13.0-bookworm-slim
输入: nodejs/, common/plugin_transpiler/
输出: 编译后的 Node.js 服务代码
命令: turbo build --filter=@posthog/nodejs...
```

#### Stage 3: Python 后端构建 (`posthog-build`)
```
基础镜像: python:3.12-slim + astral-sh/uv:0.10.2
工具: uv (超快 Python 包管理器)
输入: pyproject.toml, uv.lock
输出: /python-runtime/ (Python 虚拟环境 + 所有依赖)
命令: uv sync --locked --no-dev
额外: python manage.py collectstatic --noinput → /staticfiles/
```

#### Stage 4: GeoIP 数据库 (`fetch-geoip-db`)
```
下载 GeoLite2-City.mmdb 地理位置数据库
来源: mmdbcdn.posthog.net
```

#### Stage 5: 最终运行镜像
```
基础镜像: unit:1.33.0-python3.12 (Nginx Unit ASGI/WSGI 服务器)
包含:
  - Django 应用 + Python 依赖
  - 前端静态资源 (/frontend/dist/)
  - Node.js 24 运行时 + 编译后的 Node 服务
  - Chromium + ffmpeg + Playwright（用于会话录制导出）
  - GeoIP 数据库
运行用户: posthog (UID 1000, 非 root)
暴露端口: 8000 (应用), 8001 (Prometheus 指标)
入口: ./bin/docker
```

### 2.2 构建命令

**在本地构建主镜像：**
```bash
# 构建自定义商用版镜像
docker build -t your-company/posthog:latest .

# 如果需要指定平台（例如在 Mac M 芯片上构建 Linux amd64）
docker build --platform linux/amd64 -t your-company/posthog:latest .
```

**Node.js 服务镜像（可选，如需独立部署）：**
```bash
docker build -f Dockerfile.node -t your-company/posthog-node:latest .
```

### 2.3 前端单独构建（开发调试用）

```bash
# 安装前端依赖
corepack enable
pnpm install --frozen-lockfile

# 开发模式
pnpm --filter=@posthog/frontend start

# 生产构建
pnpm --filter=@posthog/frontend build
# 产出: frontend/dist/
```

### 2.4 后端单独构建（开发调试用）

```bash
# 安装 Python 依赖
uv sync --locked

# 收集静态文件
python manage.py collectstatic --noinput

# 运行数据库迁移
python manage.py migrate          # PostgreSQL
python manage.py migrate_clickhouse  # ClickHouse
```

---

## 三、部署方式

### 3.1 推荐方式：Docker Compose 单机部署（Hobby 模式）

PostHog **已经停止支持 Kubernetes/Helm 自托管部署**，官方推荐的自托管方式是 Docker Compose 单机部署。

#### 核心文件
- `docker-compose.base.yml` — 服务基础定义（22KB）
- `docker-compose.hobby.yml` — 单机部署配置（继承 base）

#### 服务组成

```
┌─────────────────────────────────────────────┐
│                   Caddy                      │  ← 反向代理 + 自动 HTTPS
│              (端口 80/443)                    │
├─────────────────────────────────────────────┤
│  /e, /capture → capture:3000 (Rust)         │
│  /s/*        → replay-capture:3000 (Rust)   │
│  /flags/*    → feature-flags:3001 (Rust)    │
│  其他        → web:8000 (Django)             │
├─────────────────────────────────────────────┤
│  web (Django + 前端静态文件)                  │
│  worker (Celery 后台任务)                     │
│  plugins (Node.js 插件服务)                   │
│  temporal-worker (工作流执行)                  │
├─────────────────────────────────────────────┤
│  PostgreSQL 15  │  ClickHouse  │  Redis 7    │
│  Kafka          │  Zookeeper   │  MinIO      │
│  Temporal       │  SeaweedFS   │  pgBouncer  │
└─────────────────────────────────────────────┘
```

#### 部署步骤（使用部署安装包）

整个部署分为两个阶段：**开发机打包** → **生产机安装**。

##### 阶段一：在开发机上构建镜像和部署包

```bash
cd /path/to/posthog   # 仓库根目录（pujun 分支）

# 1. 构建 Docker 镜像
docker build --network=host -t grivn/posthog:v1.0.0 .

# 2. 推送到镜像仓库（Docker Hub / Harbor / 阿里云 ACR）
docker push grivn/posthog:v1.0.0

# 3. 生成部署安装包（自动收集所有配置文件）
bash customizations/deploy/build-deploy-package.sh v1.0.0
# 产出: posthog-deploy-v1.0.0.tar.gz
```

部署包内容（自包含，生产机无需克隆代码仓库）：
```
posthog-deploy/
  ├── install.sh                 ← 一键安装脚本
  ├── .env.template              ← 环境变量模板
  ├── docker-compose.base.yml    ← 服务基础定义
  ├── docker-compose.yml         ← 部署用 compose（路径已修正）
  ├── compose/                   ← 容器启动脚本（挂载进容器执行）
  │   ├── start                  ← web 容器入口: wait → migrate → server
  │   ├── wait                   ← 等待 ClickHouse/Postgres 就绪
  │   └── temporal-django-worker
  ├── config/                    ← 配置文件（volume 挂载进各容器）
  │   ├── clickhouse/            ← ClickHouse 配置
  │   ├── temporal/dynamicconfig/ ← Temporal 动态配置
  │   ├── livestream/            ← Livestream 配置
  │   ├── idl/                   ← ClickHouse IDL 定义
  │   ├── user_scripts/          ← ClickHouse UDF 二进制
  │   ├── postgres-init-scripts/ ← PostgreSQL 初始化脚本
  │   └── products/              ← 产品数据库路由
  └── share/                     ← GeoIP 数据库（如开发机上有则包含）
```

##### 阶段二：在生产服务器上安装

```bash
# 1. 将部署包传输到服务器
scp posthog-deploy-v1.0.0.tar.gz user@server:/opt/

# 2. 解压
cd /opt
tar -xzf posthog-deploy-v1.0.0.tar.gz
cd posthog-deploy

# 3. 一键安装（交互式询问域名/IP，自动生成密钥、下载 GeoIP、启动服务）
bash install.sh

# 安装脚本会:
#   - 生成 POSTHOG_SECRET 和 ENCRYPTION_SALT_KEYS
#   - 询问域名/IP，自动判断 HTTPS/HTTP 模式
#   - 生成 .env
#   - 下载 GeoIP 数据库
#   - docker compose up -d
#   - 等待健康检查通过
```

**手动配置（可选）**：如果不想用交互式安装，可以手动操作：
```bash
# 复制并编辑环境变量
cp .env.template .env
vim .env   # 修改 DOMAIN、REGISTRY_URL、POSTHOG_APP_TAG 等

# 下载 GeoIP 数据库
mkdir -p share
curl -L 'https://mmdbcdn.posthog.net/' --http1.1 | brotli --decompress > share/GeoLite2-City.mmdb

# 启动
docker compose up -d

# 等待 5-10 分钟后验证
curl -s http://localhost/_health  # 应返回 200
```

### 3.2 数据持久化

Docker Compose 使用以下 named volumes 持久化数据：

| Volume | 用途 |
|--------|------|
| `postgres-data` | PostgreSQL 数据 |
| `clickhouse-data` | ClickHouse 分析数据 |
| `redis7-data` | Redis 缓存数据 |
| `kafka-data` | Kafka 消息数据 |
| `zookeeper-data/datalog/logs` | Zookeeper 协调数据 |

### 3.3 启动流程详解

容器启动后的内部流程：

```
bin/docker (入口)
  ├── bin/migrate (数据库迁移)
  │     ├── python manage.py migrate (PostgreSQL)
  │     ├── python manage.py migrate_clickhouse (ClickHouse)
  │     └── python manage.py run_async_migrations (异步迁移)
  ├── bin/docker-worker (后台启动)
  │     ├── Node.js 插件服务
  │     └── Celery worker + beat
  └── bin/docker-server-unit (前台运行)
        └── Nginx Unit (4 进程, 端口 8000)
            └── Django WSGI 应用
```

### 3.4 应用服务器选择

支持两种模式（通过环境变量切换）：

| 服务器 | 环境变量 | 特点 |
|--------|----------|------|
| **Nginx Unit**（默认） | 默认 | WSGI, 4 进程, 稳定 |
| **Granian**（可选） | `USE_GRANIAN=true` | ASGI, uvloop, 高并发 |

---

## 四、商用版定制建议

### 4.1 镜像仓库
- 搭建私有 Docker Registry（Harbor/AWS ECR/阿里云容器镜像服务）
- 构建镜像后推送到私有仓库
```bash
docker build -t registry.your-company.com/posthog:v1.0.0 .
docker push registry.your-company.com/posthog:v1.0.0
```

### 4.2 CI/CD 流水线
参考 `.github/workflows/container-images-cd.yml`，搭建自己的 CI/CD：
1. 代码推送到 pujun 分支
2. CI 自动运行测试
3. 构建 Docker 镜像
4. 推送到私有镜像仓库
5. 在目标服务器上 `docker-compose pull && docker-compose up -d`

### 4.3 环境配置关键项

```bash
# posthog/settings/ 目录结构
__init__.py          # 入口，导入所有模块
base_variables.py    # DEBUG, CLOUD_DEPLOYMENT, SELF_CAPTURE 等
data_stores.py       # PostgreSQL, ClickHouse, Redis, Kafka 连接配置
web.py               # Django INSTALLED_APPS, 中间件, 认证
celery.py            # Celery worker 配置
temporal.py          # Temporal 工作流配置
object_storage.py    # S3/MinIO 对象存储配置
ee.py                # 企业版功能开关
```

### 4.4 升级流程
```bash
# 1. 拉取最新代码
git pull origin pujun

# 2. 重新构建镜像
docker build -t your-company/posthog:v1.1.0 .

# 3. 更新 .env 中的版本号
# POSTHOG_APP_TAG=v1.1.0

# 4. 滚动更新
docker-compose pull
docker-compose up -d

# 迁移会在容器启动时自动执行（bin/docker → bin/migrate）
```

---

## 五、硬件要求

| 规模 | CPU | 内存 | 磁盘 | 适用场景 |
|------|-----|------|------|----------|
| 最低 | 4 核 | 8 GB | 100 GB SSD | 体验/测试 |
| 推荐 | 8 核 | 16 GB | 500 GB SSD | 中小团队（<50 人） |
| 生产 | 16 核 | 32 GB+ | 1 TB+ NVMe | 正式商用（高事件量） |

> ClickHouse 是最吃资源的组件，事件量大时需要单独考虑扩容。

---

## 六、验证清单

- [ ] `docker build` 成功产出镜像
- [ ] `docker-compose up -d` 所有容器正常运行
- [ ] `curl http://localhost/_health` 返回 200
- [ ] 能访问 Web UI 并完成初始设置
- [ ] 事件采集 SDK 能正常发送数据
- [ ] ClickHouse 中能查到采集的事件数据
- [ ] Celery worker 日志无报错
- [ ] Temporal worker 正常启动
