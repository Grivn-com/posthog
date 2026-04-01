#!/bin/bash
#
# PostHog 商用版一键安装脚本
#
# 在目标服务器上运行:
#   tar -xzf posthog-deploy-v1.0.0.tar.gz
#   cd posthog-deploy
#   bash install.sh
#
set -e

echo "=== PostHog 商用版安装 ==="
echo ""

# 检查 Docker
if ! command -v docker &> /dev/null; then
    echo "错误: Docker 未安装。请先安装 Docker。"
    echo "  curl -fsSL https://get.docker.com | sh"
    exit 1
fi

# 检查 Docker Compose
if ! docker compose version &> /dev/null && ! command -v docker-compose &> /dev/null; then
    echo "错误: Docker Compose 未安装。请先安装 Docker Compose。"
    exit 1
fi

# 确定 compose 命令
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# 检查必要文件
for f in docker-compose.base.yml docker-compose.yml compose/start compose/wait; do
    if [ ! -f "$f" ]; then
        echo "错误: 缺少文件 $f，请确保在部署包目录内运行此脚本。"
        exit 1
    fi
done

# 生成 .env（如果不存在）
if [ ! -f .env ]; then
    echo "[1/4] 生成环境变量..."

    POSTHOG_SECRET=$(head -c 28 /dev/urandom | sha224sum -b | head -c 56)
    ENCRYPTION_SALT_KEYS=$(openssl rand -hex 16)

    echo ""
    echo "请输入服务器的域名或 IP 地址"
    echo "  有域名示例: analytics.your-company.com"
    echo "  无域名示例: 192.168.2.30"
    read -r -p "域名/IP: " DOMAIN

    if [ -z "$DOMAIN" ]; then
        echo "错误: 域名/IP 不能为空"
        exit 1
    fi

    # 判断是 IP 还是域名
    if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # IP 地址 → HTTP 模式
        SITE_URL_SCHEME="http"
        CADDY_HOST="http://${DOMAIN}"
        SECURE_COOKIES="false"
        echo "  检测到 IP 地址，使用 HTTP 模式"
    else
        # 域名 → HTTPS 模式
        SITE_URL_SCHEME="https"
        CADDY_HOST="${DOMAIN}, http://, https://"
        SECURE_COOKIES="true"
        echo "  检测到域名，使用 HTTPS 模式（Caddy 自动获取证书）"
    fi

    cat > .env <<EOF
POSTHOG_SECRET=${POSTHOG_SECRET}
ENCRYPTION_SALT_KEYS=${ENCRYPTION_SALT_KEYS}
DOMAIN=${DOMAIN}
SITE_URL_SCHEME=${SITE_URL_SCHEME}
TLS_BLOCK=
CADDY_HOST="${CADDY_HOST}"
SECURE_COOKIES=${SECURE_COOKIES}
REGISTRY_URL=${REGISTRY_URL:-grivn/posthog}
POSTHOG_APP_TAG=${POSTHOG_APP_TAG:-v1.0.0}
POSTHOG_NODE_TAG=${POSTHOG_NODE_TAG:-latest}
OPT_OUT_CAPTURE=true
EOF

    echo "  已生成 .env 文件"
else
    echo "[1/4] 使用已有 .env 文件"
fi

# 下载 GeoIP 数据库（如果不存在）
echo "[2/4] 检查 GeoIP 数据库..."
mkdir -p share
if [ ! -f share/GeoLite2-City.mmdb ]; then
    echo "  下载 GeoLite2-City.mmdb..."
    if command -v brotli &> /dev/null; then
        curl -L 'https://mmdbcdn.posthog.net/' --http1.1 | brotli --decompress > share/GeoLite2-City.mmdb
    else
        echo "  安装 brotli..."
        apt-get update -qq && apt-get install -y -qq brotli > /dev/null 2>&1 || {
            echo "  警告: 无法安装 brotli，跳过 GeoIP 下载。"
            echo "  请手动下载: curl -L 'https://mmdbcdn.posthog.net/' --http1.1 | brotli --decompress > share/GeoLite2-City.mmdb"
        }
        if command -v brotli &> /dev/null; then
            curl -L 'https://mmdbcdn.posthog.net/' --http1.1 | brotli --decompress > share/GeoLite2-City.mmdb
        fi
    fi
    if [ -f share/GeoLite2-City.mmdb ]; then
        echo "  GeoIP 数据库下载完成"
    fi
else
    echo "  GeoIP 数据库已存在"
fi

# 确保 compose 脚本可执行
chmod +x compose/*

# 启动服务
echo "[3/4] 启动 PostHog 服务..."
echo "  拉取镜像并启动容器（首次可能需要较长时间）..."
$COMPOSE_CMD up -d

# 健康检查
echo "[4/4] 等待服务就绪..."
echo "  PostHog 首次启动需要 5-10 分钟（数据库迁移）"
echo "  按 Ctrl+C 可跳过等待（服务会在后台继续启动）"

TIMEOUT=600
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/_health 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo ""
        echo "=== 安装完成! ==="
        # 从 .env 读取 DOMAIN
        source .env
        echo "访问地址: ${SITE_URL_SCHEME:-http}://${DOMAIN}"
        echo ""
        echo "常用命令:"
        echo "  查看状态:  $COMPOSE_CMD ps"
        echo "  查看日志:  $COMPOSE_CMD logs -f web"
        echo "  停止服务:  $COMPOSE_CMD stop"
        echo "  启动服务:  $COMPOSE_CMD start"
        echo "  重启服务:  $COMPOSE_CMD restart"
        exit 0
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    printf "\r  已等待 %ds / %ds..." "$ELAPSED" "$TIMEOUT"
done

echo ""
echo "警告: 健康检查超时（${TIMEOUT}s），但服务可能仍在启动中。"
echo "请运行以下命令查看日志:"
echo "  $COMPOSE_CMD logs web"
echo "  $COMPOSE_CMD logs worker"
