#!/bin/bash
#
# 在开发机上运行，打包生产部署所需的所有文件
#
# 用法:
#   cd /path/to/posthog
#   bash customizations/deploy/build-deploy-package.sh [version]
#
# 示例:
#   bash customizations/deploy/build-deploy-package.sh v1.0.0
#
set -e

VERSION="${1:-v1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGE_DIR=$(mktemp -d)
DEPLOY_DIR="$PACKAGE_DIR/posthog-deploy"

echo "=== PostHog 部署包构建 ==="
echo "版本: $VERSION"
echo "仓库: $REPO_ROOT"
echo "临时目录: $DEPLOY_DIR"
echo ""

mkdir -p "$DEPLOY_DIR"

# 1. 复制部署脚本并生成 .env.template
echo "[1/6] 复制部署脚本..."
cp "$SCRIPT_DIR/install.sh" "$DEPLOY_DIR/"

cat > "$DEPLOY_DIR/.env.template" <<'ENVEOF'
# PostHog 部署环境变量
# 复制为 .env 并修改以下值

# ============ 必须修改 ============

# 安全密钥（运行以下命令生成）:
#   head -c 28 /dev/urandom | sha224sum -b | head -c 56
POSTHOG_SECRET=<REPLACE_ME>

# 加密盐（运行以下命令生成）:
#   openssl rand -hex 16
ENCRYPTION_SALT_KEYS=<REPLACE_ME>

# 域名或 IP 地址
# 有域名: analytics.your-company.com
# 无域名: 192.168.2.30
DOMAIN=192.168.2.30

# ============ 镜像配置 ============

# PostHog 主镜像（Python/Django + 前端）
REGISTRY_URL=grivn/posthog
POSTHOG_APP_TAG=v1.0.0

# Node.js 服务镜像（plugins, ingestion）
# 如果使用官方镜像，保持默认值
POSTHOG_NODE_TAG=latest

# ============ TLS / Caddy ============

# 有域名时: TLS_BLOCK 留空，Caddy 自动获取 Let's Encrypt 证书
# 无域名时: TLS_BLOCK 留空，CADDY_HOST 必须加 http:// 前缀
TLS_BLOCK=

# 有域名: "analytics.your-company.com, http://, https://"
# 无域名: "http://192.168.2.30"
CADDY_HOST="http://192.168.2.30"

# ============ 可选配置 ============

# HTTP 模式（无域名，纯 IP）时必须设为 false
# HTTPS 模式（有域名）时保持 true
SECURE_COOKIES=false

# 是否禁用匿名使用数据上报（默认上报给 PostHog 官方）
OPT_OUT_CAPTURE=true

# Docker 镜像前缀（如需使用镜像加速）
# DOCKER_REGISTRY_PREFIX=registry.cn-hangzhou.aliyuncs.com/
ENVEOF

# 2. 生成 compose 定义和容器启动脚本（从仓库实时生成，不使用静态副本）
echo "[2/6] 生成 docker-compose 和启动脚本..."

# docker-compose.base.yml — 直接复制
cp "$REPO_ROOT/docker-compose.base.yml" "$DEPLOY_DIR/"

# docker-compose.yml — 基于 hobby 版本，修正路径、删除 build 块
# 使用 Python 处理：sed 无法正确删除多行嵌套的 YAML build: 块
python3 -c "
import re, sys

with open(sys.argv[1]) as f:
    lines = f.readlines()

result = []
skip = False
build_indent = 0

for line in lines:
    stripped = line.rstrip('\n')
    # 检测 build: 块开始（8空格缩进，即服务级属性）
    if re.match(r'^        build:\s*$', stripped):
        skip = True
        build_indent = len(stripped) - len(stripped.lstrip())
        continue
    # 在 build 块内：跳过缩进更深的行
    if skip:
        current_indent = len(stripped) - len(stripped.lstrip()) if stripped.strip() else build_indent + 1
        if current_indent > build_indent:
            continue
        else:
            skip = False
    result.append(line)

text = ''.join(result)

# 路径替换
text = text.replace('./posthog/posthog/idl', './config/idl')
text = text.replace('./posthog/docker/clickhouse', './config/clickhouse')
text = text.replace('./posthog/docker/temporal', './config/temporal')
text = text.replace('./posthog/docker/livestream', './config/livestream')
text = text.replace('./posthog/posthog/user_scripts', './config/user_scripts')

# SITE_URL: https → 变量
text = text.replace('SITE_URL: https://\$DOMAIN', 'SITE_URL: \${SITE_URL_SCHEME:-http}://\$DOMAIN')
text = re.sub(
    r\"LIVESTREAM_HOST: 'https://\\\$\\{DOMAIN\\}/livestream'\",
    \"LIVESTREAM_HOST: '\\\${SITE_URL_SCHEME:-http}://\\\${DOMAIN}/livestream'\",
    text
)
text = text.replace('OBJECT_STORAGE_PUBLIC_ENDPOINT: https://\$DOMAIN',
                     'OBJECT_STORAGE_PUBLIC_ENDPOINT: \${SITE_URL_SCHEME:-http}://\$DOMAIN')
text = text.replace(\"CADDY_HOST: '\\\$DOMAIN, http://, https://'\",
                     \"CADDY_HOST: '\\\$CADDY_HOST'\")

# 在 web 服务的 DEPLOYMENT: 'hobby' 后注入 SECURE_COOKIES 环境变量
text = text.replace(
    \"            DEPLOYMENT: 'hobby'\",
    \"            DEPLOYMENT: 'hobby'\n            SECURE_COOKIES: '\\\${SECURE_COOKIES:-true}'\")

sys.stdout.write(text)
" "$REPO_ROOT/docker-compose.hobby.yml" > "$DEPLOY_DIR/docker-compose.yml"

# compose/ 启动脚本 — 与 bin/deploy-hobby 生成的逻辑一致
mkdir -p "$DEPLOY_DIR/compose"

cat > "$DEPLOY_DIR/compose/start" <<'STARTEOF'
#!/bin/bash
./compose/wait
./bin/migrate
./bin/docker-server
STARTEOF

cat > "$DEPLOY_DIR/compose/wait" <<'WAITEOF'
#!/usr/bin/env python3

import socket
import time

def loop():
    print("Waiting for ClickHouse and Postgres to be ready")
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect(('clickhouse', 9000))
        print("Clickhouse is ready")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect(('db', 5432))
        print("Postgres is ready")
    except ConnectionRefusedError:
        time.sleep(5)
        loop()

loop()
WAITEOF

cat > "$DEPLOY_DIR/compose/temporal-django-worker" <<'TWEOF'
#!/bin/bash
./bin/temporal-django-worker
TWEOF

chmod +x "$DEPLOY_DIR/compose/"*

# 3. 复制 ClickHouse 配置
echo "[3/6] 复制 ClickHouse 配置..."
mkdir -p "$DEPLOY_DIR/config/clickhouse/config.d"
mkdir -p "$DEPLOY_DIR/config/clickhouse/docker-entrypoint-initdb.d"
cp "$REPO_ROOT/docker/clickhouse/config.xml" "$DEPLOY_DIR/config/clickhouse/"
cp "$REPO_ROOT/docker/clickhouse/config.d/default.xml" "$DEPLOY_DIR/config/clickhouse/config.d/"
cp "$REPO_ROOT/docker/clickhouse/docker-entrypoint-initdb.d/init-db.sh" "$DEPLOY_DIR/config/clickhouse/docker-entrypoint-initdb.d/"
cp "$REPO_ROOT/docker/clickhouse/users.xml" "$DEPLOY_DIR/config/clickhouse/"
cp "$REPO_ROOT/docker/clickhouse/user_defined_function.xml" "$DEPLOY_DIR/config/clickhouse/"

# 4. 复制 Temporal 配置
echo "[4/6] 复制 Temporal 配置..."
mkdir -p "$DEPLOY_DIR/config/temporal/dynamicconfig"
cp "$REPO_ROOT/docker/temporal/dynamicconfig/development-sql.yaml" "$DEPLOY_DIR/config/temporal/dynamicconfig/"
cp "$REPO_ROOT/docker/temporal/dynamicconfig/docker.yaml" "$DEPLOY_DIR/config/temporal/dynamicconfig/"

# 5. 复制 Livestream 配置、IDL、UDF
echo "[5/6] 复制其他配置文件..."

# Livestream
mkdir -p "$DEPLOY_DIR/config/livestream"
cp "$REPO_ROOT/docker/livestream/configs-hobby.yml" "$DEPLOY_DIR/config/livestream/"

# ClickHouse IDL 定义
mkdir -p "$DEPLOY_DIR/config/idl"
cp "$REPO_ROOT/posthog/idl/"*.json "$DEPLOY_DIR/config/idl/"

# ClickHouse UDF 二进制脚本
cp -r "$REPO_ROOT/posthog/user_scripts" "$DEPLOY_DIR/config/user_scripts"

# PostgreSQL 初始化脚本
mkdir -p "$DEPLOY_DIR/config/postgres-init-scripts"
cp "$REPO_ROOT/docker/postgres-init-scripts/"*.sh "$DEPLOY_DIR/config/postgres-init-scripts/"

# Products 数据库路由配置
mkdir -p "$DEPLOY_DIR/config/products"
cp "$REPO_ROOT/products/db_routing.yaml" "$DEPLOY_DIR/config/products/"

# share 目录（GeoIP 数据库，如果存在）
mkdir -p "$DEPLOY_DIR/share"
if [ -f "$REPO_ROOT/share/GeoLite2-City.mmdb" ]; then
    echo "  包含 GeoIP 数据库..."
    cp "$REPO_ROOT/share/GeoLite2-City.mmdb" "$DEPLOY_DIR/share/"
fi

# 6. 打包
echo "[6/6] 打包..."
OUTPUT="$REPO_ROOT/posthog-deploy-${VERSION}.tar.gz"
tar -czf "$OUTPUT" -C "$PACKAGE_DIR" posthog-deploy

# 清理
rm -rf "$PACKAGE_DIR"

echo ""
echo "=== 构建完成 ==="
echo "部署包: $OUTPUT"
echo "大小: $(du -h "$OUTPUT" | cut -f1)"
echo ""
echo "使用方法:"
echo "  1. 将 $OUTPUT 传输到目标服务器"
echo "  2. tar -xzf posthog-deploy-${VERSION}.tar.gz"
echo "  3. cd posthog-deploy"
echo "  4. bash install.sh"
