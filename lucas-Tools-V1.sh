#!/bin/bash

# --- 颜色与全局定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 自动 Root 提权 ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}正在获取管理员权限...${NC}"
    exec sudo -p "请输入当前用户的 sudo 密码: " bash "$0" "$@"
    exit 1
fi

if ! command -v curl &> /dev/null || ! command -v wget &> /dev/null || ! command -v unzip &> /dev/null; then
    apt update -y -qq && apt install -y -qq curl wget unzip
fi

# --- 核心环境探测函数 ---
detect_net_manager() {
    if systemctl is-active --quiet systemd-networkd; then echo "systemd-networkd"
    elif command -v netplan &> /dev/null && ls /etc/netplan/*.yaml >/dev/null 2>&1; then echo "Netplan"
    elif systemctl is-active --quiet NetworkManager; then echo "NetworkManager"
    else echo "ifupdown"
    fi
}

pause_to_return() {
    echo -e "\n${CYAN}====================================${NC}"
    read -n 1 -s -r -p "操作结束。按任意键返回主菜单..."
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
        echo -e "${GREEN}${type_msg} 更新成功并稳定运行！${NC}"; rm -f "$backup_file"
    else
        echo -e "${RED}严重：服务启动失败！触发防宕机回滚...${NC}"
        mv -f "$backup_file" "$target_file"; systemctl restart "$service_name"; sleep 2
        if systemctl is-active --quiet "$service_name"; then echo -e "${GREEN}回滚成功：已恢复至上一次状态！${NC}"
        else echo -e "${RED}致命错误：回滚后服务依然无法启动，请查日志！${NC}"; fi
    fi
}

# --- 业务功能函数 ---

# 1. 更新系统
update_system() {
    echo -e "${YELLOW}当前系统版本：${NC}"; cat /etc/os-release | grep PRETTY_NAME; echo ""
    read -p "是否执行系统更新 (apt update && upgrade)? [y/N/0返回]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then apt update -y && apt upgrade -y; echo -e "${GREEN}更新完成！${NC}"; fi
    pause_to_return
}

# 2. 开启 BBR (采用 Sysctl.d 目录，防重启覆盖)
enable_bbr() {
    current_bbr=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    echo -e "${YELLOW}当前拥塞控制算法: ${current_bbr:-未知}${NC}\n"
    if [ "$current_bbr" == "bbr" ]; then
        echo -e "${GREEN}BBR 已经处于开启状态。${NC}"
    else
        read -p "是否开启 BBR 网络加速? [y/N/0返回]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            echo "net.core.default_qdisc=fq" > /etc/sysctl.d/99-lucas-bbr.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-lucas-bbr.conf
            sysctl --system >/dev/null 2>&1
            echo -e "${GREEN}BBR 已开启 (独立配置文件 99-lucas-bbr.conf，重启绝对有效)！${NC}"
        fi
    fi
    pause_to_return
}

# 3. 防火墙设置
firewall_setup() {
    echo -e "${YELLOW}--- 防火墙设置 ---${NC}"
    if command -v ufw &> /dev/null; then fw_type="UFW"; fw_status=$(ufw status | head -n 1)
    elif command -v iptables &> /dev/null; then fw_type="iptables"; fw_status=$(iptables -L INPUT -n | head -n 1)
    else fw_type="未知"; fw_status="未检测到防火墙"
    fi
    echo -e "防火墙环境: ${CYAN}$fw_type${NC} | 状态: ${CYAN}$fw_status${NC}\n"
    
    echo "1. 开启防火墙并放行所有端口 (推荐内网旁路由使用)"
    echo "2. 放行指定端口 (如: 80,443,6001-6008)"
    echo "3. 恢复防火墙默认拦截状态"; echo "0. 返回"
    read -p "请选择: " fw_choice

    case $fw_choice in
        1)
            read -p "确认放行所有端口? [y/N]: " conf
            if [[ "$conf" =~ ^[Yy]$ ]]; then
                if [ "$fw_type" == "UFW" ]; then
                    ufw default allow incoming; ufw default allow outgoing; ufw --force enable
                else
                    iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT; iptables -F
                    apt-get install -y iptables-persistent >/dev/null 2>&1; netfilter-persistent save >/dev/null 2>&1
                fi
                echo -e "${GREEN}所有端口已放行！${NC}"
            fi ;;
        2)
            read -p "请输入端口 (如: 100,6000,6001-6008): " ports
            if [ -n "$ports" ]; then
                if [ "$fw_type" == "UFW" ]; then
                    ufw --force enable; IFS=',' read -ra ADDR <<< "$ports"; for p in "${ADDR[@]}"; do ufw allow "$p"; done
                else
                    IFS=',' read -ra ADDR <<< "$ports"
                    for p in "${ADDR[@]}"; do
                        if [[ "$p" == *-* ]]; then
                            iptables -A INPUT -p tcp --dport "${p%:*}:${p#*:}" -j ACCEPT; iptables -A INPUT -p udp --dport "${p%:*}:${p#*:}" -j ACCEPT
                        else
                            iptables -A INPUT -p tcp --dport "$p" -j ACCEPT; iptables -A INPUT -p udp --dport "$p" -j ACCEPT
                        fi
                    done
                    netfilter-persistent save >/dev/null 2>&1
                fi
                echo -e "${GREEN}指定端口已放行！${NC}"
            fi ;;
        3)
            read -p "确认恢复默认拦截? [y/N]: " conf
            if [[ "$conf" =~ ^[Yy]$ ]]; then
                if [ "$fw_type" == "UFW" ]; then
                    ufw --force reset; ufw default deny incoming; ufw default allow outgoing; ufw --force enable
                else
                    iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT; iptables -F; netfilter-persistent save >/dev/null 2>&1
                fi
                echo -e "${GREEN}已恢复默认状态！${NC}"
            fi ;;
        0|"") return ;;
    esac
    pause_to_return
}

# 4. 网络修改 (底层判断重构)
network_modify() {
    echo -e "${YELLOW}--- 系统网络修改 ---${NC}"
    net_mgr=$(detect_net_manager)
    ipv6_status=$(sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | awk '{print $3}')
    current_ip=$(ip -4 addr show | grep global | awk '{print $2}')
    current_gw=$(ip route show default | awk '/default/ {print $3}')
    
    # DNS 获取逻辑修正
    if systemctl is-active --quiet mihomo; then
        current_dns="[Mihomo 接管中]"
    else
        current_dns=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd "," -)
    fi

    echo -e "当前底层网络管理器: ${CYAN}${net_mgr}${NC}"
    echo -e "当前 IPv6 禁用状态: ${CYAN}${ipv6_status:-0} (1为禁用)${NC}"
    echo -e "当前 IPv4 地址: ${CYAN}${current_ip}${NC}"
    echo -e "当前 默认网关: ${CYAN}${current_gw:-未设置}${NC}"
    echo -e "当前 DNS: ${CYAN}${current_dns}${NC}\n"
    
    echo "1. 一键彻底关闭 IPv6"
    echo "2. 修改 IPv4 地址与默认网关 (智能适配管理器)"
    echo "3. 修改系统基础 DNS (智能适配管理器)"
    echo "0. 返回主菜单"
    read -p "请选择: " net_choice

    case $net_choice in
        1)
            read -p "确认完全禁用 IPv6 吗? [y/N/0返回]: " conf
            if [[ "$conf" =~ ^[Yy]$ ]]; then
                echo "net.ipv6.conf.all.disable_ipv6 = 1" > /etc/sysctl.d/99-lucas-disable-ipv6.conf
                echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.d/99-lucas-disable-ipv6.conf
                echo "net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.d/99-lucas-disable-ipv6.conf
                sysctl --system >/dev/null 2>&1
                echo -e "${GREEN}IPv6 已通过 99-lucas-disable-ipv6.conf 彻底关闭！${NC}"
            fi ;;
        2)
            echo -e "${RED}即将修改 IP/网关！请谨慎操作以防断网。${NC}"
            read -p "确认继续编辑网络配置文件吗? [y/N/0返回]: " conf
            if [[ "$conf" =~ ^[Yy]$ ]]; then
                if [ "$net_mgr" == "systemd-networkd" ]; then
                    echo -e "${YELLOW}检测到 systemd-networkd，请编辑对应网卡的 .network 文件:${NC}"
                    ls -l /etc/systemd/network/
                    read -p "请输入要编辑的文件名 (如 eth0.network): " net_file
                    nano "/etc/systemd/network/$net_file"
                    echo -e "${GREEN}修改保存后，执行 'systemctl restart systemd-networkd' 生效。${NC}"
                elif [ "$net_mgr" == "Netplan" ]; then
                    echo -e "${YELLOW}检测到 Netplan，正在打开 yaml 配置文件:${NC}"
                    net_file=$(ls /etc/netplan/*.yaml | head -n 1)
                    nano "$net_file"
                    echo -e "${GREEN}修改保存后，执行 'netplan apply' 生效。${NC}"
                elif [ "$net_mgr" == "NetworkManager" ]; then
                    echo -e "${YELLOW}检测到 NetworkManager，建议使用 nmtui 图形化配置:${NC}"
                    nmtui
                else
                    echo -e "${YELLOW}检测到 ifupdown，正在打开 interfaces 文件:${NC}"
                    nano /etc/network/interfaces
                    echo -e "${GREEN}修改保存后，执行 'systemctl restart networking' 生效。${NC}"
                fi
            fi ;;
        3)
            read -p "修改 DNS？(注意: 如果启动了 Mihomo，请不要随意修改) [y/N]: " conf
            if [[ "$conf" =~ ^[Yy]$ ]]; then
                if systemctl is-active --quiet systemd-resolved; then
                    echo -e "${YELLOW}检测到 systemd-resolved 正在运行。直接修改 resolv.conf 会被覆盖。${NC}"
                    echo "已自动停止并禁用 systemd-resolved 以防冲突..."
                    systemctl disable --now systemd-resolved; rm -f /etc/resolv.conf
                fi
                echo "nameserver 223.5.5.5" > /etc/resolv.conf
                echo "nameserver 114.114.114.114" >> /etc/resolv.conf
                echo -e "${GREEN}DNS 强制重置为基础 IP，文件已解除软链接绑定。${NC}"
            fi ;;
        0|"") return ;;
    esac
    pause_to_return
}

# 5. 开启 IP 转发 (固化升级)
enable_forwarding() {
    v4_fwd=$(sysctl net.ipv4.ip_forward 2>/dev/null | awk '{print $3}')
    echo -e "${YELLOW}当前 IPv4 转发状态: ${CYAN}${v4_fwd:-0}${YELLOW} (1为开启)${NC}\n"
    echo "1. 仅开启 IPv4 转发 (旁路由必备)"
    echo "2. 同时开启 IPv4 和 IPv6 转发"; echo "0. 返回"
    read -p "请选择: " fwd_choice

    case $fwd_choice in
        1)
            echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-lucas-ipforward.conf; sysctl --system >/dev/null 2>&1
            echo -e "${GREEN}IPv4 转发已开启 (已写入 99-lucas-ipforward.conf)！${NC}" ;;
        2)
            echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-lucas-ipforward.conf
            echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-lucas-ipforward.conf; sysctl --system >/dev/null 2>&1
            echo -e "${GREEN}双栈转发已开启！${NC}" ;;
        0|"") return ;;
    esac
    pause_to_return
}

# 6. Swap 虚拟内存
setup_swap() {
    current_swap=$(free -h | grep Swap | awk '{print $2}')
    echo -e "${YELLOW}当前 Swap 容量: ${CYAN}${current_swap:-0B}${NC}\n"
    read -p "需要设置的 Swap 大小 (单位:G，0返回): " swap_size
    if [[ "$swap_size" =~ ^[1-9][0-9]*$ ]]; then
        fallocate -l ${swap_size}G /swapfile; chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
        sed -i '/\/swapfile/d' /etc/fstab; echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo "vm.swappiness=10" > /etc/sysctl.d/99-lucas-swap.conf; sysctl --system >/dev/null 2>&1
        echo -e "${GREEN}${swap_size}G Swap 创建成功并固化！${NC}"
    fi
    pause_to_return
}

# 7. 服务器时间校准
sync_time() {
    current_tz=$(timedatectl | grep "Time zone" | awk '{print $3}')
    echo -e "当前时区: ${CYAN}${current_tz:-未知}${NC} | 时间: ${CYAN}$(date "+%Y-%m-%d %H:%M:%S")${NC}\n"
    read -p "设置时区为 Asia/Shanghai 并开启 NTP 自动校时? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        timedatectl set-timezone Asia/Shanghai; timedatectl set-ntp true
        echo -e "${GREEN}服务器时间校准完成: $(date "+%Y-%m-%d %H:%M:%S")${NC}"
    fi
    pause_to_return
}

# 8. PVE QEMU Guest Agent 部署
install_qga() {
    if systemctl is-active --quiet qemu-guest-agent; then qga_status="${GREEN}运行中${NC}"
    elif command -v qemu-ga &> /dev/null; then qga_status="${YELLOW}已安装未运行${NC}"
    else qga_status="${RED}未安装${NC}"; fi
    echo -e "QGA 状态: ${qga_status}\n"

    if ! systemctl is-active --quiet qemu-guest-agent; then
        read -p "部署 QEMU Guest Agent? [y/N]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            apt update -y -qq && apt install -y qemu-guest-agent; systemctl enable --now qemu-guest-agent
            echo -e "${GREEN}部署成功，已开机自启！${NC}"
        fi
    fi
    pause_to_return
}

# 9. 一键初始部署 Mihomo (彻底解决无网络问题)
deploy_mihomo() {
    echo -e "${YELLOW}====== 开始 Mihomo 自动化初始部署 ======${NC}"
    if systemctl is-active --quiet mihomo; then
        echo -e "${RED}Mihomo 已在运行！请使用主菜单选项 10。${NC}"; pause_to_return; return
    fi
    
    # 【核心修复1】强制开启 IP 转发，防止手机无网
    echo "-> 正在强制开启系统内核 IP 转发功能..."
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-lucas-ipforward.conf
    sysctl --system >/dev/null 2>&1
    
    # 【核心修复2】强制放行 iptables 转发规则，解决默认 DROP 导致的网关断网
    if command -v iptables &> /dev/null; then
        echo "-> 正在调整 iptables 转发策略..."
        iptables -P FORWARD ACCEPT
        apt-get install -y iptables-persistent >/dev/null 2>&1
        netfilter-persistent save >/dev/null 2>&1 || true
    fi

    # 释放 53 端口
    echo "-> 释放 53 端口..."
    if systemctl is-active --quiet systemd-resolved; then
        systemctl disable --now systemd-resolved
        rm -f /etc/resolv.conf; echo "nameserver 223.5.5.5" > /etc/resolv.conf
    fi

    # 下载安装
    mkdir -p /etc/mihomo
    latest_version=$(curl -sL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    echo -e "拉取云端内核: ${CYAN}$latest_version${NC}"
    wget -q --show-progress -O /tmp/mihomo.gz "https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/mihomo-linux-amd64-v3-${latest_version}.gz"
    gunzip -f /tmp/mihomo.gz; mv /tmp/mihomo /usr/local/bin/mihomo; chmod +x /usr/local/bin/mihomo

    # 配置文件
    echo -e "\n-> 配置文件部署"
    read -p "请输入包含 TUN 设置的 Substore 订阅链接: " sub_url
    if [ -n "$sub_url" ]; then
        curl -sL -o /etc/mihomo/config.yaml "$sub_url"; echo "$sub_url" > /etc/mihomo/.sub_url
    else
        echo -e "${RED}必须输入配置链接！中止。${NC}"; pause_to_return; return
    fi

    # 守护进程
    cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo Daemon
After=network.target

[Service]
Type=simple
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
Restart=always
ExecStartPre=/usr/bin/sleep 1s
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable mihomo

    # 面板
    echo -e "\n-> 图形化 Web 面板部署"
    echo "1. Metacubexd (推荐)"; echo "2. Zashboard"
    read -p "请选择: " ui_choice
    mkdir -p /etc/mihomo/ui
    if [ "$ui_choice" == "1" ]; then
        wget -q -O /tmp/ui.zip "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
        unzip -q /tmp/ui.zip -d /tmp/; cp -r /tmp/metacubexd-gh-pages/* /etc/mihomo/ui/
    elif [ "$ui_choice" == "2" ]; then
        wget -q -O /tmp/ui.zip "https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"
        unzip -q /tmp/ui.zip -d /tmp/; cp -r /tmp/zashboard-gh-pages/* /etc/mihomo/ui/
    fi
    rm -rf /tmp/ui.zip /tmp/*-gh-pages

    systemctl start mihomo
    check_and_rollback "mihomo" "" "" "部署完成"
    current_ip=$(ip -4 addr show | grep global | awk '{print $2}' | cut -d/ -f1 | head -n 1)
    echo -e "\n${GREEN}底层网络环境已自动优化！面板地址: http://${current_ip}:9090/ui${NC}"
    pause_to_return
}

# 10. Mihomo 配置管理
manage_mihomo() {
    while true; do
        clear
        current_ver=$(/usr/local/bin/mihomo -v 2>/dev/null | awk '{print $2}')
        current_status=$(systemctl is-active mihomo 2>/dev/null)
        if [ "$current_status" == "active" ]; then status_color=$GREEN; else status_color=$RED; fi
        
        echo -e "${CYAN}--- Mihomo 配置与管理 ---${NC}"
        echo -e "内核版本: ${CYAN}${current_ver:-未安装}${NC} | 状态: ${status_color}${current_status:-未安装}${NC}\n"
        echo "1. 🔄 更新内核 (防宕机)"; echo "2. 📝 更新订阅链接 (防宕机)"
        echo "3. 🛑 关闭"; echo "4. ▶️ 开启"; echo "5. 🔁 重启"; echo "0. 返回"
        read -p "请选择: " m_choice

        case $m_choice in
            1)
                latest_version=$(curl -sL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
                echo -e "\n最新版本: ${CYAN}$latest_version${NC}"
                if [ "$current_ver" != "$latest_version" ]; then
                    read -p "更新内核并重启? [y/N]: " conf
                    if [[ "$conf" =~ ^[Yy]$ ]]; then
                        cp /usr/local/bin/mihomo /usr/local/bin/mihomo.bak; systemctl stop mihomo
                        wget -q --show-progress -O /tmp/mihomo.gz "https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/mihomo-linux-amd64-v3-${latest_version}.gz"
                        gunzip -f /tmp/mihomo.gz; mv /tmp/mihomo /usr/local/bin/mihomo; chmod +x /usr/local/bin/mihomo
                        systemctl start mihomo; check_and_rollback "mihomo" "/usr/local/bin/mihomo.bak" "/usr/local/bin/mihomo" "内核"
                    fi
                else echo -e "${GREEN}已是最新版本！${NC}"; fi; pause_to_return ;;
            2)
                echo -e "\n1. 仅重新拉取当前链接\n2. 输入新链接并覆盖\n0. 返回"
                read -p "请选择: " sub_choice
                if [ "$sub_choice" == "1" ] || [ "$sub_choice" == "2" ]; then
                    cp /etc/mihomo/config.yaml /etc/mihomo/config.yaml.bak
                    if [ "$sub_choice" == "1" ]; then
                        [ -f "/etc/mihomo/.sub_url" ] && target_url=$(cat /etc/mihomo/.sub_url) || { echo -e "${RED}无历史链接！${NC}"; target_url=""; }
                    else
                        read -p "输入新链接: " target_url; [ -n "$target_url" ] && echo "$target_url" > /etc/mihomo/.sub_url
                    fi
                    if [ -n "$target_url" ]; then
                        systemctl stop mihomo; curl -sL -o /etc/mihomo/config.yaml "$target_url"
                        systemctl start mihomo; check_and_rollback "mihomo" "/etc/mihomo/config.yaml.bak" "/etc/mihomo/config.yaml" "配置"
                    fi
                fi; pause_to_return ;;
            3) systemctl stop mihomo; echo -e "${GREEN}已关闭。${NC}"; pause_to_return ;;
            4) systemctl start mihomo; echo -e "${GREEN}已启动。${NC}"; pause_to_return ;;
            5) systemctl restart mihomo; echo -e "${GREEN}已重启。${NC}"; pause_to_return ;;
            0|"") break ;;
        esac
    done
}

# 11 & 12 系统操作
reboot_system() { read -p "⚠️ 确认重启系统？连接将断开！[y/N]: " conf; if [[ "$conf" =~ ^[Yy]$ ]]; then reboot; fi; }
shutdown_system() { read -p "⚠️ 确认关机？需 PVE 手动开机！[y/N]: " conf; if [[ "$conf" =~ ^[Yy]$ ]]; then poweroff; fi; }

# --- 主循环控制 ---
while true; do
    clear
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${YELLOW}      Lucas Bypass Router (Debian TUN)        ${NC}"
    echo -e "${CYAN}==============================================${NC}"
    echo "  1. 📦 更新 Debian 系统 & 软件"
    echo "  2. ⚡ 开启 BBR 网络加速 (防 Cloudinit 覆盖)"
    echo "  3. 🛡️  系统防火墙设置"
    echo "  4. 🌐 系统网络底层修改 (智能检测网管工具)"
    echo "  5. 🛣️ 开启 IP 转发 (核心路由功能)"
    echo "  6. 💾 添加 Swap 虚拟内存"
    echo "  7. ⏰ 服务器时间校准 (Asia/Shanghai)"
    echo "  8. 🖥️  PVE QEMU Guest Agent 部署"
    echo "  9. 🚀 一键部署 Mihomo (彻底修复透明网关断网)"
    echo " 10. 🛠️  Mihomo 配置与状态管理"
    echo " 11. 🔄 重启系统"
    echo " 12. ⛔ 关闭系统"; echo "  0. ❌ 退出"
    echo -e "${CYAN}==============================================${NC}"
    read -p "请输入 [0-12]: " main_choice

    case $main_choice in
        1) update_system ;; 2) enable_bbr ;; 3) firewall_setup ;; 4) network_modify ;;
        5) enable_forwarding ;; 6) setup_swap ;; 7) sync_time ;; 8) install_qga ;;
        9) deploy_mihomo ;; 10) manage_mihomo ;; 11) reboot_system ;; 12) shutdown_system ;;
        0) echo -e "\n${GREEN}安全退出！${NC}"; exit 0 ;; *) sleep 1 ;;
    esac
done
