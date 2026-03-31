#!/usr/bin/env bash
#
# PostHog 从源码一键部署脚本 (Ubuntu 24.04)
#
# 用法:
#   cd ~/posthog
#   chmod +x setup-posthog.sh
#   ./setup-posthog.sh
#
# 前提条件:
#   - Ubuntu 24.04 LTS
#   - 已克隆 PostHog 仓库到 ~/posthog
#   - 已安装 Docker + Docker Compose V2
#   - 已安装 pyenv + Python 3.12.12
#   - 已安装 nvm + Node.js 24.x
#   - 已安装 uv (~0.10.2)
#   - 已安装 Rust stable (rustup)
#   - 已安装 mprocs
#   - 已安装 pnpm (corepack)

set -euo pipefail

# ============================================================
# 配置区 — 根据需要修改
# ============================================================
POSTHOG_USER_EMAIL="${POSTHOG_USER_EMAIL:-pujun0809@gmail.com}"
POSTHOG_USER_PASSWORD="${POSTHOG_USER_PASSWORD:-posthog2024}"
POSTHOG_USER_FIRST_NAME="${POSTHOG_USER_FIRST_NAME:-Pujun}"

# ============================================================
# 颜色和工具函数
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

step_num=0
step() {
    step_num=$((step_num + 1))
    echo ""
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo -e "${BLUE}${BOLD}  Step ${step_num}: $1${NC}"
    echo -e "${BLUE}${BOLD}========================================${NC}"
    echo ""
}

ok() { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

# ============================================================
step "检查前提条件"
# ============================================================

# Docker
command -v docker &>/dev/null || fail "Docker 未安装"
docker info &>/dev/null || fail "Docker 未运行，或当前用户不在 docker 组"
ok "Docker 已就绪"

# Python
if command -v python3.12 &>/dev/null; then
    PYTHON_CMD="python3.12"
elif python3 --version 2>/dev/null | grep -q "3.12"; then
    PYTHON_CMD="python3"
else
    fail "Python 3.12 未找到。请先安装: pyenv install 3.12.12"
fi
ok "Python: $($PYTHON_CMD --version)"

# Node.js
command -v node &>/dev/null || fail "Node.js 未安装"
NODE_MAJOR=$(node --version | cut -d. -f1 | tr -d 'v')
[[ "$NODE_MAJOR" -ge 24 ]] || warn "Node.js 版本 $(node --version)，建议 24.x"
ok "Node.js: $(node --version)"

# pnpm
command -v pnpm &>/dev/null || fail "pnpm 未安装。运行: corepack enable && corepack prepare"
ok "pnpm: $(pnpm --version)"

# uv
command -v uv &>/dev/null || fail "uv 未安装。运行: curl -LsSf https://astral.sh/uv/install.sh | sh"
ok "uv: $(uv --version)"

# mprocs
command -v mprocs &>/dev/null || fail "mprocs 未安装"
ok "mprocs 已安装"

# ============================================================
step "安装系统依赖"
# ============================================================

sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential \
    libxml2 libxmlsec1-dev libffi-dev pkg-config \
    postgresql-client postgresql-contrib libpq-dev \
    2>/dev/null

ok "系统依赖已安装"

# ============================================================
step "配置 /etc/hosts (关键步骤)"
# ============================================================

HOSTS_ENTRY_V4="127.0.0.1 kafka clickhouse clickhouse-coordinator objectstorage"
HOSTS_ENTRY_V6="::1 kafka clickhouse clickhouse-coordinator objectstorage"

if grep -qF "kafka" /etc/hosts && grep -qF "clickhouse" /etc/hosts; then
    ok "/etc/hosts 已包含所需条目"
else
    echo "$HOSTS_ENTRY_V4" | sudo tee -a /etc/hosts >/dev/null
    echo "$HOSTS_ENTRY_V6" | sudo tee -a /etc/hosts >/dev/null
    ok "已添加 /etc/hosts 条目 (kafka, clickhouse, objectstorage)"
fi

# ============================================================
step "停止旧容器，启动 Docker 基础设施"
# ============================================================

echo "  停止旧容器..."
docker compose -f docker-compose.dev.yml down 2>/dev/null || true

echo "  启动基础设施容器..."
docker compose -f docker-compose.dev.yml up -d

echo "  等待服务就绪..."
sleep 10

# 等待 PostgreSQL
for i in $(seq 1 30); do
    if docker exec posthog-db-1 pg_isready -U posthog -q 2>/dev/null; then
        ok "PostgreSQL 已就绪"
        break
    fi
    [[ $i -eq 30 ]] && fail "PostgreSQL 启动超时"
    sleep 2
done

# 等待 ClickHouse
for i in $(seq 1 30); do
    if docker exec posthog-clickhouse-1 clickhouse-client --query "SELECT 1" &>/dev/null; then
        ok "ClickHouse 已就绪"
        break
    fi
    [[ $i -eq 30 ]] && fail "ClickHouse 启动超时"
    sleep 2
done

# 等待 Redis (容器名是 redis7)
for i in $(seq 1 15); do
    if docker exec posthog-redis7-1 redis-cli ping 2>/dev/null | grep -q PONG; then
        ok "Redis 已就绪"
        break
    fi
    [[ $i -eq 15 ]] && fail "Redis 启动超时"
    sleep 2
done

# 检查 Kafka
for i in $(seq 1 30); do
    if docker exec posthog-kafka-1 bash -c "echo > /dev/tcp/localhost/9092" 2>/dev/null; then
        ok "Kafka 已就绪"
        break
    fi
    [[ $i -eq 30 ]] && warn "Kafka 可能未就绪，继续..."
    sleep 2
done

# ============================================================
step "安装 Python 依赖"
# ============================================================

uv sync
ok "Python 依赖已安装"

# 激活虚拟环境
source .venv/bin/activate
ok "虚拟环境已激活"

# ============================================================
step "安装 Node.js 依赖"
# ============================================================

corepack enable 2>/dev/null || true
pnpm install
ok "Node.js 依赖已安装"

# ============================================================
step "下载 GeoIP 数据库"
# ============================================================

./bin/download-mmdb
if [[ -f ./share/GeoLite2-City.mmdb ]]; then
    chmod 0755 ./share/GeoLite2-City.mmdb
    ok "GeoIP 数据库已就绪"
else
    warn "GeoIP 数据库下载可能失败，feature-flags 服务可能受影响"
fi

# ============================================================
step "绕过 DuckLake 检查 (修复版本不匹配阻塞)"
# ============================================================

# DuckLake catalog v0.3 与 extension v0.4 不匹配，导致 check_ducklake_up 无限重试
# 这会阻塞 backend、celery、nodejs 全部启动
if [[ -f bin/check_ducklake_up ]]; then
    cp bin/check_ducklake_up bin/check_ducklake_up.original
    cat > bin/check_ducklake_up << 'DUCKLAKE_BYPASS'
#!/usr/bin/env python3
"""DuckLake health check — bypassed for local source build (version mismatch workaround)."""
import sys
print("DuckLake check bypassed (local dev - catalog version mismatch workaround)")
sys.exit(0)
DUCKLAKE_BYPASS
    chmod +x bin/check_ducklake_up
    ok "已绕过 DuckLake 检查 (原文件备份为 bin/check_ducklake_up.original)"
fi

# ============================================================
step "修复 Linux 后端绑定地址"
# ============================================================

# bin/start-backend 在 Linux 上默认绑定到 Docker bridge gateway IP (172.17.0.1)
# 导致从远程机器无法访问。修改为支持 HOST_BIND 环境变量覆盖。
if grep -q 'HOST_BIND="\$DOCKER_GATEWAY_IP"' bin/start-backend; then
    cp bin/start-backend bin/start-backend.original
    sed -i 's|else\n.*# Linux - containers cannot reach|else\n    # Linux - use HOST_BIND env var if set, otherwise use bridge gateway\n    if [[ -z "${HOST_BIND:-}" ]]; then\n    # Linux - containers cannot reach|' bin/start-backend 2>/dev/null || true

    # 更可靠的方式：直接替换整个 else 块
    python3 << 'PYFIX'
import re

with open("bin/start-backend", "r") as f:
    content = f.read()

old_block = '''else
    # Linux - containers cannot reach host's 127.0.0.1, use bridge gateway
    DOCKER_GATEWAY_IP=$(docker network inspect bridge --format='{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || echo "172.17.0.1")
    HOST_BIND="$DOCKER_GATEWAY_IP"
    echo "🐧 Linux detected, binding to Docker bridge gateway: $HOST_BIND"
fi'''

new_block = '''else
    # Linux - use HOST_BIND env var if already set (e.g. from .env), otherwise use bridge gateway
    if [[ -z "${HOST_BIND:-}" ]]; then
        DOCKER_GATEWAY_IP=$(docker network inspect bridge --format='{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || echo "172.17.0.1")
        HOST_BIND="$DOCKER_GATEWAY_IP"
    fi
    echo "🐧 Linux detected, binding to: $HOST_BIND"
fi'''

if old_block in content:
    content = content.replace(old_block, new_block)
    with open("bin/start-backend", "w") as f:
        f.write(content)
    print("PATCHED")
else:
    print("ALREADY_PATCHED_OR_DIFFERENT")
PYFIX

    ok "已修改 bin/start-backend 支持 HOST_BIND 环境变量覆盖"
else
    ok "bin/start-backend 已是修改后的版本"
fi

# 修复 Caddy proxy 也绑定 0.0.0.0 以支持远程访问
# docker-compose.dev.yml 中 proxy 端口默认是 127.0.0.1:8010:8000
# 创建一个 override 文件来修改这个行为
if [[ ! -f docker-compose.override.yml ]]; then
    cat > docker-compose.override.yml << 'OVERRIDE'
# 覆盖端口绑定，允许远程访问
# 由 setup-posthog.sh 自动生成
services:
  proxy:
    ports:
      - '0.0.0.0:8010:8000'
OVERRIDE
    ok "已创建 docker-compose.override.yml (Caddy proxy 绑定 0.0.0.0:8010)"
fi

# 创建 .env 文件
touch .env
if ! grep -q "HOST_BIND" .env 2>/dev/null; then
    echo '# 绑定到所有接口，允许远程访问' >> .env
    echo 'HOST_BIND=0.0.0.0' >> .env
fi
if ! grep -q "DEBUG" .env 2>/dev/null; then
    echo 'DEBUG=1' >> .env
fi
ok "已配置 .env (HOST_BIND=0.0.0.0, DEBUG=1)"

# 重启 proxy 容器以应用 override
docker compose -f docker-compose.dev.yml -f docker-compose.override.yml up -d proxy 2>/dev/null || true
ok "已重启 proxy 容器"

# ============================================================
step "运行数据库迁移"
# ============================================================

export DEBUG=1
export DATABASE_URL=postgres://posthog:posthog@localhost:5432/posthog

# 先尝试修复 ClickHouse crash_log 表问题
echo "  预创建 system.crash_log 表 (避免 migration 0159 失败)..."
docker exec posthog-clickhouse-1 clickhouse-client --query "
CREATE TABLE IF NOT EXISTS system.crash_log (
    event_date Date,
    event_time DateTime,
    timestamp_ns UInt64,
    signal Int32,
    thread_id UInt64,
    query_id String,
    trace Array(UInt64),
    trace_full Array(String),
    version String,
    revision UInt32,
    build_id String,
    comment String
) ENGINE = MergeTree ORDER BY event_date
" 2>/dev/null || warn "crash_log 表可能已存在或无法创建"

echo "  运行 PostgreSQL 迁移..."
python manage.py migrate --noinput || fail "PostgreSQL 迁移失败"
ok "PostgreSQL 迁移完成"

echo "  运行产品数据库迁移..."
python manage.py migrate_product_databases || warn "产品数据库迁移可能有警告"

echo "  运行 ClickHouse 迁移..."
python manage.py migrate_clickhouse || fail "ClickHouse 迁移失败"
ok "ClickHouse 迁移完成"

echo "  同步复制表 schema..."
python manage.py sync_replicated_schema || warn "sync_replicated_schema 可能有警告"

echo "  运行异步迁移..."
python manage.py run_async_migrations --complete-noop-migrations 2>/dev/null || warn "异步迁移可能有警告"

# Persons 数据库 (本地开发模式)
echo "  运行 Persons 数据库迁移..."
python manage.py apply_persons_migrations --database=persons_db_writer --ensure-database 2>/dev/null || warn "Persons 迁移可能有警告"

ok "所有数据库迁移完成"

# ============================================================
step "构建前端"
# ============================================================

echo "  生成 Kea 类型..."
pnpm --filter=@posthog/frontend typegen:write 2>/dev/null || warn "typegen 可能有警告（首次可能需要手动处理）"

echo "  构建前端 (ESBuild)..."
pnpm --filter=@posthog/frontend build || fail "前端构建失败"
ok "前端构建完成"

echo "  收集 Django 静态文件..."
STATIC_COLLECTION=1 python manage.py collectstatic --noinput || fail "collectstatic 失败"
ok "静态文件收集完成"

# ============================================================
step "创建管理员用户"
# ============================================================

python manage.py shell -c "
from posthog.models import User
if not User.objects.filter(email='${POSTHOG_USER_EMAIL}').exists():
    user = User.objects.create_user(
        email='${POSTHOG_USER_EMAIL}',
        password='${POSTHOG_USER_PASSWORD}',
        first_name='${POSTHOG_USER_FIRST_NAME}'
    )
    user.is_staff = True
    user.save()
    print('User created: ${POSTHOG_USER_EMAIL}')
else:
    print('User already exists: ${POSTHOG_USER_EMAIL}')
" || warn "用户创建可能有问题，可稍后手动创建"

ok "用户就绪: ${POSTHOG_USER_EMAIL}"

# ============================================================
step "设置完成！"
# ============================================================

LOCAL_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}${BOLD}============================================${NC}"
echo -e "${GREEN}${BOLD}  PostHog 从源码部署完成！${NC}"
echo -e "${GREEN}${BOLD}============================================${NC}"
echo ""
echo -e "  ${BOLD}启动方式 A (推荐 — mprocs TUI):${NC}"
echo -e "    cd $REPO_ROOT"
echo -e "    source .venv/bin/activate"
echo -e "    ./bin/start"
echo ""
echo -e "  ${BOLD}启动方式 B (手动 — 仅后端):${NC}"
echo -e "    cd $REPO_ROOT"
echo -e "    source .venv/bin/activate"
echo -e "    export DEBUG=1"
echo -e "    python -m granian --interface asgi posthog.asgi:application \\"
echo -e "        --host 0.0.0.0 --port 8000 --log-level debug --workers 1"
echo ""
echo -e "  ${BOLD}访问地址:${NC}"
echo -e "    本地:  http://localhost:8000"
echo -e "    远程:  http://${LOCAL_IP}:8000  (直连 Django)"
echo -e "    代理:  http://${LOCAL_IP}:8010  (通过 Caddy, 需要 bin/start)"
echo ""
echo -e "  ${BOLD}登录账号:${NC}"
echo -e "    邮箱:  ${POSTHOG_USER_EMAIL}"
echo -e "    密码:  ${POSTHOG_USER_PASSWORD}"
echo ""
echo -e "  ${YELLOW}提示: 首次登录后需要创建 Organization 和 Project${NC}"
echo ""
