#!/bin/bash
# ==========================================
# X-UI 自动路由出站补丁 (多 IP/批量部署专版)
# ==========================================

XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"

echo -e "\033[36m[1/4] 检查运行环境...\033[0m"
if [ ! -f "$XRAY_BIN" ] && [ ! -f "${XRAY_BIN}_real" ]; then
    echo -e "\033[31m错误: 未找到 Xray 核心！请确保已安装 vaxilu/x-ui 面板并登录过一次。\033[0m"
    exit 1
fi

echo -e "\033[36m[2/4] 安装必要依赖...\033[0m"
command -v python3 >/dev/null 2>&1 || (apt-get update -y >/dev/null 2>&1 && apt-get install -y python3 >/dev/null 2>&1)

echo -e "\033[36m[3/4] 植入自动化补丁...\033[0m"
# 只有当 _real 备份不存在时，才重命名原生核心（防止多次运行脚本导致核心被覆盖）
if [ ! -f "${XRAY_BIN}_real" ]; then
    mv "$XRAY_BIN" "${XRAY_BIN}_real"
fi

# 生成 Python 处理器
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

# 生成 Shell 拦截器
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

echo -e "\033[36m[4/4] 正在重启面板服务...\033[0m"
systemctl restart x-ui
sleep 2

# 检查服务状态
if systemctl is-active --quiet x-ui; then
    echo -e "\n\033[32m✅ 部署成功！x-ui 服务已完美重启并加载补丁。\033[0m"
    echo -e "\033[33m【日常使用说明】\033[0m"
    echo -e "以后无论加多少新 IP，\033[36m只需在面板添加节点时填入【监听 IP】\033[0m，然后点击保存即可。"
    echo -e "面板会自动完成所有路由绑定，\033[31m无需\033[0m再执行任何重启命令！"
else
    echo -e "\n\033[31m❌ 警告: x-ui 重启可能失败，请使用 systemctl status x-ui 查看原因。\033[0m"
fi
