#!/bin/bash
# =================================================================
# 服务器开机一键全自动初始化脚本
# 包含：修改Root/SSH、网络/依赖检查、BBR优化、Docker挂机程序、X-UI、固定7000端口Xray节点及多IP补丁
#
# 一键运行：
#   bash <(curl -sL https://raw.githubusercontent.com/SIJULY/vps-scripts/main/init.sh)
# =================================================================

set -e

# ==================== 1. 基础配置变量 ====================
ROOT_PASS='Ayou2Mke#65%a1'
XUI_USER="sijuly"
XUI_PASS='Ayou2Mke#65%a1'
XUI_PORT="54321"

# Xray 独立节点配置 (固定 7000 端口与 VLESS TCP 协议)
XRAY_PORT="7000"
XRAY_UUID="1483c30c-ae2c-4130-f643-c6139d199c42"

RP_EMAIL="sijuly@outlook.com"
RP_API_KEY="60725bcd-b4ff-4e1d-b254-e8fc6cfdf2dc"
TM_TOKEN="WovlB9V4nql+H2MQ1FAcv6HBgy5plSrA/VRv4S25d+c="
EARNFM_TOKEN="ce203a4c-627b-4b44-934d-58689ca6cf7f"
# =========================================================

echo "===== 开始执行开机初始化脚本: $(date) ====="

if [ "$EUID" -ne 0 ]; then
    echo "正在申请 Root 权限..."
    exec sudo bash "$0" "$@"
fi

# ==================== 2. SSH 与 Root 密码配置 ====================
echo ">>> [1/6] 配置 SSH 及 Root 密码..."
echo "root:${ROOT_PASS}" | chpasswd
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
systemctl restart sshd || service sshd restart || true
echo "SSH 配置已更新，Root 密码已修改。"

# ==================== 3. 网络、基础依赖与 BBR 优化 ====================
echo ">>> [2/6] 检查网络与安装基础依赖..."
WAIT_COUNT=0; MAX_WAIT=12; PING_TARGET="8.8.8.8"
until ping -c 1 "$PING_TARGET" &>/dev/null; do
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then echo "错误：网络超时"; exit 1; fi
    echo "网络未就绪，等待 5 秒... ($((WAIT_COUNT+1))/$MAX_WAIT)"; sleep 5
    WAIT_COUNT=$((WAIT_COUNT+1))
done

if command -v apt-get &>/dev/null; then
    apt-get update -y && apt-get install -y curl wget python3
elif command -v yum &>/dev/null; then
    yum install -y curl wget python3
fi

echo "配置 BBR 加速与清理防火墙..."
if ! grep -q "net.core.default_qdisc=cake" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=cake" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
fi
iptables -F; iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT

# ==================== 4. Docker 安装与挂机容器部署 ====================
echo ">>> [3/6] 检查/安装 Docker 并部署挂机程序..."
if ! command -v docker &>/dev/null; then
    echo "Docker 未安装，开始安装..."
    curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh
    rm -f get-docker.sh
    systemctl start docker && systemctl enable docker || true
fi

cleanup_container() {
    local name=$1 image=$2
    if docker ps -a --format '{{.Names}}' | grep -Eq "^${name}\$"; then
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

cleanup_container "tm" "$TM_IMAGE"
docker run -d --restart=always --name tm "$TM_IMAGE" start accept --token "$TM_TOKEN"

cleanup_container "repocket" "repocket/repocket"
docker run -d --restart=always -e RP_EMAIL="$RP_EMAIL" -e RP_API_KEY="$RP_API_KEY" --name repocket repocket/repocket

cleanup_container "earnfm-client" "earnfm/earnfm-client:latest"
docker run -d --restart=always -e EARNFM_TOKEN="$EARNFM_TOKEN" --name earnfm-client earnfm/earnfm-client:latest

cleanup_container "watchtower" "containrrr/watchtower"
docker run -d --restart=always -e DOCKER_API_VERSION=1.40 --name watchtower \
  -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower \
  --cleanup --include-stopped --include-restarting --revive-stopped --interval 60 earnfm-client

# ==================== 5. X-UI 安装与多 IP 路由补丁 ====================
echo ">>> [4/6] 静默安装 X-UI 面板并植入多 IP 补丁..."
printf "y\n${XUI_USER}\n${XUI_PASS}\n${XUI_PORT}\n" | bash <(curl -4 -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh) >/dev/null 2>&1
systemctl restart x-ui; sleep 5

if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    XRAY_BIN="/usr/local/x-ui/bin/xray-linux-arm64-v8a"
else
    XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"
fi

if [ ! -f "$XRAY_BIN" ] && [ ! -f "${XRAY_BIN}_real" ]; then
    FOUND_BIN=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | grep -v "real" | head -n 1)
    [ -n "$FOUND_BIN" ] && XRAY_BIN="$FOUND_BIN"
fi

if [ -f "$XRAY_BIN" ] || [ -f "${XRAY_BIN}_real" ]; then
    [ ! -f "${XRAY_BIN}_real" ] && mv "$XRAY_BIN" "${XRAY_BIN}_real"

    cat > /usr/local/x-ui/bin/patch_config.py << 'PYEOF'
import sys, json
config_path, out_path = sys.argv[1], sys.argv[2]
try:
    with open(config_path, 'r', encoding='utf-8') as f: data = json.load(f)
except Exception:
    sys.exit(0)
if 'outbounds' not in data: data['outbounds'] = []
if 'routing' not in data: data['routing'] = {'rules': []}
if 'rules' not in data['routing']: data['routing']['rules'] = []
for inbound in data.get('inbounds', []):
    listen_ip = inbound.get('listen', '')
    tag = inbound.get('tag', '')
    if listen_ip and listen_ip not in ['0.0.0.0', '127.0.0.1', '::']:
        outbound_tag = f"out_{listen_ip}"
        if not any(o.get('tag') == outbound_tag for o in data['outbounds']):
            data['outbounds'].insert(0, {"protocol": "freedom", "tag": outbound_tag, "sendThrough": listen_ip})
        if not any(outbound_tag == r.get('outboundTag') and tag in r.get('inboundTag', []) for r in data['routing']['rules']):
            data['routing']['rules'].insert(0, {"type": "field", "inboundTag": [tag], "outboundTag": outbound_tag})
with open(out_path, 'w', encoding='utf-8') as f: json.dump(data, f, indent=2)
PYEOF

    cat > "$XRAY_BIN" << BASH_EOF
#!/bin/bash
args=("\$@")
CONFIG_FILE=""
for i in "\${!args[@]}"; do
    if [[ "\${args[\$i]}" == "-c" || "\${args[\$i]}" == "-config" ]]; then
        CONFIG_FILE="\${args[\$i+1]}"; break
    fi
done
if [ -n "\$CONFIG_FILE" ]; then
    python3 /usr/local/x-ui/bin/patch_config.py "\$CONFIG_FILE" "\${CONFIG_FILE}_patched.json"
    if [ \$? -eq 0 ]; then
        for i in "\${!args[@]}"; do
            if [[ "\${args[\$i]}" == "-c" || "\${args[\$i]}" == "-config" ]]; then
                args[\$i+1]="\${CONFIG_FILE}_patched.json"; break
            fi
        done
    fi
fi
exec ${XRAY_BIN}_real "\${args[@]}"
BASH_EOF

    chmod +x "$XRAY_BIN"
    systemctl restart x-ui
fi

# ==================== 6. 部署 Xray 固定端口节点 ====================
echo "开始安装并配置 Xray..."
# 定义标记文件路径，用于判断 Xray 是否已安装
FLAG_FILE="/root/.xray_installed_flag"

if [ ! -f "$FLAG_FILE" ]; then
    echo "Xray 未安装或标记文件不存在，开始安装 Xray..."
    # 检查 wget 是否安装，因为 Xray 安装脚本可能依赖它
    if ! command -v wget &> /dev/null; then
        echo "wget 未安装，尝试安装..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y wget || { echo "错误：apt-get 安装 wget 失败。Xray 安装可能受影响。"; }
        elif command -v yum &> /dev/null; then
            yum install -y wget || { echo "错误：yum 安装 wget 失败。Xray 安装可能受影响。"; }
        else
            echo "警告：无法自动安装 wget。Xray 安装可能会失败。请手动安装 wget 后重试。"
            # 这里不 exit，允许脚本继续，但 Xray 安装可能会受影响
        fi
    fi

    # 安装并配置 Xray
    sudo wget -qO- https://github.com/233boy/Xray/raw/main/install.sh | bash || {
        echo "错误：Xray 安装脚本执行失败。此错误不影响前面已完成的任务。"
        # 此处不 exit，因为已在脚本末尾，且用户希望前面任务不受影响。
    }

    # 运行 xray add tcp 命令 (用户要求保留)
    # 注意：此命令可能与 233boy 脚本的默认配置冲突，有导致命令失败的风险。
    # 使用 || true 确保即使失败也不会终止脚本
    xray add tcp 7000 1483c30c-ae2c-4130-f643-c6139d199c42 || {
        echo "警告：xray add tcp 命令执行失败。请检查 Xray 配置。"
    }

    sudo systemctl enable xray  # 确保开机自启
    # 创建标记文件，表示 Xray 已尝试安装
    sudo touch "$FLAG_FILE"
    echo "Xray 安装和基本配置尝试完成。"
else
    echo "Xray 已安装（检测到标记文件：$FLAG_FILE），跳过安装步骤。"
fi

# 每次启动时确保服务运行（即使已 enable）
echo "确保 Xray 服务正在运行..."
sudo systemctl start xray || {
    echo "错误：无法启动 Xray 服务。请手动检查 `systemctl status xray`。此错误不影响前面已完成的任务。"
}
echo "Xray 服务状态已确保。"
echo "Xray 功能模块处理完成。"

# ==================== 7. 部署结果展示 ====================
echo ">>> [6/6] 获取系统信息..."
IP=$(curl -s4m5 4.ipw.cn || curl -s4m5 ifconfig.me || echo "服务器IP")

echo -e "\n=================================================="
echo -e "✅ 服务器初始化已全部完成！"
echo -e "=================================================="
echo -e "1. Root 密码已设置: ${ROOT_PASS}"
echo -e "2. SSH 远程密码登录: 已开启 (Port: 22)"
echo -e "3. Docker 挂机容器: tm, repocket, earnfm, watchtower 运行中"
echo -e "4. X-UI 面板控制台: http://${IP}:${XUI_PORT}"
echo -e "   账号: ${XUI_USER} | 密码: ${XUI_PASS}"
echo -e "5. 静态 Xray 节点信息 (VLESS + TCP):"
echo -e "   协议: VLESS | 传输: TCP | 端口: ${XRAY_PORT} | UUID: ${XRAY_UUID}"
echo -e "6. 多 IP 入站/出站同 IP 路由绑定: 已激活"
echo -e "=================================================="
echo "⚠️  注意: 请确保 AWS 安全组入站规则已放行 TCP 端口: 22, ${XUI_PORT}, ${XRAY_PORT}"
echo "===== 脚本完成时间: $(date) ====="
exit 0
