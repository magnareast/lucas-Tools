#!/bin/bash

# --- 颜色与全局定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 1. 严格权限拦截 (不做任何安装，仅提示) ---
if [ "$EUID" -ne 0 ]; then
    if ! command -v sudo &> /dev/null; then
        echo -e "${RED}错误：当前不是 root 用户，且系统未安装 sudo！${NC}"
        echo -e "${YELLOW}在原版纯净 Debian 中，请先输入 ${GREEN}su -${YELLOW} (注意有个短横线) 并输入 root 密码切换到超级用户，然后再执行本脚本。${NC}"
        exit 1
    fi
    echo -e "${YELLOW}正在获取管理员权限...${NC}"
    exec sudo -p "请输入当前用户的 sudo 密码: " bash "$0" "$@"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# --- 动态进度条动画引擎 ---
show_spinner() {
    local pid=$1
    local message=$2
    local frames=('.' 'o' 'O' '@' 'O' 'o')
    local num_frames=${#frames[@]}
    local start_time=$(date +%s)
    local i=0
    
    while kill -0 $pid 2>/dev/null; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        printf "\r${YELLOW}${message} ${CYAN}[%s] (${elapsed}s)${NC} " "${frames[i]}"
        i=$(( (i + 1) % num_frames ))
        sleep 0.1
    done
    wait $pid
    local status=$?
    
    if [ $status -eq 0 ]; then
        printf "\r\033[K${YELLOW}${message} ${GREEN}[✔ 完成]${NC}\n"
    else
        printf "\r\033[K${YELLOW}${message} ${RED}[✖ 失败/超时]${NC} (请查看 /tmp/lucas_error.log)\n"
    fi
    return $status
}

# --- 完美下载进度条引擎 ---
download_with_progress() {
    local url="$1"
    local file="$2"
    local title="$3"

    mkdir -p "$(dirname "$file")"

    curl -L "$url" -o "$file" 2>&1 | tr '\r' '\n' | awk -v title="$title" '
    BEGIN { fflush() }
    {
        if ($1 ~ /^[0-9]+$/) {
            percent = $1; total = $2; received = $4; time_left = $11; speed = $12
            if (total == "0") total = "未知"
            if (speed == "0") speed = "0"

            bar_len = 20
            filled = int((percent * bar_len) / 100)
            unfilled = bar_len - filled

            bar = ""
            for (i = 0; i < filled; i++) bar = bar "█"
            for (i = 0; i < unfilled; i++) bar = bar "-"

            printf "\r\033[K%s [\033[0;32m%s\033[0m] %3s%% | %s/%s | 速度: %s/s | 剩余: %s", title, bar, percent, received, total, speed, time_left
            fflush()
        }
    }
    END { print "" }'

    if [ -s "$file" ]; then return 0
    else echo -e "${RED}[✖ 失败] 下载异常或文件为空: $title${NC}"; return 1; fi
}

# --- 2. 系统环境初始化 (先盖过光盘源，再拉取缺失组件，包含 sudo) ---
init_system_env() {
    echo -e "\n${CYAN}================ 系统环境初始化 =================${NC}"

    echo -e "-> 正在智能匹配并配置清华大学 (TUNA) 镜像源，剔除光盘源干扰..."
    if ls /etc/apt/sources.list.d/*.sources >/dev/null 2>&1; then
        for f in /etc/apt/sources.list.d/*.sources; do mv "$f" "$f.bak" 2>/dev/null; done
    fi
    [ -f /etc/apt/sources.list ] && cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null

    source /etc/os-release
    if [ "$ID" == "debian" ]; then
        if [[ "$VERSION_CODENAME" == "trixie" || "$VERSION_CODENAME" == "testing" ]]; then
            cat > /etc/apt/sources.list << EOF
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ trixie main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security/ trixie-security main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ trixie-updates main contrib non-free non-free-firmware
EOF
        else
            cat > /etc/apt/sources.list << EOF
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ $VERSION_CODENAME main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ $VERSION_CODENAME-updates main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ $VERSION_CODENAME-backports main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security/ $VERSION_CODENAME-security main contrib non-free non-free-firmware
EOF
        fi
        echo -e "${GREEN}-> 已成功应用 Debian ($VERSION_CODENAME) 清华源！${NC}"
    elif [ "$ID" == "ubuntu" ]; then
        cat > /etc/apt/sources.list << EOF
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $VERSION_CODENAME main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $VERSION_CODENAME-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $VERSION_CODENAME-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $VERSION_CODENAME-security main restricted universe multiverse
EOF
        echo -e "${GREEN}-> 已成功应用 Ubuntu ($VERSION_CODENAME) 清华源！${NC}"
    fi

    dpkg --configure -a >/dev/null 2>&1

    missing_pkgs=""
    for pkg in sudo curl wget unzip iptables cron chattr ip ethtool; do
        if ! command -v $pkg &> /dev/null; then 
            if [ "$pkg" == "chattr" ]; then missing_pkgs="$missing_pkgs e2fsprogs"
            elif [ "$pkg" == "ip" ]; then missing_pkgs="$missing_pkgs iproute2"
            else missing_pkgs="$missing_pkgs $pkg"; fi
        fi
    done

    if [ -n "$missing_pkgs" ]; then
        (
            apt-get update -y --allow-releaseinfo-change >/tmp/lucas_error.log 2>&1
            apt-get install -y $missing_pkgs < /dev/null >>/tmp/lucas_error.log 2>&1
        ) &
        show_spinner $! "正在极速拉取并安装缺失组件 (含 sudo 等): ${CYAN}${missing_pkgs}${NC}"
    else
        echo -e "-> 核心组件状态: ${GREEN}全部就绪${NC}"
    fi
    echo -e "${CYAN}=================================================${NC}\n"
    sleep 1
}

init_system_env

# --- 3. 自动将普通用户加入 sudo 组 ---
if [ -z "$SUDO_USER" ] && [ "$USER" == "root" ]; then
    REAL_USER=$(awk -F':' '{if ($3 >= 1000 && $3 < 60000) print $1}' /etc/passwd | head -n 1)
    if [ -n "$REAL_USER" ]; then
        if ! groups "$REAL_USER" 2>/dev/null | grep -q '\bsudo\b'; then
            echo -e "${CYAN}================ 账号权限优化 =================${NC}"
            echo -e "检测到普通用户 [${GREEN}$REAL_USER${NC}] 未拥有 sudo 权限。"
            echo -e "已自动将 $REAL_USER 加入管理员组！"
            usermod -aG sudo "$REAL_USER"
            echo -e "${YELLOW}下次 SSH 登录时，你可以直接使用普通用户并配合 sudo 执行高权限指令了。${NC}"
            echo -e "${CYAN}=================================================${NC}\n"
            sleep 2
        fi
    fi
fi

# --- 临时网关安全防护机制 ---
TEMP_GW_SET=false
TEMP_ORIG_GW=""

restore_temp_gw() {
    if [ "$TEMP_GW_SET" = true ]; then
        echo -e "\n${YELLOW}正在恢复系统真实网关...${NC}"
        if [ -n "$TEMP_ORIG_GW" ]; then ip route replace default via "$TEMP_ORIG_GW" 2>/dev/null
        else ip route del default 2>/dev/null; fi
        
        chattr -i /etc/resolv.conf 2>/dev/null
        [ -f /tmp/resolv.conf.bak ] && mv /tmp/resolv.conf.bak /etc/resolv.conf 2>/dev/null
        chattr +i /etc/resolv.conf 2>/dev/null
        
        echo -e "${GREEN}系统真实网关已恢复！${NC}"
        TEMP_GW_SET=false
    fi
}
trap restore_temp_gw EXIT INT TERM

setup_temp_gw() {
    while true; do
        echo -e "\n${CYAN}--- 下载加速 (借道超车) ---${NC}"
        read -p "请输入可翻墙的临时网关IP (直接回车跳过并使用当前网络): " temp_gw
        if [ -z "$temp_gw" ]; then return 0; fi
        if [[ ! "$temp_gw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo -e "${RED}IP 格式错误！${NC}"; continue; fi

        ORIG_GW=$(ip -4 route show default | grep -v "mihomo" | awk '/default/ {print $3}' | head -n 1)
        echo -e "${YELLOW}正在切换网关至 $temp_gw 并测试连通性...${NC}"
        
        ip route replace default via "$temp_gw" 2>/dev/null || ip route add default via "$temp_gw" 2>/dev/null
        
        chattr -i /etc/resolv.conf 2>/dev/null
        cp /etc/resolv.conf /tmp/resolv.conf.bak 2>/dev/null
        rm -f /etc/resolv.conf
        echo "nameserver 119.29.29.29" > /etc/resolv.conf; echo "nameserver 8.8.8.8" >> /etc/resolv.conf
        chattr +i /etc/resolv.conf 2>/dev/null

        if curl -s -m 5 -I https://github.com > /dev/null; then
            echo -e "${GREEN}测试通过！海外网络已连通，启用临时加速。${NC}"
            TEMP_GW_SET=true; TEMP_ORIG_GW="$ORIG_GW"; break
        else
            echo -e "${RED}测试失败！无法连通 GitHub。请检查该网关是否具备科学上网能力。${NC}"
            echo -e "正在还原网关..."
            if [ -n "$ORIG_GW" ]; then ip route replace default via "$ORIG_GW" 2>/dev/null
            else ip route del default via "$temp_gw" 2>/dev/null; fi
            
            chattr -i /etc/resolv.conf 2>/dev/null
            mv /tmp/resolv.conf.bak /etc/resolv.conf 2>/dev/null
            chattr +i /etc/resolv.conf 2>/dev/null
        fi
    done
}

detect_net_manager() {
    if command -v nmcli &> /dev/null && systemctl is-active --quiet NetworkManager; then echo "NetworkManager"
    elif command -v netplan &> /dev/null && ls /etc/netplan/*.yaml >/dev/null 2>&1; then echo "Netplan"
    elif systemctl is-active --quiet systemd-networkd; then echo "systemd-networkd"
    else echo "ifupdown"; fi
}

pause_to_return() {
    echo -e "\n${CYAN}====================================${NC}"
    read -n 1 -s -r -p "操作结束。按任意键返回当前菜单..."
    echo ""
}

check_and_rollback() {
    local service_name=$1; local backup_file=$2; local target_file=$3; local type_msg=$4; local success=false
    echo -e "${YELLOW}健康检查中 (尝试 3 次)...${NC}"
    for i in {1..3}; do
        sleep 2
        if systemctl is-active --quiet "$service_name"; then success=true; break; fi
        echo -e "第 $i 次检查: 服务未运行..."
    done
    if [ "$success" = true ]; then
        echo -e "${GREEN}${type_msg} 启动成功并稳定运行！${NC}"; rm -f "$backup_file"
    else
        echo -e "${RED}严重：服务启动失败！触发防宕机回滚...${NC}"
        mv -f "$backup_file" "$target_file" 2>/dev/null; systemctl restart "$service_name"; sleep 2
        if systemctl is-active --quiet "$service_name"; then echo -e "${GREEN}回滚成功：已恢复至上一次状态！${NC}"
        else echo -e "${RED}致命错误：回滚后服务依然无法启动，请查日志！${NC}"; fi
    fi
}

ensure_mihomo_base_config() {
    if [ -f /etc/mihomo/config.yaml ]; then
        if ! grep -q "external-ui" /etc/mihomo/config.yaml; then
            sed -i '1i\external-ui: /etc/mihomo/ui' /etc/mihomo/config.yaml
        fi
        if ! grep -q "external-controller" /etc/mihomo/config.yaml; then
            sed -i '1i\external-controller: "0.0.0.0:9090"' /etc/mihomo/config.yaml
        elif grep -q "external-controller:.*127.0.0.1" /etc/mihomo/config.yaml || grep -q "external-controller:.*localhost" /etc/mihomo/config.yaml; then
            sed -i "s/external-controller:.*/external-controller: '0.0.0.0:9090'/g" /etc/mihomo/config.yaml
        fi
    fi
}

patch_ui_api() {
    echo -e "${YELLOW}正在为 Web 面板注入动态 API 地址 (免密登录)...${NC}"
    find /etc/mihomo/ui -type f \( -name "*.js" -o -name "*.html" \) -exec sed -i 's/"http:\/\/127.0.0.1:9090"/window.location.protocol+"\/\/"+window.location.host/g' {} + 2>/dev/null
    find /etc/mihomo/ui -type f \( -name "*.js" -o -name "*.html" \) -exec sed -i "s/'http:\/\/127.0.0.1:9090'/window.location.protocol+'\/\/'+window.location.host/g" {} + 2>/dev/null
    echo -e "${GREEN}UI 动态绑定完成！${NC}"
}

# --- 核心部署与双模调度引擎 ---
# 👇 将默认兜底参数改为 TUN
deploy_mihomo_core() {
    local target_mode=${1:-"TUN"}
    local is_switch=$2
    
    if [ "$is_switch" != "true" ]; then
        if systemctl is-active --quiet mihomo || [ -f /usr/local/bin/mihomo ]; then
            echo -e "${RED}检测到系统已安装 Mihomo！${NC}"
            read -p "是否强制覆盖重装为 [$target_mode] 模式？[y/N]: " force_redeploy
            if [[ ! "$force_redeploy" =~ ^[Yy]$ ]]; then return; fi
        fi
    fi

    # --- 环境大清洗：防止底层冲突 ---
    echo -e "\n${YELLOW}====== 开始执行清理并部署 Mihomo ($target_mode 模式) ======${NC}"
    systemctl stop mihomo >/dev/null 2>&1
    systemctl disable mihomo >/dev/null 2>&1
    if [ -f /etc/mihomo/tproxy-clean.sh ]; then
        bash /etc/mihomo/tproxy-clean.sh >/dev/null 2>&1
    fi
    rm -f /etc/systemd/system/mihomo.service
    systemctl daemon-reload
    
    setup_temp_gw

    echo -e "\n-> 强制开启内核 IP 转发..."
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-lucas-ipforward.conf; sysctl --system >/dev/null 2>&1
    
    echo "-> 调整系统核心防护策略..."
    iptables -P FORWARD ACCEPT
    if ! dpkg -s iptables-persistent &> /dev/null; then 
        (
            apt-get update -y >/tmp/lucas_error.log 2>&1
            apt-get install -y iptables-persistent < /dev/null >>/tmp/lucas_error.log 2>&1
        ) &
        show_spinner $! "正在部署 iptables 持久化组件"
    fi
    netfilter-persistent save >/dev/null 2>&1 || true

    echo -e "\n-> 执行系统极限瘦身与日志防爆配置..."
    sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=100M/' /etc/systemd/journald.conf 2>/dev/null || echo "SystemMaxUse=100M" >> /etc/systemd/journald.conf
    sed -i 's/^#SystemMaxFiles=.*/SystemMaxFiles=5/' /etc/systemd/journald.conf 2>/dev/null || echo "SystemMaxFiles=5" >> /etc/systemd/journald.conf
    systemctl restart systemd-journald
    if systemctl is-active --quiet rsyslog; then systemctl disable --now rsyslog 2>/dev/null || true; fi

    chattr -i /etc/resolv.conf 2>/dev/null
    if systemctl is-active --quiet systemd-resolved; then systemctl disable --now systemd-resolved; fi
    rm -f /etc/resolv.conf; echo "nameserver 223.5.5.5" > /etc/resolv.conf; echo "nameserver 119.29.29.29" >> /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null

    mkdir -p /etc/mihomo
    echo "$target_mode" > /etc/mihomo/.run_mode
    
    active_iface=$(ip -4 route show default | grep -v "mihomo" | grep -v "tun" | awk '/default/ {print $5}' | head -n 1)
    [ -z "$active_iface" ] && active_iface=$(ip link | awk -F: '$0 !~ "lo|vir|wl|mihomo|tun|^[^0-9]"{print $2;getline}' | head -n 1 | tr -d ' ')

    latest_version=$(curl -sL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$latest_version" ]; then
        echo -e "${RED}严重错误：无法获取最新版本号！请检查网络。${NC}"
        restore_temp_gw; pause_to_return; return
    fi

    download_with_progress "https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/mihomo-linux-amd64-v3-${latest_version}.gz" "/tmp/mihomo.gz" "拉取云端内核 ${latest_version}"
    if [ -f "/tmp/mihomo.gz" ]; then
        gunzip -f /tmp/mihomo.gz && mv /tmp/mihomo /usr/local/bin/mihomo && chmod +x /usr/local/bin/mihomo >/dev/null 2>&1
    fi

    if [ ! -x /usr/local/bin/mihomo ]; then restore_temp_gw; pause_to_return; return; fi

    echo -e "\n${YELLOW}正在预下载大满贯路由数据库 (GeoSite/GeoIP/ASN)...${NC}"
    rm -f /etc/mihomo/*.dat /etc/mihomo/*.metadat /etc/mihomo/*.metadb /etc/mihomo/*.mmdb
    download_with_progress "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat" "/etc/mihomo/geosite.dat" "拉取 geosite.dat"
    download_with_progress "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb" "/etc/mihomo/geoip.metadb" "拉取 geoip.metadb"
    download_with_progress "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb" "/etc/mihomo/country.mmdb" "拉取 country.mmdb"
    download_with_progress "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/asn.mmdb" "/etc/mihomo/asn.mmdb" "拉取 asn.mmdb"

    echo -e "\n-> 配置文件部署"
    if [ "$target_mode" == "TProxy" ]; then
        echo -e "${YELLOW}🚨 注意：请确保你的 Sub-Store 配置为 [TProxy 极速版] (关闭 TUN，端口 7892，DNS 改为纯净 UDP)！${NC}"
    else
        echo -e "${YELLOW}🚨 注意：请确保你的 Sub-Store 配置为 [TUN 兼容版] (开启 TUN，关闭 TProxy 端口)！${NC}"
    fi
    
    read -p "请输入 $target_mode 专属配置订阅链接: " sub_url
    if [ -n "$sub_url" ]; then 
        curl -sL -o /etc/mihomo/config.yaml "$sub_url"
        echo "$sub_url" > /etc/mihomo/.sub_url
        ensure_mihomo_base_config
    else 
        echo -e "${RED}必须输入链接！中止。${NC}"
        restore_temp_gw
        pause_to_return
        return
    fi

    # --- 模式分离：底层劫持策略注入 ---
    if [ "$target_mode" == "TProxy" ]; then
        echo -e "\n-> 注入 TProxy 底层劫持脚本..."
        cat > /etc/mihomo/tproxy-setup.sh << EOF
#!/bin/bash
modprobe xt_TPROXY 2>/dev/null || true
modprobe xt_socket 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1
for i in /sys/class/net/*; do
    iface=\$(basename "\$i")
    sysctl -w net.ipv4.conf."\$iface".rp_filter=0 >/dev/null 2>&1
done
sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.send_redirects=0 >/dev/null 2>&1
sysctl -w net.ipv4.conf.all.accept_redirects=0 >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.accept_redirects=0 >/dev/null 2>&1

ip rule add fwmark 1 table 100 2>/dev/null || true
ip route add local default dev lo table 100 2>/dev/null || true

iptables -t nat -C POSTROUTING -o $active_iface -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o $active_iface -j MASQUERADE
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

iptables -t mangle -N MIHOMO_DIVERT 2>/dev/null || true
iptables -t mangle -F MIHOMO_DIVERT
iptables -t mangle -A MIHOMO_DIVERT -j MARK --set-mark 1
iptables -t mangle -A MIHOMO_DIVERT -j ACCEPT

iptables -t mangle -N MIHOMO 2>/dev/null || true
iptables -t mangle -F MIHOMO

iptables -t mangle -A MIHOMO -d 0.0.0.0/8 -j RETURN
iptables -t mangle -A MIHOMO -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A MIHOMO -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A MIHOMO -d 169.254.0.0/16 -j RETURN
iptables -t mangle -A MIHOMO -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A MIHOMO -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A MIHOMO -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A MIHOMO -d 240.0.0.0/4 -j RETURN

iptables -t mangle -A MIHOMO -p tcp -j TPROXY --on-port 7892 --tproxy-mark 1
iptables -t mangle -A MIHOMO -p udp ! --dport 53 -j TPROXY --on-port 7892 --tproxy-mark 1

iptables -t mangle -C PREROUTING -p tcp -m socket -j MIHOMO_DIVERT 2>/dev/null || iptables -t mangle -I PREROUTING -p tcp -m socket -j MIHOMO_DIVERT
iptables -t mangle -C PREROUTING -j MIHOMO 2>/dev/null || iptables -t mangle -A PREROUTING -j MIHOMO

iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53
iptables -t nat -C PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53
EOF
        chmod +x /etc/mihomo/tproxy-setup.sh

        cat > /etc/mihomo/tproxy-clean.sh << EOF
#!/bin/bash
ip rule del fwmark 1 table 100 2>/dev/null || true
ip route del local default dev lo table 100 2>/dev/null || true
iptables -t nat -D POSTROUTING -o $active_iface -j MASQUERADE 2>/dev/null || true
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -D PREROUTING -p tcp -m socket -j MIHOMO_DIVERT 2>/dev/null || true
iptables -t mangle -D PREROUTING -j MIHOMO 2>/dev/null || true
iptables -t mangle -F MIHOMO_DIVERT 2>/dev/null || true
iptables -t mangle -X MIHOMO_DIVERT 2>/dev/null || true
iptables -t mangle -F MIHOMO 2>/dev/null || true
iptables -t mangle -X MIHOMO 2>/dev/null || true
iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
EOF
        chmod +x /etc/mihomo/tproxy-clean.sh

        cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo Daemon (TProxy Mode)
After=network.target

[Service]
Type=simple
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
Restart=always
ExecStartPre=+/etc/mihomo/tproxy-setup.sh
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
ExecStopPost=+/etc/mihomo/tproxy-clean.sh
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
EOF

    else
        # TUN Mode Clean Systemd
        rm -f /etc/mihomo/tproxy-setup.sh /etc/mihomo/tproxy-clean.sh
        cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo Daemon (TUN Mode)
After=network.target

[Service]
Type=simple
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
Restart=always
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload; systemctl enable mihomo

    echo -e "\n-> 图形化 Web 面板部署"
    echo "1. Metacubexd (推荐)"; echo "2. Zashboard"
    read -p "请选择: " ui_choice
    mkdir -p /etc/mihomo/ui; rm -rf /etc/mihomo/ui/*
    
    local url=""
    if [ "$ui_choice" == "1" ]; then url="https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
    elif [ "$ui_choice" == "2" ]; then url="https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"; fi

    if [ -n "$url" ]; then
        download_with_progress "$url" "/tmp/ui.zip" "拉取 Web 面板"
        unzip -q /tmp/ui.zip -d /tmp/ >/dev/null 2>&1
        
        if [ -d /tmp/metacubexd-gh-pages ]; then
            cp -r /tmp/metacubexd-gh-pages/* /etc/mihomo/ui/; echo "Metacubexd" > /etc/mihomo/.ui_type
        elif [ -d /tmp/zashboard-gh-pages ]; then
            cp -r /tmp/zashboard-gh-pages/* /etc/mihomo/ui/; echo "Zashboard" > /etc/mihomo/.ui_type
        fi
        rm -rf /tmp/ui.zip /tmp/*-gh-pages
        patch_ui_api
    fi

    restore_temp_gw

    systemctl start mihomo
    check_and_rollback "mihomo" "" "" "$target_mode 透明网关"
    
    current_ip=$(ip -4 addr show "$active_iface" 2>/dev/null | grep global | awk '{print $2}' | cut -d/ -f1 | head -n 1)
    echo -e "\n${GREEN}面板地址: http://${current_ip}:9090/ui${NC}"
    pause_to_return
}

# --- 部署向导菜单 ---
# 👇 修改菜单提示，将 TUN 设为默认选项
deploy_mihomo_menu() {
    clear
    echo -e "${CYAN}--- Mihomo 部署向导 ---${NC}"
    echo "1. 🚀 部署 TProxy 模式 (网页秒开，极限性能)"
    echo "2. 🛡️ 部署 TUN 模式 (强力接管，高兼容性) [默认]"
    echo "0. 返回主菜单"
    read -p "请选择 [1/2, 默认2]: " deploy_choice
    
    case $deploy_choice in
        1) deploy_mihomo_core "TProxy" ;;
        0) return ;;
        *) deploy_mihomo_core "TUN" ;;
    esac
}

update_system() {
    echo -e "${YELLOW}当前系统版本：${NC}"; cat /etc/os-release | grep PRETTY_NAME; echo ""
    read -p "是否执行系统更新 (apt update && upgrade)? [y/N/0返回]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then 
        echo -e "${YELLOW}正在执行全系统更新，请稍候...${NC}"
        apt-get update -y && apt-get upgrade -y
        echo -e "${GREEN}系统更新完成！${NC}"
    fi
    pause_to_return
}

enable_bbr() {
    current_bbr=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    echo -e "${YELLOW}当前拥塞控制算法: ${current_bbr:-未知}${NC}\n"
    if [ "$current_bbr" == "bbr" ]; then echo -e "${GREEN}BBR 已经处于开启状态。${NC}"
    else
        read -p "是否开启 BBR 网络加速与网卡硬件级调优? [y/N/0返回]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            if ! lsmod | grep -q bbr; then modprobe tcp_bbr 2>/dev/null || true; echo "tcp_bbr" > /etc/modules-load.d/bbr.conf; fi
            echo "net.core.default_qdisc=fq" > /etc/sysctl.d/99-lucas-bbr.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-lucas-bbr.conf
            sysctl --system >/dev/null 2>&1; echo -e "${GREEN}BBR 已成功开启！${NC}"
            
            echo -e "\n${YELLOW}正在执行直通网卡硬件级极限调优 (队列扩展与卸载)...${NC}"
            active_iface=$(ip -4 route show default | grep -v "mihomo" | grep -v "tun" | awk '/default/ {print $5}' | head -n 1)
            [ -z "$active_iface" ] && active_iface=$(ip link | awk -F: '$0 !~ "lo|vir|wl|mihomo|tun|^[^0-9]"{print $2;getline}' | head -n 1 | tr -d ' ')
            
            if [ -n "$active_iface" ]; then
                ethtool -G "$active_iface" rx 4096 tx 4096 2>/dev/null || true
                ethtool -K "$active_iface" tso on gso on gro on 2>/dev/null || true
                
                cat <<EOF > /etc/systemd/system/ethtool-tune.service
[Unit]
Description=Ethtool Hardware NIC Tuning
After=network.target

[Service]
Type=oneshot
ExecStart=-/sbin/ethtool -G $active_iface rx 4096 tx 4096
ExecStart=-/sbin/ethtool -K $active_iface tso on gso on gro on
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable ethtool-tune.service >/dev/null 2>&1
                echo -e "${GREEN}网卡 $active_iface 硬件加速调优完成并已固化重启配置！${NC}"
            else
                echo -e "${RED}未检测到活动物理网卡，硬件调优跳过。${NC}"
            fi
        fi
    fi
    pause_to_return
}

firewall_setup() {
    while true; do
        clear
        echo -e "${YELLOW}--- 防火墙设置 ---${NC}"
        if command -v ufw &> /dev/null; then fw_type="UFW"; fw_status=$(ufw status | head -n 1)
        elif command -v iptables &> /dev/null; then fw_type="iptables"; fw_status=$(iptables -L INPUT -n | head -n 1)
        else fw_type="未知"; fw_status="未检测到防火墙"; fi
        
        echo -e "防火墙工具: ${CYAN}$fw_type${NC} | 状态: ${CYAN}$fw_status${NC}\n"
        echo "1. 配置为放行所有流量 (相当于彻底关闭拦截)"
        echo "2. 放行指定端口"; echo "3. 恢复默认拦截状态"; echo "0. 返回主菜单"
        read -p "请选择: " fw_choice

        case $fw_choice in
            1)
                read -p "确认放行所有端口? [y/N]: " conf
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    if [ "$fw_type" == "UFW" ]; then ufw default allow incoming; ufw default allow outgoing; ufw --force enable
                    else
                        iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT; iptables -F
                        if ! dpkg -s iptables-persistent &> /dev/null; then apt-get install -y -qq iptables-persistent >/dev/null 2>&1; fi
                        netfilter-persistent save >/dev/null 2>&1
                    fi
                    echo -e "${GREEN}已放行所有端口！${NC}"
                fi; pause_to_return ;;
            2)
                read -p "输入端口 (如 100,6000,6001-6008): " ports
                if [ -n "$ports" ]; then
                    if [ "$fw_type" == "UFW" ]; then
                        ufw --force enable; IFS=',' read -ra ADDR <<< "$ports"; for p in "${ADDR[@]}"; do ufw allow "$p"; done
                    else
                        IFS=',' read -ra ADDR <<< "$ports"
                        for p in "${ADDR[@]}"; do
                            if [[ "$p" == *-* ]]; then iptables -A INPUT -p tcp --dport "${p%:*}:${p#*:}" -j ACCEPT; iptables -A INPUT -p udp --dport "${p%:*}:${p#*:}" -j ACCEPT
                            else iptables -A INPUT -p tcp --dport "$p" -j ACCEPT; iptables -A INPUT -p udp --dport "$p" -j ACCEPT; fi
                        done
                        if ! dpkg -s iptables-persistent &> /dev/null; then apt-get install -y -qq iptables-persistent >/dev/null 2>&1; fi
                        netfilter-persistent save >/dev/null 2>&1
                    fi
                    echo -e "${GREEN}指定端口已放行！${NC}"
                fi; pause_to_return ;;
            3)
                read -p "确认恢复默认拦截? [y/N]: " conf
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    if [ "$fw_type" == "UFW" ]; then ufw --force reset; ufw default deny incoming; ufw default allow outgoing; ufw --force enable
                    else
                        iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT; iptables -F
                        if ! dpkg -s iptables-persistent &> /dev/null; then apt-get install -y -qq iptables-persistent >/dev/null 2>&1; fi
                        netfilter-persistent save >/dev/null 2>&1
                    fi
                    echo -e "${GREEN}已恢复默认拦截状态！${NC}"
                fi; pause_to_return ;;
            0|"") break ;;
        esac
    done
}

write_network_config() {
    local mode=$1; local iface=$2; local ip=$3; local gw=$4; local mgr=$5
    local dns1=${6:-223.5.5.5}; local dns2=${7:-119.29.29.29}
    echo -e "\n${YELLOW}正在通过 $mgr 引擎安全重写底层网络配置...${NC}"
    
    if [ -d /etc/cloud/cloud.cfg.d ]; then
        echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    fi
    
    if [ "$mgr" == "NetworkManager" ]; then
        con_name=$(nmcli -t -f NAME,DEVICE con show --active | grep ":$iface" | cut -d: -f1 | head -n 1)
        [ -z "$con_name" ] && con_name="$iface"
        if [ "$mode" == "dhcp" ]; then nmcli con mod "$con_name" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
        else nmcli con mod "$con_name" ipv4.method manual ipv4.addresses "$ip" ipv4.gateway "$gw" ipv4.dns "$dns1 $dns2"; fi
    elif [ "$mgr" == "Netplan" ]; then
        local net_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n 1)
        [ -z "$net_file" ] && net_file="/etc/netplan/01-netcfg.yaml"
        cp "$net_file" "${net_file}.bak"
        cat <<EOF > "$net_file"
network:
  version: 2
  ethernets:
    $iface:
EOF
        if [ "$mode" == "dhcp" ]; then echo "      dhcp4: true" >> "$net_file"
        else
            echo "      dhcp4: false" >> "$net_file"; echo "      addresses: [$ip]" >> "$net_file"
            [ -n "$gw" ] && echo -e "      routes:\n        - to: default\n          via: $gw" >> "$net_file"
            echo -e "      nameservers:\n        addresses: [$dns1, $dns2]" >> "$net_file"
        fi
        chmod 600 "$net_file"
    elif [ "$mgr" == "systemd-networkd" ]; then
        local net_file="/etc/systemd/network/10-$iface.network"
        [ -f "$net_file" ] && cp "$net_file" "${net_file}.bak"
        cat <<EOF > "$net_file"
[Match]
Name=$iface

[Network]
EOF
        if [ "$mode" == "dhcp" ]; then echo "DHCP=yes" >> "$net_file"
        else
            echo "Address=$ip" >> "$net_file"
            [ -n "$gw" ] && echo "Gateway=$gw" >> "$net_file"
            echo "DNS=$dns1" >> "$net_file"; echo "DNS=$dns2" >> "$net_file"
        fi
    else # ifupdown
        local net_file="/etc/network/interfaces"
        cp "$net_file" "${net_file}.bak"
        cat <<EOF > "$net_file"
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

allow-hotplug $iface
EOF
        if [ "$mode" == "dhcp" ]; then echo "iface $iface inet dhcp" >> "$net_file"
        else
            echo "iface $iface inet static" >> "$net_file"
            echo "    address $ip" >> "$net_file"
            [ -n "$gw" ] && echo "    gateway $gw" >> "$net_file"
            echo "    dns-nameservers $dns1 $dns2" >> "$net_file"
        fi
    fi
}

network_modify() {
    while true; do
        clear
        echo -e "${YELLOW}--- 系统网络底层修改 ---${NC}"
        net_mgr=$(detect_net_manager)
        
        active_iface=$(ip -4 route show default | grep -v "mihomo" | grep -v "tun" | awk '/default/ {print $5}' | head -n 1)
        [ -z "$active_iface" ] && active_iface=$(ip link | awk -F: '$0 !~ "lo|vir|wl|mihomo|tun|^[^0-9]"{print $2;getline}' | head -n 1 | tr -d ' ')
        current_ip_cidr=$(ip -4 addr show "$active_iface" 2>/dev/null | grep global | awk '{print $2}' | head -n 1)
        current_gw=$(ip -4 route show default | grep -v "mihomo" | grep -v "tun" | awk '/default/ {print $3}' | head -n 1)
        
        if systemctl is-active --quiet disable-ipv6-enforcer.service; then ipv6_status="${GREEN}已开启系统级绝育守护${NC}"
        else ipv6_status=$(sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | awk '{print $3}'); fi
        
        if systemctl is-active --quiet mihomo; then current_dns="[Mihomo 接管中]"
        else current_dns=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd "," -); fi

        echo -e "物理网卡: ${CYAN}${active_iface}${NC} | 管理器: ${CYAN}${net_mgr}${NC}"
        echo -e "IPv4: ${CYAN}${current_ip_cidr:-未知}${NC} | 网关: ${CYAN}${current_gw:-未设置}${NC}"
        echo -e "IPv6 禁用状态: ${CYAN}${ipv6_status:-0}${NC} | DNS: ${CYAN}${current_dns}${NC}\n"
        
        echo "1. 一键彻底关闭 IPv6 (Sysctl + 免疫 Cloud-init)"
        echo "2. 修改 IPv4 地址与网关 (向导式安全注入)"
        echo "3. 修改系统基础 DNS (向导式)"
        echo "4. 💣 一键彻底卸载 Cloud-init (物理超度，防配置复原)"
        echo "0. 返回主菜单"
        read -p "请选择: " net_choice

        case $net_choice in
            1)
                read -p "确认完全禁用 IPv6 吗? [y/N]: " conf
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    if [ -d /etc/cloud/cloud.cfg.d ]; then echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg; fi
                    
                    cat > /etc/sysctl.d/99-lucas-disable-ipv6.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.default.autoconf = 0
EOF
                    sysctl --system >/dev/null 2>&1
                    
                    cat << 'EOF' > /usr/local/bin/disable-ipv6.sh
#!/bin/bash
sysctl -p /etc/sysctl.d/99-lucas-disable-ipv6.conf >/dev/null 2>&1
for i in /sys/class/net/*; do
    iface=$(basename "$i")
    sysctl -w net.ipv6.conf."$iface".disable_ipv6=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf."$iface".accept_ra=0 >/dev/null 2>&1
done
if command -v ip6tables &> /dev/null; then
    ip6tables -P FORWARD DROP 2>/dev/null
    ip6tables -F FORWARD 2>/dev/null
fi
EOF
                    chmod +x /usr/local/bin/disable-ipv6.sh
                    
                    cat << 'EOF' > /etc/systemd/system/disable-ipv6-enforcer.service
[Unit]
Description=Force Disable IPv6 Enforcer
After=network.target network-online.target NetworkManager.service systemd-networkd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disable-ipv6.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
                    systemctl daemon-reload
                    systemctl enable --now disable-ipv6-enforcer.service >/dev/null 2>&1
                    
                    ip -6 route flush all 2>/dev/null
                    for i in /sys/class/net/*; do ip -6 addr flush dev "$(basename "$i")" 2>/dev/null; done

                    echo -e "${GREEN}IPv6 已彻底关闭！防泄漏黑洞守护神满血上线！${NC}"
                fi; pause_to_return ;;
            2)
                echo -e "${YELLOW}\n请选择网络配置模式:${NC}"
                echo "1. 静态 IP (Static) [推荐旁路由使用]"
                echo "2. 动态获取 (DHCP)"
                read -p "选择 [默认 1]: " ip_mode
                ip_mode=${ip_mode:-1}

                if [ "$ip_mode" == "1" ]; then
                    read -p "请输入静态 IP (带掩码, 如 192.168.2.231/24) [直接回车保持 $current_ip_cidr]: " new_ip
                    new_ip=${new_ip:-$current_ip_cidr}
                    read -p "是否需要修改网关？输入新网关 IP [直接回车保持 $current_gw]: " new_gw
                    new_gw=${new_gw:-$current_gw}
                    
                    current_dns_arr=($(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}'))
                    default_dns1=${current_dns_arr[0]:-223.5.5.5}
                    default_dns2=${current_dns_arr[1]:-119.29.29.29}
                    
                    read -p "请输入首选 DNS [直接回车保持 $default_dns1]: " new_dns1
                    new_dns1=${new_dns1:-$default_dns1}
                    read -p "请输入备用 DNS [直接回车保持 $default_dns2]: " new_dns2
                    new_dns2=${new_dns2:-$default_dns2}

                    write_network_config "static" "$active_iface" "$new_ip" "$new_gw" "$net_mgr" "$new_dns1" "$new_dns2"
                    
                    chattr -i /etc/resolv.conf 2>/dev/null
                    if systemctl is-active --quiet systemd-resolved; then systemctl disable --now systemd-resolved; fi
                    rm -f /etc/resolv.conf
                    echo "nameserver $new_dns1" > /etc/resolv.conf
                    [ -n "$new_dns2" ] && echo "nameserver $new_dns2" >> /etc/resolv.conf
                    chattr +i /etc/resolv.conf 2>/dev/null
                else
                    read -p "切换为 DHCP 模式。是否需要指定网关？输入网关 IP [直接回车自动获取]: " new_gw
                    write_network_config "dhcp" "$active_iface" "" "$new_gw" "$net_mgr"
                fi
                
                echo -e "\n${YELLOW}底层网络配置已重写生成。${NC}"
                if systemctl is-active --quiet mihomo || [ -f /usr/local/bin/mihomo ]; then
                    read -p "是否立即应用更改并同步重启 Mihomo？(⚠️ SSH 必将断开) [y/N]: " apply_net
                else
                    read -p "是否立即应用网络更改？(⚠️ SSH 必将断开) [y/N]: " apply_net
                fi

                if [[ "$apply_net" =~ ^[Yy]$ ]]; then
                    echo -e "${GREEN}正在后台下发网卡重启与服务同步指令...${NC}"
                    echo -e "${YELLOW}请在终端断开后，使用新的 IP 重新连接！${NC}"
                    nohup bash -c "
                        if [ '$net_mgr' == 'NetworkManager' ]; then nmcli con up '$active_iface'
                        elif [ '$net_mgr' == 'Netplan' ]; then netplan apply
                        elif [ '$net_mgr' == 'systemd-networkd' ]; then systemctl restart systemd-networkd
                        else systemctl restart networking; fi
                        sleep 3
                        if systemctl is-active --quiet mihomo || [ -f /usr/local/bin/mihomo ]; then systemctl restart mihomo; fi
                    " >/dev/null 2>&1 &
                    sleep 2; exit 0
                fi; pause_to_return ;;
            3)
                echo -e "\n${YELLOW}旁路由自身系统 DNS 配置向导:${NC}"
                current_dns_arr=($(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}'))
                default_dns1=${current_dns_arr[0]:-223.5.5.5}
                default_dns2=${current_dns_arr[1]:-119.29.29.29}
                read -p "请输入首选 DNS (回车保持 $default_dns1): " dns1
                dns1=${dns1:-$default_dns1}
                read -p "请输入备用 DNS (回车保持 $default_dns2): " dns2
                dns2=${dns2:-$default_dns2}
                
                chattr -i /etc/resolv.conf 2>/dev/null
                if systemctl is-active --quiet systemd-resolved; then systemctl disable --now systemd-resolved; fi
                rm -f /etc/resolv.conf
                echo "nameserver $dns1" > /etc/resolv.conf
                [ -n "$dns2" ] && echo "nameserver $dns2" >> /etc/resolv.conf
                chattr +i /etc/resolv.conf 2>/dev/null
                echo -e "${GREEN}系统 DNS 已修改，并成功开启防篡改锁！${NC}"; pause_to_return ;;
            4)
                echo -e "${RED}⚠️ 卸载 Cloud-init 后，所有网络和系统设置将彻底由本机接管。${NC}"
                read -p "确认彻底物理卸载 Cloud-init 吗？[y/N]: " conf
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}正在连根拔起 Cloud-init 及其依赖残留...${NC}"
                    apt-get purge -y -qq cloud-init cloud-initramfs-copymods cloud-initramfs-dyn-netconf >/dev/null 2>&1
                    rm -rf /etc/cloud /var/lib/cloud /etc/network/interfaces.d/50-cloud-init* 2>/dev/null
                    echo -e "${GREEN}Cloud-init 已被彻底物理超度！系统控制权完美收回。${NC}"
                fi; pause_to_return ;;
            0|"") break ;;
        esac
    done
}

enable_forwarding() {
    v4_fwd=$(sysctl net.ipv4.ip_forward 2>/dev/null | awk '{print $3}')
    echo -e "${YELLOW}当前 IPv4 转发状态: ${CYAN}${v4_fwd:-0}${YELLOW} (1为开启)${NC}\n"
    echo "1. 仅开启 IPv4 转发"; echo "2. 同时开启 IPv4 和 IPv6 转发"; echo "0. 返回"
    read -p "请选择: " fwd_choice

    case $fwd_choice in
        1)
            echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-lucas-ipforward.conf; sysctl --system >/dev/null 2>&1
            echo -e "${GREEN}IPv4 转发已开启！${NC}" ;;
        2)
            echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-lucas-ipforward.conf
            echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-lucas-ipforward.conf; sysctl --system >/dev/null 2>&1
            echo -e "${GREEN}双栈转发已开启！${NC}" ;;
        0|"") return ;;
    esac
    pause_to_return
}

setup_swap() {
    current_swap=$(free -h | grep Swap | awk '{print $2}')
    echo -e "${YELLOW}当前 Swap 容量: ${CYAN}${current_swap:-0B}${NC}\n"
    read -p "设置 Swap 大小 (单位:G，0返回): " swap_size
    if [[ "$swap_size" =~ ^[1-9][0-9]*$ ]]; then
        fallocate -l ${swap_size}G /swapfile; chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
        sed -i '/\/swapfile/d' /etc/fstab; echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo "vm.swappiness=10" > /etc/sysctl.d/99-lucas-swap.conf; sysctl --system >/dev/null 2>&1
        echo -e "${GREEN}Swap 创建成功！${NC}"
    fi
    pause_to_return
}

sync_time() {
    current_tz=$(timedatectl | grep "Time zone" | awk '{print $3}')
    echo -e "当前时区: ${CYAN}${current_tz:-未知}${NC} | 时间: ${CYAN}$(date "+%Y-%m-%d %H:%M:%S")${NC}\n"
    read -p "设置为 Asia/Shanghai 并开启 NTP? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        timedatectl set-timezone Asia/Shanghai; timedatectl set-ntp true
        echo -e "${GREEN}校准完成: $(date "+%Y-%m-%d %H:%M:%S")${NC}"
    fi
    pause_to_return
}

install_qga() {
    if systemctl is-active --quiet qemu-guest-agent; then qga_status="${GREEN}运行中${NC}"
    elif command -v qemu-ga &> /dev/null; then qga_status="${YELLOW}已安装未运行${NC}"
    else qga_status="${RED}未安装${NC}"; fi
    echo -e "QGA 状态: ${qga_status}\n"

    if ! systemctl is-active --quiet qemu-guest-agent; then
        read -p "部署 QEMU Guest Agent? [y/N]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            (
                apt-get update -y >/tmp/lucas_error.log 2>&1
                apt-get install -y qemu-guest-agent < /dev/null >>/tmp/lucas_error.log 2>&1
            ) &
            show_spinner $! "正在安装 QEMU Guest Agent"
            systemctl enable --now qemu-guest-agent
            echo -e "${GREEN}部署成功，已开机自启！${NC}"
        fi
    fi
    pause_to_return
}

manage_geo_data() {
    while true; do
        clear
        echo -e "\n${CYAN}--- Geo 大满贯数据库配置 ---${NC}"
        if crontab -l 2>/dev/null | grep -q "update_geo.sh"; then cron_status="${GREEN}已配置 (每周六 3:00 自动拉取)${NC}"
        else cron_status="${YELLOW}未开启定时更新${NC}"; fi
        echo -e "当前定时状态: ${cron_status}\n"

        echo "1. ⚡ 立即全部更新"
        echo "2. 🕒 定时更新 (每周六凌晨 3:00)"
        echo "3. 🗑️  取消定时更新"; echo "0. 返回主菜单"
        read -p "请选择: " geo_choice

        case $geo_choice in
            1)
                setup_temp_gw
                systemctl stop mihomo
                rm -f /etc/mihomo/*.dat /etc/mihomo/*.metadat /etc/mihomo/*.metadb /etc/mihomo/*.mmdb
                echo -e "\n${YELLOW}正在拉取最新大满贯数据库...${NC}"
                download_with_progress "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat" "/etc/mihomo/geosite.dat" "更新 geosite.dat"
                download_with_progress "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb" "/etc/mihomo/geoip.metadb" "更新 geoip.metadb"
                download_with_progress "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb" "/etc/mihomo/country.mmdb" "更新 country.mmdb"
                download_with_progress "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/asn.mmdb" "/etc/mihomo/asn.mmdb" "更新 asn.mmdb"
                
                restore_temp_gw; systemctl start mihomo; pause_to_return ;;
            2)
                echo -e "${YELLOW}正在写入自动任务...${NC}"
                cat << 'EOF' > /etc/mihomo/update_geo.sh
#!/bin/bash
systemctl stop mihomo
rm -f /etc/mihomo/*.dat /etc/mihomo/*.metadat /etc/mihomo/*.metadb /etc/mihomo/*.mmdb
wget -q -O /etc/mihomo/geosite.dat "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
wget -q -O /etc/mihomo/geoip.metadb "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"
wget -q -O /etc/mihomo/country.mmdb "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb"
wget -q -O /etc/mihomo/asn.mmdb "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/asn.mmdb"
systemctl start mihomo
EOF
                chmod +x /etc/mihomo/update_geo.sh
                (crontab -l 2>/dev/null | grep -v "update_geo.sh"; echo "0 3 * * 6 /etc/mihomo/update_geo.sh >/dev/null 2>&1") | crontab -
                echo -e "${GREEN}配置成功！系统将在每周六 03:00 后台自动更新。${NC}"; pause_to_return ;;
            3)
                crontab -l 2>/dev/null | grep -v "update_geo.sh" | crontab -; rm -f /etc/mihomo/update_geo.sh
                echo -e "${GREEN}已取消定时任务。${NC}"; pause_to_return ;;
            0|"") break ;;
        esac
    done
}

manage_ui() {
    while true; do
        clear
        current_ui="未知面板"
        if [ -f /etc/mihomo/.ui_type ]; then current_ui=$(cat /etc/mihomo/.ui_type)
        elif grep -qi "metacubexd" /etc/mihomo/ui/index.html 2>/dev/null; then current_ui="Metacubexd"
        elif grep -qi "zashboard" /etc/mihomo/ui/index.html 2>/dev/null; then current_ui="Zashboard"; fi

        echo -e "\n${CYAN}--- Web 面板设置 ---${NC}"
        echo -e "当前安装的面板: ${CYAN}${current_ui}${NC}\n"
        echo "1. ⬆️  当前 Web 面板更新至最新版"
        echo "2. 🔄 切换为其他 Web 面板"; echo "0. 返回主菜单"
        read -p "请选择: " ui_choice

        case $ui_choice in
            1)
                if [ "$current_ui" == "未知面板" ]; then echo -e "${RED}未知面板，请直接选择切换重装。${NC}"; pause_to_return; continue; fi
                read -p "确认更新 ${current_ui} 吗？[y/N]: " conf
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    setup_temp_gw; 
                    [ -d /etc/mihomo/ui ] && mv /etc/mihomo/ui /etc/mihomo/ui.bak
                    mkdir -p /etc/mihomo/ui
                    
                    local url=""
                    if [ "$current_ui" == "Metacubexd" ]; then url="https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
                    elif [ "$current_ui" == "Zashboard" ]; then url="https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"; fi
                    
                    download_with_progress "$url" "/tmp/ui.zip" "更新 Web 面板"
                    unzip -q /tmp/ui.zip -d /tmp/ >/dev/null 2>&1
                    
                    if [ -d /tmp/*-gh-pages ]; then
                        if [ "$current_ui" == "Metacubexd" ]; then cp -r /tmp/metacubexd-gh-pages/* /etc/mihomo/ui/
                        else cp -r /tmp/zashboard-gh-pages/* /etc/mihomo/ui/; fi
                        rm -rf /tmp/*-gh-pages /tmp/ui.zip
                        ensure_mihomo_base_config; patch_ui_api; restore_temp_gw; rm -rf /etc/mihomo/ui.bak
                        echo -e "${GREEN}${current_ui} 更新成功！刷新浏览器 (Ctrl+F5) 查看。${NC}"
                    else
                        echo -e "${RED}下载失败或文件损坏！触发回滚...${NC}"; rm -rf /tmp/ui.zip /etc/mihomo/ui; mv /etc/mihomo/ui.bak /etc/mihomo/ui; restore_temp_gw
                    fi
                fi; pause_to_return ;;
            2)
                if [ "$current_ui" == "Metacubexd" ]; then target="Zashboard"
                elif [ "$current_ui" == "Zashboard" ]; then target="Metacubexd"
                else echo "选择: 1. Metacubexd  2. Zashboard"; read -p "选择: " choice
                    if [ "$choice" == "1" ]; then target="Metacubexd"; elif [ "$choice" == "2" ]; then target="Zashboard"; else continue; fi
                fi

                if [ -n "$target" ]; then
                    read -p "确认切换为 ${target} 吗？[y/N]: " conf
                    if [[ "$conf" =~ ^[Yy]$ ]]; then
                        setup_temp_gw
                        [ -d /etc/mihomo/ui ] && mv /etc/mihomo/ui /etc/mihomo/ui.bak
                        mkdir -p /etc/mihomo/ui
                        
                        local url=""
                        if [ "$target" == "Metacubexd" ]; then url="https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
                        elif [ "$target" == "Zashboard" ]; then url="https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"; fi
                        
                        download_with_progress "$url" "/tmp/ui.zip" "拉取并切换至 $target"
                        unzip -q /tmp/ui.zip -d /tmp/ >/dev/null 2>&1
                        
                        if [ -d /tmp/*-gh-pages ]; then
                            if [ "$target" == "Metacubexd" ]; then cp -r /tmp/metacubexd-gh-pages/* /etc/mihomo/ui/; echo "Metacubexd" > /etc/mihomo/.ui_type
                            else cp -r /tmp/zashboard-gh-pages/* /etc/mihomo/ui/; echo "Zashboard" > /etc/mihomo/.ui_type; fi
                            rm -rf /tmp/*-gh-pages /tmp/ui.zip
                            ensure_mihomo_base_config; patch_ui_api; restore_temp_gw; rm -rf /etc/mihomo/ui.bak
                            echo -e "${GREEN}面板已切换！刷新浏览器 (Ctrl+F5) 查看。${NC}"
                        else
                            echo -e "${RED}下载失败，恢复原面板...${NC}"; rm -rf /tmp/ui.zip /etc/mihomo/ui; mv /etc/mihomo/ui.bak /etc/mihomo/ui; restore_temp_gw
                        fi
                    fi
                fi; pause_to_return ;;
            0|"") break ;;
        esac
    done
}

manage_mihomo() {
    while true; do
        clear
        current_ver=$(/usr/local/bin/mihomo -v 2>/dev/null | awk '{print $2}')
        current_status=$(systemctl is-active mihomo 2>/dev/null)
        if [ "$current_status" == "active" ]; then status_color=$GREEN; else status_color=$RED; fi
        
        local current_mode="未知"
        [ -f /etc/mihomo/.run_mode ] && current_mode=$(cat /etc/mihomo/.run_mode)
        if [ "$current_mode" == "未知" ] && [ -f /etc/mihomo/tproxy-setup.sh ]; then current_mode="TProxy"; fi
        if [ "$current_mode" == "未知" ] && systemctl is-active --quiet mihomo; then current_mode="TUN"; fi

        echo -e "${CYAN}--- Mihomo 管理 ---${NC}"
        echo -e "内核版本: ${CYAN}${current_ver:-未安装}${NC} | 状态: ${status_color}${current_status:-未安装}${NC} | 运行模式: ${YELLOW}${current_mode}${NC}\n"
        
        echo "1. 🔄 更新内核 (防宕机)"
        echo "2. 📝 更新订阅 (防宕机)"
        echo "3. 🗺️  Geo 数据库配置"
        echo "4. 🖥️  Web 面板设置"
        echo "5. 🔀 切换运行模式 (TProxy ⇌ TUN)"
        echo "6. 🛑 关闭"; echo "7. ▶️ 开启"; echo "8. 🔁 重启"
        echo "9. 🗑️  一键彻底清除 Mihomo (恢复纯净系统)"
        echo "10. 📄 查看 Mihomo 运行日志 (实时滚动)"
        echo "11. 👁️  查看当前配置文件 (config.yaml)"
        echo "0. 返回主菜单"
        read -p "选择: " m_choice

        case $m_choice in
            1)
                latest_version=$(curl -sL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
                if [ -z "$latest_version" ]; then echo -e "${RED}获取最新版本号失败，请检查网络！${NC}"; pause_to_return; continue; fi
                if [ "$current_ver" != "$latest_version" ]; then
                    read -p "更新内核并重启? [y/N]: " conf
                    if [[ "$conf" =~ ^[Yy]$ ]]; then
                        setup_temp_gw
                        cp /usr/local/bin/mihomo /usr/local/bin/mihomo.bak; systemctl stop mihomo
                        
                        download_with_progress "https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/mihomo-linux-amd64-v3-${latest_version}.gz" "/tmp/mihomo.gz" "更新云端内核 ${latest_version}"
                        if [ -f "/tmp/mihomo.gz" ]; then
                            gunzip -f /tmp/mihomo.gz && mv /tmp/mihomo /usr/local/bin/mihomo && chmod +x /usr/local/bin/mihomo >/dev/null 2>&1
                        fi
                        
                        if [ -x /usr/local/bin/mihomo ]; then
                            restore_temp_gw; systemctl start mihomo; check_and_rollback "mihomo" "/usr/local/bin/mihomo.bak" "/usr/local/bin/mihomo" "内核"
                        else
                            echo -e "${RED}下载失败，恢复旧内核...${NC}"; rm -f /tmp/mihomo.gz; mv /usr/local/bin/mihomo.bak /usr/local/bin/mihomo; restore_temp_gw; systemctl start mihomo
                        fi
                    fi
                else echo -e "${GREEN}已是最新！${NC}"; fi; pause_to_return ;;
            2)
                echo -e "\n1. 仅重新拉取\n2. 输入新链接并覆盖"
                read -p "选择: " sub_choice
                if [ "$sub_choice" == "1" ] || [ "$sub_choice" == "2" ]; then
                    cp /etc/mihomo/config.yaml /etc/mihomo/config.yaml.bak
                    if [ "$sub_choice" == "1" ]; then [ -f "/etc/mihomo/.sub_url" ] && target_url=$(cat /etc/mihomo/.sub_url) || target_url=""
                    else read -p "输入新链接: " target_url; [ -n "$target_url" ] && echo "$target_url" > /etc/mihomo/.sub_url; fi
                    if [ -n "$target_url" ]; then
                        setup_temp_gw; systemctl stop mihomo
                        
                        download_with_progress "$target_url" "/etc/mihomo/config.yaml" "拉取 Sub-Store 配置"
                        
                        ensure_mihomo_base_config; restore_temp_gw; systemctl start mihomo
                        check_and_rollback "mihomo" "/etc/mihomo/config.yaml.bak" "/etc/mihomo/config.yaml" "配置"
                    fi
                fi; pause_to_return ;;
            3) manage_geo_data ;;
            4) manage_ui ;;
            5)
                local target_mode="TUN"
                [ "$current_mode" == "TUN" ] && target_mode="TProxy"
                echo -e "\n${YELLOW}即将从 [${current_mode}] 模式切换为 [${target_mode}] 模式...${NC}"
                echo -e "${RED}⚠️ 切换模式需要彻底重置系统底层路由规则，并要求你输入对应新模式的订阅链接！${NC}"
                read -p "确认开始切换吗？[y/N]: " conf
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    deploy_mihomo_core "$target_mode" "true"
                fi
                ;;
            6) systemctl stop mihomo; echo -e "${GREEN}已关闭。${NC}"; pause_to_return ;;
            7) systemctl start mihomo; echo -e "${GREEN}已启动。${NC}"; pause_to_return ;;
            8) systemctl restart mihomo; echo -e "${GREEN}已重启。${NC}"; pause_to_return ;;
            9)
                echo -e "${RED}⚠️ 警告：这将会完全卸载 Mihomo 并清空防火墙接管规则！${NC}"
                read -p "是否确认彻底清除？[y/N]: " conf
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    systemctl stop mihomo 2>/dev/null
                    systemctl disable mihomo 2>/dev/null
                    [ -f /etc/mihomo/tproxy-clean.sh ] && bash /etc/mihomo/tproxy-clean.sh 2>/dev/null
                    rm -f /etc/systemd/system/mihomo.service
                    systemctl daemon-reload
                    rm -rf /etc/mihomo
                    rm -f /usr/local/bin/mihomo
                    echo -e "${GREEN}Mihomo 已被彻底清除，系统网络已恢复纯净状态！${NC}"
                fi; pause_to_return ;;
            10)
                echo -e "\n${YELLOW}正在打开 Mihomo 实时运行日志...${NC}"
                echo -e "${CYAN}提示：按下键盘的 [Ctrl + C] 可以退出查看。${NC}"
                sleep 2
                journalctl -u mihomo -f -n 100
                pause_to_return ;;
            11)
                if [ -f /etc/mihomo/config.yaml ]; then
                    echo -e "\n${YELLOW}正在打开配置文件，支持上下键翻页，按 'q' 即可退出查看...${NC}"
                    sleep 1.5
                    less /etc/mihomo/config.yaml
                else
                    echo -e "\n${RED}未找到配置文件 /etc/mihomo/config.yaml！可能是还未成功拉取配置。${NC}"
                fi
                pause_to_return ;;
            0|"") break ;;
        esac
    done
}

network_diagnostics() {
    while true; do
        clear
        echo -e "${CYAN}--- 网络硬核诊断箱 ---${NC}"
        echo "1. 📍 TCPing (精确测试节点端口连通性与延迟)"
        echo "2. 🗺️  NextTrace (高阶路由追踪，查明绕路黑手)"
        echo "0. 返回主菜单"
        read -p "请选择: " diag_choice

        case $diag_choice in
            1)
                echo -e "\n${YELLOW}--- Bash TCPing 测速引擎 ---${NC}"
                read -p "请输入目标 IP 或域名: " target_ip
                read -p "请输入目标端口: " target_port
                if [ -n "$target_ip" ] && [ -n "$target_port" ]; then
                    echo -e "\n${YELLOW}正在通过底层 TCP 握手测试 ${CYAN}$target_ip:$target_port${YELLOW} ... (共测试 5 次)${NC}"
                    for i in {1..5}; do
                        start_time=$(date +%s%3N)
                        timeout 1.5 bash -c "</dev/tcp/$target_ip/$target_port" 2>/dev/null
                        result=$?
                        end_time=$(date +%s%3N)
                        if [ $result -eq 0 ]; then
                            echo -e "来自 ${CYAN}$target_ip${NC} 的 TCP 响应: 端口 ${CYAN}$target_port${NC} ${GREEN}开放${NC}, 延迟 ${GREEN}$((end_time - start_time)) ms${NC}"
                        else
                            echo -e "${RED}连接 $target_ip:$target_port 失败或超时${NC}"
                        fi
                        sleep 1
                    done
                fi
                pause_to_return ;;
            2)
                if ! command -v nexttrace &> /dev/null; then
                    download_with_progress "https://ghproxy.net/https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_amd64" "/usr/local/bin/nexttrace" "拉取 NextTrace 路由追踪引擎"
                    chmod +x /usr/local/bin/nexttrace 2>/dev/null
                fi
                echo -e "\n${YELLOW}--- NextTrace 路由追踪引擎 ---${NC}"
                read -p "请输入需要追踪的目标 IP 或域名: " target_ip
                if [ -n "$target_ip" ]; then
                    echo -e "\n${YELLOW}开始路由追踪 (可按 Ctrl+C 随时中止)...${NC}"
                    nexttrace "$target_ip"
                fi
                pause_to_return ;;
            0|"") break ;;
        esac
    done
}

reboot_system() { read -p "⚠️ 确认重启？[y/N]: " conf; if [[ "$conf" =~ ^[Yy]$ ]]; then reboot; fi; }
shutdown_system() { read -p "⚠️ 确认关机？[y/N]: " conf; if [[ "$conf" =~ ^[Yy]$ ]]; then poweroff; fi; }

# --- 主循环控制 ---
while true; do
    clear
    
    active_iface=$(ip -4 route show default | grep -v "mihomo" | grep -v "tun" | awk '/default/ {print $5}' | head -n 1)
    [ -z "$active_iface" ] && active_iface=$(ip link | awk -F: '$0 !~ "lo|vir|wl|mihomo|tun|^[^0-9]"{print $2;getline}' | head -n 1 | tr -d ' ')
    
    local_ip=$(ip -4 addr show "$active_iface" 2>/dev/null | grep global | awk '{print $2}' | cut -d/ -f1 | head -n 1)
    [ -z "$local_ip" ] && local_ip=$(ip -4 addr show | grep global | grep -v "mihomo" | grep -v "tun" | awk '{print $2}' | cut -d/ -f1 | head -n 1)
    
    local_gw=$(ip -4 route show default | grep -v "mihomo" | grep -v "tun" | awk '/default/ {print $3}' | head -n 1)
    
    cn_status="${RED}未连通${NC}"
    out_status="${RED}未连通${NC}"
    
    ( curl -s -m 1.5 --connect-timeout 1.5 -I http://www.baidu.com >/dev/null ) & pid_cn=$!
    ( curl -x http://127.0.0.1:7890 -s -m 1.5 --connect-timeout 1.5 -I https://www.google.com >/dev/null || curl -s -m 1.5 --connect-timeout 1.5 -I https://www.google.com >/dev/null ) & pid_out=$!
    
    wait $pid_cn && cn_status="${GREEN}已连通${NC}"
    wait $pid_out && out_status="${GREEN}已连通${NC}"

    echo -e "${CYAN}================================================================${NC}"
    echo -e "${YELLOW}                 Lucas Bypass Router (Debian/Ubuntu)            ${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo -e " IP地址: ${CYAN}${local_ip:-未知}${NC}\t网关: ${CYAN}${local_gw:-未设置}${NC}"
    echo -e " 大陆网络连通性: ${cn_status}\t海外网络连通性: ${out_status}"
    echo -e "${CYAN}================================================================${NC}"
    echo "  1. 📦 更新 Linux 系统 & 软件"
    echo "  2. ⚡ 开启 BBR 网络加速 (含网卡硬件极限调优)"
    echo "  3. 🛡️  系统防火墙设置"
    echo "  4. 🌐 系统网络底层修改 (智能向导)"
    echo "  5. 🛣️ 开启 IP 转发 (核心路由功能)"
    echo "  6. 💾 添加 Swap 虚拟内存"
    echo "  7. ⏰ 服务器时间校准 (Asia/Shanghai)"
    echo "  8. 🖥️  PVE QEMU Guest Agent 部署"
    echo "  9. 🚀 一键部署 Mihomo (双核引擎驱动向导)"
    echo " 10. 🛠️  Mihomo 配置与状态管理"
    echo " 11. 🩺 网络硬核诊断箱 (TCPing & 路由追踪)"
    echo " 12. 🔄 重启系统"
    echo " 13. ⛔ 关闭系统"
    echo "  0. ❌ 退出"
    echo -e "${CYAN}================================================================${NC}"
    read -p "请输入 [0-13]: " main_choice

    case $main_choice in
        1) update_system ;; 2) enable_bbr ;; 3) firewall_setup ;; 4) network_modify ;;
        5) enable_forwarding ;; 6) setup_swap ;; 7) sync_time ;; 8) install_qga ;;
        9) deploy_mihomo_menu ;; 10) manage_mihomo ;; 11) network_diagnostics ;;
        12) reboot_system ;; 13) shutdown_system ;;
        0) echo -e "\n${GREEN}安全退出！${NC}"; exit 0 ;; *) sleep 1 ;;
    esac
done