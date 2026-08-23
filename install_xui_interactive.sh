#!/bin/bash
# ==========================================
# X-UI 面板安装 + 多 IP 路由补丁 (交互式安装版)
# ==========================================

echo -e "\033[36m>>> 开始安装 X-UI 面板及路由补丁 (交互模式)...\033[0m"

# 1. 检查权限
[ "$EUID" -ne 0 ] && echo "请用 root 运行" && exit 1

# 2. 安装依赖
command -v curl >/dev/null 2>&1 || (apt-get update && apt-get install -y curl || yum install -y curl)
command -v python3 >/dev/null 2>&1 || (apt-get update -y && apt-get install -y python3)

# 3. 安装原版 X-UI (交互式)
echo -e "\033[33m即将运行官方 X-UI 安装脚本，请根据提示设置账号密码和端口：\033[0m"
bash <(curl -4 -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh)

if [ $? -ne 0 ]; then
    echo -e "\033[31m安装 X-UI 失败，脚本退出。\033[0m"
    exit 1
fi

# 确保面板已拉起
systemctl restart x-ui
sleep 5

# 4. 植入自动化补丁
XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"
if [ ! -f "$XRAY_BIN" ] && [ ! -f "${XRAY_BIN}_real" ]; then
    echo -e "\033[31m警告: 未找到 Xray 核心，补丁植入跳过。\033[0m"
    exit 1
fi

echo -e "\033[36m正在植入自动化路由补丁...\033[0m"
if [ ! -f "${XRAY_BIN}_real" ]; then
    mv "$XRAY_BIN" "${XRAY_BIN}_real"
fi

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

cat > "$XRAY_BIN" << 'BASH_EOF'
#!/bin/bash
args=("$@")
CONFIG_FILE=""
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "-c" || "${args[$i]}" == "-config" ]]; then
        CONFIG_FILE="${args[$i+1]}"
        break
    fi
done

if [ -n "$CONFIG_FILE" ]; then
    python3 /usr/local/x-ui/bin/patch_config.py "$CONFIG_FILE" "${CONFIG_FILE}.patched"
    if [ $? -eq 0 ]; then
        for i in "${!args[@]}"; do
            if [[ "${args[$i]}" == "-c" || "${args[$i]}" == "-config" ]]; then
                args[$i+1]="${CONFIG_FILE}.patched"
                break
            fi
        done
    fi
fi
exec /usr/local/x-ui/bin/xray-linux-amd64_real "${args[@]}"
BASH_EOF

chmod +x "$XRAY_BIN"
systemctl restart x-ui
sleep 2

echo -e "\n\033[32m✅ X-UI 面板及多 IP 自动路由补丁部署完毕！\033[0m"
echo -e "\033[33m【提示】\033[0m以后加新节点时，只要填写【监听 IP】，出口流量即可自动绑定。"
