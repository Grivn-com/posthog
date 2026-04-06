#!/bin/bash
#
# PostHog 商用版卸载脚本
#
# 用法:
#   cd posthog-deploy
#   bash uninstall.sh           # 保留数据，仅停止并移除容器
#   bash uninstall.sh --all     # 删除所有数据、镜像、配置（不可恢复）
#
set -e

echo "=== PostHog 商用版卸载 ==="
echo ""

REMOVE_ALL=false
if [[ "${1:-}" == "--all" ]]; then
    REMOVE_ALL=true
fi

# 确定 compose 命令
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo "错误: 未找到 Docker Compose"
    exit 1
fi

# 检查 compose 文件是否存在
if [ ! -f docker-compose.yml ]; then
    echo "错误: 未找到 docker-compose.yml，请在部署目录内运行此脚本"
    exit 1
fi

# 显示当前状态
echo "当前容器状态:"
$COMPOSE_CMD ps 2>/dev/null || true
echo ""

if [ "$REMOVE_ALL" = true ]; then
    echo "!!! 警告: --all 模式将永久删除所有数据 !!!"
    echo "  - PostgreSQL 数据库"
    echo "  - ClickHouse 数据"
    echo "  - Redis 缓存"
    echo "  - Kafka 消息"
    echo "  - 对象存储文件"
    echo "  - 所有 Docker 镜像"
    echo "  - .env 配置文件"
    echo ""
    read -r -p "确认删除所有数据？输入 YES 继续: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "已取消"
        exit 0
    fi
    echo ""

    echo "[1/3] 停止并移除容器和数据卷..."
    $COMPOSE_CMD down -v --remove-orphans
    echo "  完成"

    echo "[2/3] 移除 Docker 镜像..."
    $COMPOSE_CMD down --rmi all 2>/dev/null || true
    echo "  完成"

    echo "[3/3] 清理配置文件..."
    rm -f .env
    echo "  完成"
else
    echo "保留模式: 仅停止容器，保留数据卷和镜像"
    echo "  如需彻底删除，运行: bash uninstall.sh --all"
    echo ""
    read -r -p "确认停止所有 PostHog 服务？(y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
        echo "已取消"
        exit 0
    fi
    echo ""

    echo "停止并移除容器..."
    $COMPOSE_CMD down --remove-orphans
    echo "  完成"
fi

echo ""
echo "=== 卸载完成 ==="
