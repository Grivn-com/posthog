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

# 1. 复制部署脚本和 compose 定义
echo "[1/6] 复制部署脚本..."
cp "$SCRIPT_DIR/install.sh" "$DEPLOY_DIR/"
cp "$SCRIPT_DIR/.env.template" "$DEPLOY_DIR/"
cp "$SCRIPT_DIR/docker-compose.yml" "$DEPLOY_DIR/"
cp "$REPO_ROOT/docker-compose.base.yml" "$DEPLOY_DIR/"

# 2. 复制容器启动脚本
echo "[2/6] 复制容器启动脚本..."
cp -r "$SCRIPT_DIR/compose" "$DEPLOY_DIR/"
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
