#!/bin/bash
# ==========================================
# X-UI 面板全自动安装 + 多 IP 路由补丁 (私用静默版)
# ==========================================

# =================配置区=================
XUI_USER="sijuly"
XUI_PASS="050148Sq$"
XUI_PORT="54321"
# =======================================

echo -e "[36m>>> 开始安装 X-UI 面板及路由补丁 (静默模式)...[0m"

# 1. 检查权限
[ "$EUID" -ne 0 ] && echo "请用 root 运行" && exit 1

# 2. 安装依赖
command -v curl >/dev/null 2>&1 || (apt-get update && apt-get install -y curl || yum install -y curl)
command -v python3 >/dev/null 2>&1 || (apt-get update -y && apt-get install -y python3)

# 3. 放行端口
if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport "$XUI_PORT" -j ACCEPT
    iptables-save > /etc/iptables.rules 2>/dev/null
fi
if command -v ufw >/dev/nulif command -v ufw >/dev/nulif command -v ufw >/dev/nulif command -v ufw >/dev/nulif comman??安装/重装 vaxilu/x-ui ..."
printf "y
${XUI_USER}
${XUI_PASS}
${XUI_PORT}
" | bash <(curl -4 -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh) >/dev/null 2>&1

if [ $? -ne 0 ]; then
    echo -e "[31m安装 X-UI 失败，脚本退出。[0m"
    exit 1
fi

# 等待面板初始拉起，确保核心文件释放
systemctl restart x-ui
sleep 5

# 5. 植入自动化补丁
XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"
if [ ! -f "$XRAY_BIN" ] && [ ! -f "${XRAY_BIN}_real" ]; then
    echo -e "[31m警告: 未找到 Xray 核心，补丁可能未生效。[0m"
    exit 1
fi

echo "正在植入自动化补丁..."
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

for inbound in data.get(inbounds, []):
    listen_ip = inbound.get(listen, )
    tag = inbound.get(tag, )
    if listen_ip and listen_ip not in ['0.0.0.0', '127.0.0.1', '::']:
        outbound_tag = f"out_{listen_ip}"
        if not any(o.get(tag) == outbound_tag for o in data['outbounds']):
            data['outbounds'].insert(0, {"protocol": "freedom", "tag": outbound_tag, "sendThrough": listen_ip})
        if not any(outbound_tag == r.get(outboundTag) and tag in r.get(inboundTag, []) for r in data['routing']['rules']):
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

# 6. 完成
IP=$(curl -s4m5 4.ipw.cn || curl -s4m5 ifconfig.me)
echo -e "
[32m✅ 全自动部署完成！[0m"
echo -e "面板登录地址: [36mhttp://${IP}:${XUI_PORT}[0m"
echo -e "账号: $XUI_USER | 密码: $XUI_PASS"
echo -e "多 IP 出站自动绑定功能已激活。"

