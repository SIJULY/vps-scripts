#!/bin/bash
# =================================================================
# 服务器开机一键初始化脚本（精简版）
# 只部署三个挂机容器：TM、Repocket、EarnFM
# 其他（SSH/Root 改密、BBR、X-UI、Xray）已全部删除
#
# 一键运行：
#   bash <(curl -sL https://raw.githubusercontent.com/SIJULY/vps-scripts/main/init.sh)
# =================================================================

if [ "$EUID" -ne 0 ]; then
    echo "正在申请 Root 权限..."
    exec sudo bash "$0" "$@"
fi

echo "===== 开始执行开机初始化脚本: $(date) ====="

# 挂机容器凭据
RP_EMAIL="sijuly@outlook.com"
RP_API_KEY="60725bcd-b4ff-4e1d-b254-e8fc6cfdf2dc"
TM_TOKEN="WovlB9V4nql+H2MQ1FAcv6HBgy5plSrA/VRv4S25d+c="
EARNFM_TOKEN="ce203a4c-627b-4b44-934d-58689ca6cf7f"

# ==================== 等待网络就绪 ====================
WAIT_COUNT=0; MAX_WAIT=12; PING_TARGET="8.8.8.8"
until ping -c 1 "$PING_TARGET" &>/dev/null; do
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then echo "警告：网络未就绪，仍继续尝试拉取镜像"; break; fi
    echo "网络未就绪，等待 5 秒... ($((WAIT_COUNT+1))/$MAX_WAIT)"; sleep 5
    WAIT_COUNT=$((WAIT_COUNT+1))
done

# ==================== 安装 Docker ====================
if ! command -v docker &>/dev/null; then
    echo "Docker 未安装，开始安装..."
    if command -v apt-get &>/dev/null; then
        apt-get update -y && apt-get install -y curl
    elif command -v yum &>/dev/null; then
        yum install -y curl
    fi
    curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh
    rm -f get-docker.sh
    systemctl start docker && systemctl enable docker || true
fi

cleanup_container() {
    local name=$1 image=$2
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${name}$"; then
        docker stop "$name" >/dev/null 2>&1 || true; docker rm "$name" >/dev/null 2>&1 || true
    fi
    local old_ids=$(docker ps -a -q --filter "ancestor=${image}")
    if [ -n "$old_ids" ]; then
        for id in $old_ids; do docker stop "$id" >/dev/null 2>&1 || true; docker rm "$id" >/dev/null 2>&1 || true; done
    fi
}

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then TM_IMAGE="traffmonetizer/cli_v2:latest"
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then TM_IMAGE="traffmonetizer/cli_v2:arm64v8"
else TM_IMAGE="traffmonetizer/cli_v2:latest"; fi

# 启动一个容器：拉取失败或启动后未运行，重试一次；单个容器失败不影响其他两个
FAILED=""
start_container() {
    local name=$1 image=$2; shift 2
    echo ">>> 部署 $name ..."
    cleanup_container "$name" "$image"
    local attempt=1
    while [ $attempt -le 2 ]; do
        if docker pull "$image" && docker run -d --restart=always --name "$name" "$@" "$image"; then
            sleep 5
            if [ "$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)" = "running" ]; then
                echo "$name: 运行中"
                return 0
            fi
            echo "$name: 启动后未运行，重试 ($attempt/2)..."
        else
            echo "$name: 拉取/启动失败，重试 ($attempt/2)..."
        fi
        docker rm -f "$name" >/dev/null 2>&1 || true
        attempt=$((attempt+1))
    done
    echo "$name: 失败，请检查 Token 与 docker logs $name"
    FAILED="$FAILED $name"
    return 1
}

# 注意：start_container 的 docker run 参数里，最后一个镜像名由函数追加，
# tm 需要把镜像后的启动参数放在镜像名之前，所以 tm 单独处理
echo ">>> 部署 tm ..."
cleanup_container "tm" "$TM_IMAGE"
attempt=1
while [ $attempt -le 2 ]; do
    if docker pull "$TM_IMAGE" && docker run -d --restart=always --name tm "$TM_IMAGE" start accept --token "$TM_TOKEN"; then
        sleep 5
        if [ "$(docker inspect -f '{{.State.Status}}' tm 2>/dev/null)" = "running" ]; then echo "tm: 运行中"; break; fi
        echo "tm: 启动后未运行，重试 ($attempt/2)..."
    else
        echo "tm: 拉取/启动失败，重试 ($attempt/2)..."
    fi
    docker rm -f tm >/dev/null 2>&1 || true
    attempt=$((attempt+1))
    if [ $attempt -gt 2 ]; then echo "tm: 失败，请检查 Token 与 docker logs tm"; FAILED="$FAILED tm"; fi
done

start_container "repocket" "repocket/repocket" -e RP_EMAIL="$RP_EMAIL" -e RP_API_KEY="$RP_API_KEY" || true
start_container "earnfm-client" "earnfm/earnfm-client:latest" -e EARNFM_TOKEN="$EARNFM_TOKEN" || true

# ==================== 校验三个容器 ====================
echo ""
echo "=================================================="
docker ps -a --format '{{.Names}} {{.Status}} {{.Image}}'
echo "=================================================="
MISSING=""
for c in tm repocket earnfm-client; do
    if [ "$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)" != "running" ]; then MISSING="$MISSING $c"; fi
done
if [ -n "$MISSING" ]; then
    echo "❌ 未运行的容器:$MISSING"
    echo "===== 脚本完成时间: $(date) ====="
    exit 1
fi
echo "✅ 三个容器全部运行中：tm、repocket、earnfm-client"
echo "===== 脚本完成时间: $(date) ====="
exit 0
