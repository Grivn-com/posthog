#!/bin/bash
#
# 在开发机上运行，打包生产部署所需的所有文件
#
# 用法:
#   cd /path/to/posthog
#   bash customizations/deploy/build-deploy-package.sh [version] [--no-images]
#
# 示例:
#   bash customizations/deploy/build-deploy-package.sh v1.0.0
#   bash customizations/deploy/build-deploy-package.sh v1.0.0 --no-images
#
set -e

VERSION="${1:-v1.0.0}"
SAVE_IMAGES=true
if [[ "${2:-}" == "--no-images" ]]; then
    SAVE_IMAGES=false
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGE_DIR=$(mktemp -d)
DEPLOY_DIR="$PACKAGE_DIR/posthog-deploy"

echo "=== PostHog 部署包构建 ==="
echo "版本: $VERSION"
echo "仓库: $REPO_ROOT"
echo "导出镜像: $SAVE_IMAGES"
echo "临时目录: $DEPLOY_DIR"
echo ""

mkdir -p "$DEPLOY_DIR"

# ============================================================
# 1. 复制部署脚本并生成 .env.template
# ============================================================
echo "[1/8] 复制部署脚本..."

# 复制 install.sh 并替换版本占位符
sed \
    -e "s|__POSTHOG_APP_TAG__|${VERSION}|g" \
    -e "s|__POSTHOG_NODE_TAG__|${VERSION}|g" \
    "$SCRIPT_DIR/install.sh" > "$DEPLOY_DIR/install.sh"
chmod +x "$DEPLOY_DIR/install.sh"

cp "$SCRIPT_DIR/uninstall.sh" "$DEPLOY_DIR/uninstall.sh"
chmod +x "$DEPLOY_DIR/uninstall.sh"

cat > "$DEPLOY_DIR/.env.template" <<ENVEOF
# PostHog 部署环境变量
#
# !!! 请运行 install.sh 自动配置，不要手动编辑此文件 !!!
# install.sh 会自动生成密钥、检测域名/IP、下载 GeoIP 数据库
#
# 如果必须手动配置，请复制为 .env 并修改以下值

# ============ 必须修改 ============

# 安全密钥（运行以下命令生成）:
#   head -c 28 /dev/urandom | sha224sum -b | head -c 56
POSTHOG_SECRET=<REPLACE_ME>

# 加密盐（必须是 32 字符的十六进制字符串）
# 运行以下命令生成:
#   openssl rand -hex 16
ENCRYPTION_SALT_KEYS=<REPLACE_ME>

# 域名或 IP 地址
# 有域名: analytics.your-company.com
# 无域名: 192.168.2.30
DOMAIN=192.168.2.30

# ============ 镜像配置 ============

# PostHog 主镜像（Python/Django + 前端）
REGISTRY_URL=grivn/posthog
POSTHOG_APP_TAG=${VERSION}

# Node.js 服务镜像（plugins, ingestion）
POSTHOG_NODE_TAG=${VERSION}

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

# ============================================================
# 2. 生成 compose 定义和容器启动脚本
# ============================================================
echo "[2/8] 生成 docker-compose 和启动脚本..."

# docker-compose.base.yml — 复制并修正路径
cp "$REPO_ROOT/docker-compose.base.yml" "$DEPLOY_DIR/"
sed -i.bak \
    -e 's|./docker/postgres-init-scripts|./config/postgres-init-scripts|g' \
    -e 's|\./products:/products:ro|./config/products:/products:ro|g' \
    -e 's|image: caddy$|image: caddy:2.9.1|g' \
    "$DEPLOY_DIR/docker-compose.base.yml"
rm -f "$DEPLOY_DIR/docker-compose.base.yml.bak"

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
    \"LIVESTREAM_HOST: '\${SITE_URL_SCHEME:-http}://\${DOMAIN}/livestream'\",
    text
)
text = text.replace('OBJECT_STORAGE_PUBLIC_ENDPOINT: https://\$DOMAIN',
                     'OBJECT_STORAGE_PUBLIC_ENDPOINT: \${SITE_URL_SCHEME:-http}://\$DOMAIN')
text = text.replace(\"CADDY_HOST: '\$DOMAIN, http://, https://'\",
                     \"CADDY_HOST: '\$CADDY_HOST'\")

# 在 web 服务的 DEPLOYMENT: 'hobby' 后注入 SECURE_COOKIES 环境变量
text = text.replace(
    \"            DEPLOYMENT: 'hobby'\",
    \"            DEPLOYMENT: 'hobby'\n            SECURE_COOKIES: '\${SECURE_COOKIES:-true}'\")

# Livestream: 添加 GeoIP 卷挂载
text = text.replace(
    '            - ./config/livestream/configs-hobby.yml:/configs/configs.yml',
    '            - ./config/livestream/configs-hobby.yml:/configs/configs.yml\n            - ./share:/share')

# 移除 POSTHOG_NODE_TAG 的 latest 回退（防止 .env 缺失时拉错镜像）
text = text.replace('\${POSTHOG_NODE_TAG:-latest}', '\${POSTHOG_NODE_TAG}')

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

print("Waiting for ClickHouse and Postgres to be ready")
while True:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect(('clickhouse', 9000))
        print("ClickHouse is ready")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect(('db', 5432))
        print("Postgres is ready")
        break
    except (ConnectionRefusedError, OSError):
        time.sleep(5)
WAITEOF

cat > "$DEPLOY_DIR/compose/temporal-django-worker" <<'TWEOF'
#!/bin/bash
./bin/temporal-django-worker
TWEOF

chmod +x "$DEPLOY_DIR/compose/"*

# ============================================================
# 3. 复制 ClickHouse 配置
# ============================================================
echo "[3/8] 复制 ClickHouse 配置..."
mkdir -p "$DEPLOY_DIR/config/clickhouse/config.d"
mkdir -p "$DEPLOY_DIR/config/clickhouse/docker-entrypoint-initdb.d"
cp "$REPO_ROOT/docker/clickhouse/config.xml" "$DEPLOY_DIR/config/clickhouse/"
cp "$REPO_ROOT/docker/clickhouse/config.d/default.xml" "$DEPLOY_DIR/config/clickhouse/config.d/"
cp "$REPO_ROOT/docker/clickhouse/docker-entrypoint-initdb.d/init-db.sh" "$DEPLOY_DIR/config/clickhouse/docker-entrypoint-initdb.d/"
cp "$REPO_ROOT/docker/clickhouse/users.xml" "$DEPLOY_DIR/config/clickhouse/"
cp "$REPO_ROOT/docker/clickhouse/user_defined_function.xml" "$DEPLOY_DIR/config/clickhouse/"

# ============================================================
# 4. 复制 Temporal 配置
# ============================================================
echo "[4/8] 复制 Temporal 配置..."
mkdir -p "$DEPLOY_DIR/config/temporal/dynamicconfig"
cp "$REPO_ROOT/docker/temporal/dynamicconfig/development-sql.yaml" "$DEPLOY_DIR/config/temporal/dynamicconfig/"
cp "$REPO_ROOT/docker/temporal/dynamicconfig/docker.yaml" "$DEPLOY_DIR/config/temporal/dynamicconfig/"

# ============================================================
# 5. 复制 Livestream 配置、IDL、UDF
# ============================================================
echo "[5/8] 复制其他配置文件..."

# Livestream
mkdir -p "$DEPLOY_DIR/config/livestream"
cp "$REPO_ROOT/docker/livestream/configs-hobby.yml" "$DEPLOY_DIR/config/livestream/"
# 修正 GeoIP 路径为容器内绝对路径（需配合 ./share:/share 卷挂载）
sed -i.bak "s|path: 'GeoLite2-City.mmdb'|path: '/share/GeoLite2-City.mmdb'|g" "$DEPLOY_DIR/config/livestream/configs-hobby.yml"
rm -f "$DEPLOY_DIR/config/livestream/configs-hobby.yml.bak"

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

# ============================================================
# 6. 下载 GeoIP 数据库
# ============================================================
echo "[6/8] 准备 GeoIP 数据库..."
mkdir -p "$DEPLOY_DIR/share"
if [ -f "$REPO_ROOT/share/GeoLite2-City.mmdb" ]; then
    echo "  使用本地 GeoIP 数据库..."
    cp "$REPO_ROOT/share/GeoLite2-City.mmdb" "$DEPLOY_DIR/share/"
else
    echo "  下载 GeoLite2-City.mmdb..."
    if command -v brotli &> /dev/null; then
        curl -L 'https://mmdbcdn.posthog.net/' --http1.1 | brotli --decompress > "$DEPLOY_DIR/share/GeoLite2-City.mmdb" && \
            echo "  下载完成" || echo "  警告: 下载失败，客户安装时需联网下载"
    elif command -v python3 &> /dev/null && python3 -c "import brotli" 2>/dev/null; then
        curl -L 'https://mmdbcdn.posthog.net/' --http1.1 -o /tmp/geo.br && \
            python3 -c "import brotli,sys; sys.stdout.buffer.write(brotli.decompress(open('/tmp/geo.br','rb').read()))" > "$DEPLOY_DIR/share/GeoLite2-City.mmdb" && \
            rm -f /tmp/geo.br && echo "  下载完成" || echo "  警告: 下载失败，客户安装时需联网下载"
    else
        echo "  警告: 未找到 brotli，跳过 GeoIP 预下载"
        echo "  提示: pip3 install brotli 或 brew install brotli 后重新打包"
    fi
fi

# ============================================================
# 7. 导出 Docker 镜像
# ============================================================
if [ "$SAVE_IMAGES" = true ]; then
    echo "[7/8] 导出 Docker 镜像（这可能需要较长时间）..."

    # 从 compose 文件中提取第三方镜像（固定版本）
    THIRD_PARTY_IMAGES=(
        "caddy:2.9.1"
        "postgres:15.12-alpine"
        "redis:7.2-alpine"
        "clickhouse/clickhouse-server:25.12.8.9"
        "zookeeper:3.7.0"
        "docker.redpanda.com/redpandadata/redpanda:v25.1.9"
        "minio/minio:RELEASE.2025-04-22T22-12-26Z"
        "elasticsearch:7.17.28"
        "temporalio/auto-setup:1.26.2"
        "temporalio/admin-tools:1.26.2"
        "temporalio/ui:2.47.2"
        "chrislusf/seaweedfs:4.03"
    )

    # PostHog 官方 sidecar 镜像 — 锁定到已验证可用的 digest
    # 更新方法：在已验证环境运行以下命令获取新 digest:
    #   for img in ghcr.io/posthog/posthog/{capture,property-defs-rs,feature-flags,livestream,cyclotron-janitor,cymbal}:master; do
    #     echo "$img -> $(docker inspect --format='{{index .RepoDigests 0}}' "$img")"
    #   done
    declare -A SIDECAR_DIGESTS=(
        ["ghcr.io/posthog/posthog/capture:master"]="ghcr.io/posthog/posthog/capture@sha256:47febd08cc12798f3559f7557a8981d8f7f220e34c5a6e557bbfbca46eae4cb8"
        ["ghcr.io/posthog/posthog/property-defs-rs:master"]="ghcr.io/posthog/posthog/property-defs-rs@sha256:476809bd01e765f8973d43e6fcb2d61194c0bfa466a654eb0c4f16e97ee418db"
        ["ghcr.io/posthog/posthog/feature-flags:master"]="ghcr.io/posthog/posthog/feature-flags@sha256:0d89fc60bb62de0f5dfa3304d11e485d259d797b1e5ebabf8e15f1992242be9c"
        ["ghcr.io/posthog/posthog/livestream:master"]="ghcr.io/posthog/posthog/livestream@sha256:e93204a3279ce0833a0bf98bb1414c2416da05eca6c2d82ea8d3788e71e40aad"
        ["ghcr.io/posthog/posthog/cyclotron-janitor:master"]="ghcr.io/posthog/posthog/cyclotron-janitor@sha256:92416f78bcd7859a436bc9b939344d1c343ed9c04a2323cb80d70b3f72745138"
        ["ghcr.io/posthog/posthog/cymbal:master"]="ghcr.io/posthog/posthog/cymbal@sha256:4848dab3a1dd63529d2671e28fbd5968f4a41d252bbe5ef94cd6a28f064c6452"
    )

    # 用户自建镜像
    REGISTRY_URL="${REGISTRY_URL:-grivn/posthog}"
    USER_IMAGES=(
        "${REGISTRY_URL}:${VERSION}"
        "${REGISTRY_URL}-node:${VERSION}"
    )

    ALL_IMAGES=()

    # Pull 第三方镜像
    echo "  拉取第三方镜像..."
    for img in "${THIRD_PARTY_IMAGES[@]}"; do
        echo "    pulling $img"
        docker pull "$img" > /dev/null 2>&1 || echo "    警告: 无法拉取 $img"
        ALL_IMAGES+=("$img")
    done

    # Pull sidecar 镜像（按锁定的 digest）
    echo "  拉取 sidecar 镜像（已锁定版本）..."
    for tag in "${!SIDECAR_DIGESTS[@]}"; do
        digest="${SIDECAR_DIGESTS[$tag]}"
        echo "    pulling $digest"
        docker pull "$digest" > /dev/null 2>&1 || { echo "    警告: 无法拉取 $digest"; continue; }
        # 打上 :master tag 以便 docker save 时包含可读 tag
        docker tag "$digest" "$tag" 2>/dev/null || true
        ALL_IMAGES+=("$tag")
    done

    # 用户镜像（应已在本地）
    echo "  检查用户镜像..."
    for img in "${USER_IMAGES[@]}"; do
        if docker image inspect "$img" > /dev/null 2>&1; then
            echo "    found $img"
            ALL_IMAGES+=("$img")
        else
            echo "    警告: 未找到 $img，请先构建"
        fi
    done

    # 替换 docker-compose.base.yml 中 sidecar 的 :master 为 @sha256:xxx
    echo "  锁定 compose 文件中的镜像版本..."
    for tag in "${!SIDECAR_DIGESTS[@]}"; do
        digest="${SIDECAR_DIGESTS[$tag]}"
        sed -i.bak "s|${tag}|${digest}  # was ${tag}|g" "$DEPLOY_DIR/docker-compose.base.yml"
    done
    rm -f "$DEPLOY_DIR/docker-compose.base.yml.bak"

    # 同样替换 docker-compose.yml 中的 cymbal 引用（cymbal 在 hobby compose 中直接定义）
    if [ -f "$DEPLOY_DIR/docker-compose.yml" ]; then
        cymbal_tag="ghcr.io/posthog/posthog/cymbal:master"
        cymbal_digest="${SIDECAR_DIGESTS[$cymbal_tag]}"
        if [ -n "$cymbal_digest" ]; then
            sed -i.bak "s|${cymbal_tag}|${cymbal_digest}  # was ${cymbal_tag}|g" "$DEPLOY_DIR/docker-compose.yml"
            rm -f "$DEPLOY_DIR/docker-compose.yml.bak"
        fi
    fi

    # 导出所有镜像为单个 tar
    echo "  导出镜像到 images.tar..."
    docker save "${ALL_IMAGES[@]}" -o "$DEPLOY_DIR/images.tar"
    echo "  镜像大小: $(du -h "$DEPLOY_DIR/images.tar" | cut -f1)"
else
    echo "[7/8] 跳过镜像导出（--no-images）"
fi

# ============================================================
# 8. 打包
# ============================================================
echo "[8/8] 打包..."
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
