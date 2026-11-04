#!/usr/bin/env bash
# Ubuntu / Debian 交互式初始化工具；使用 sudo bash sysenv.sh 执行。
# 远程脚本下载到临时文件，校验下载状态和 Bash 语法后再执行。

DOCKER_NETWORK='mynet'
sysenv_session_dir=''
SSH_USER_SCRIPT_URL='https://raw.githubusercontent.com/JsonPager/MyUbuntuSysSH/refs/heads/main/setup-ssh-user.sh'

# ==================== 通用工具 ====================

info() {
    printf '\n[提示] %s\n' "$*"
}

error() {
    printf '\n[错误] %s\n' "$*" >&2
}

confirm() {
    local answer
    read -r -p "$1 [y/N]：" answer || return 1
    [[ $answer == y || $answer == Y ]]
}

# 子 shell 隔离远程脚本的 exit / trap，不影响主菜单。
# 直接继承终端，支持创建用户脚本的隐藏密码输入和 SSH_CONNECTION。
run_remote_script() (
    local url=$1 title=$2 script_file
    command -v curl >/dev/null 2>&1 || {
        error '缺少 curl，请先安装：apt-get install curl'
        exit 1
    }
    script_file=$(mktemp /tmp/sysenv-script.XXXXXXXX.sh) || exit 1
    trap 'rm -f -- "$script_file"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    info "正在下载：$title"
    if ! curl --fail --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 120 "$url" -o "$script_file"; then
        error '下载失败，未执行远程脚本。'
        exit 1
    fi
    if [[ ! -s $script_file ]] || ! bash -n "$script_file"; then
        error '脚本为空或语法检查失败，已停止执行。'
        exit 1
    fi
    bash "$script_file"
)

# 会话缓存仅存放临时 JWT，不保存登录密码；退出当前 sysenv 时删除。
cleanup_sysenv_session() {
    if [[ -n $sysenv_session_dir ]]; then
        if [[ $sysenv_session_dir =~ ^/run/sysenv-portainer-session\.[A-Za-z0-9_-]+$ && ! -L $sysenv_session_dir ]]; then
            rm -rf -- "$sysenv_session_dir"
        fi
        sysenv_session_dir=''
    fi
}

update_system() {
    info '更新系统软件包'
    apt-get update && apt-get upgrade -y
}

# ==================== 系统设置 ====================

# 替换同名设置，避免重复执行时不断追加配置。
set_sysctl() {
    local key=$1 value=$2 escaped_key
    escaped_key=${key//./\\.}
    touch /etc/sysctl.conf || return 1
    sed -i "/^[[:space:]]*${escaped_key}[[:space:]]*=/d" /etc/sysctl.conf || return 1
    printf '%s = %s\n' "$key" "$value" >> /etc/sysctl.conf || return 1
    sysctl -w "$key=$value"
}

open_bbr() {
    set_sysctl net.core.default_qdisc fq &&
        set_sysctl net.ipv4.tcp_congestion_control bbr &&
        sysctl net.ipv4.tcp_congestion_control
}

stop_ufw() {
    confirm '是否关闭并禁用防火墙？' || return 0
    systemctl stop ufw && systemctl disable ufw || return 1
    if confirm '是否卸载防火墙？'; then
        apt-get remove ufw -y
    fi
}

set_swap() {
    local current_swap swap_size
    current_swap=$(free -m | awk '/^Swap:/ {print $2}')
    [[ $current_swap =~ ^[0-9]+$ ]] || { error '无法读取交换内存信息。'; return 1; }
    if (( current_swap > 0 )); then
        info "已开启交换内存，大小：${current_swap} MB"
        return 0
    fi
    confirm '当前未开启交换内存，是否设置？' || return 0
    if [[ -e /swapfile || -L /swapfile ]]; then
        error '/swapfile 已存在，请先人工核查，避免覆盖已有文件。'
        return 1
    fi
    while true; do
        read -r -p '请输入交换内存大小（MB，正整数）：' swap_size || return 1
        if [[ $swap_size =~ ^[1-9][0-9]*$ ]]; then
            break
        fi
        error '请输入正整数。'
    done
    # 先限制权限，再创建文件；任一步失败均不继续写入 fstab。
    (umask 077; fallocate -l "${swap_size}M" /swapfile) &&
        chmod 600 /swapfile &&
        mkswap /swapfile &&
        swapon /swapfile || {
            error '交换内存设置失败，未更新 fstab；请检查 /swapfile。'
            return 1
        }
    if ! awk '$1=="/swapfile" {found=1} END {exit !found}' /etc/fstab; then
        printf '/swapfile swap swap defaults 0 0\n' >> /etc/fstab || return 1
    fi
    set_sysctl vm.swappiness 50 || return 1
    swapon --show
    free -h
}

# ==================== Docker 管理 ====================

check_docker() {
    command -v docker >/dev/null 2>&1 || { error 'Docker 尚未安装。'; return 1; }
    if ! systemctl is-active --quiet docker; then
        systemctl start docker || { error 'Docker 服务启动失败。'; return 1; }
    fi
    docker info >/dev/null 2>&1 || { error '无法连接 Docker 服务。'; return 1; }
}

check_network() {
    docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1
}

check_docker_and_network() {
    check_docker || return 1
    check_network || { error "Docker 网络 $DOCKER_NETWORK 不存在，请先执行 Docker 管理 → 创建 Docker 网络。"; return 1; }
}

create_docker_network() {
    check_docker || return 1
    if check_network; then
        info "Docker 网络 $DOCKER_NETWORK 已存在。"
        return 0
    fi
    docker network create \
        --driver bridge \
        --ipv6 \
        --subnet f602:fa3f:0:0::/64 \
        --subnet 192.168.0.0/24 \
        --gateway 192.168.0.1 \
        "$DOCKER_NETWORK" && info 'Docker 网络创建完成。'
}

install_docker() {
    run_remote_script \
        'https://raw.githubusercontent.com/JsonPager/MyUbuntuSysSH/refs/heads/main/ubuntu_docker.sh' \
        '安装 Docker'
}

install_portainer() {
    check_docker_and_network || return 1
    if docker container inspect portainer >/dev/null 2>&1; then
        error 'portainer 容器已存在。'
        return 1
    fi
    docker run \
        --privileged=true \
        -itd \
        --restart=always \
        --name=portainer \
        --network="$DOCKER_NETWORK" \
        --ip 192.168.0.6 \
        --ip6 f602:fa3f:0:0::6 \
        -p 9000:9000 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /opt/dockerservice/portainer_data:/data \
        portainer/portainer-ce
}

remove_container() {
    local container_name
    check_docker || return 1
    read -r -p '请输入需要移除的容器名称：' container_name || return 1
    [[ $container_name =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || {
        error '容器名称不合法。'
        return 1
    }
    if ! docker container inspect "$container_name" >/dev/null 2>&1; then
        error "未找到容器：$container_name"
        return 1
    fi
    confirm "确认移除容器 $container_name？" || return 0
    docker stop "$container_name" && docker rm "$container_name" || return 1
    # 不自动递归删除挂载路径，避免误删 Docker socket 或共享目录。
    info '容器已移除，挂载目录和数据卷已保留。'
}

uninstall_docker() {
    confirm '确认卸载 Docker 及相关容器、镜像、卷？' || return 0
    run_remote_script \
        'https://raw.githubusercontent.com/JsonPager/MyUbuntuSysSH/refs/heads/main/undocker.sh' \
        '卸载 Docker'
}

deploy_portainer_stack() {
    if [[ -z $sysenv_session_dir ]]; then
        sysenv_session_dir=$(umask 077; mktemp -d /run/sysenv-portainer-session.XXXXXXXX) || {
            error '无法创建本次会话的临时登录缓存。'
            return 1
        }
    fi
    SYSENV_PORTAINER_SESSION_DIR="$sysenv_session_dir" run_remote_script \
        'https://raw.githubusercontent.com/JsonPager/MyUbuntuSysSH/refs/heads/main/deploy-portainer-stack.sh' \
        '从 Git 部署 Portainer Stack'
}

# ==================== SSH 用户 ====================

create_user() {
    run_remote_script "$SSH_USER_SCRIPT_URL" '创建 SSH 登录用户'
}

# ==================== iptables 端口管理（IPv4） ====================

check_iptables() {
    if ! command -v iptables >/dev/null 2>&1 ||
        ! command -v iptables-save >/dev/null 2>&1; then
        error '缺少 iptables，请先安装：apt-get install iptables'
        return 1
    fi
    iptables -w 10 -S INPUT >/dev/null || {
        error '无法读取 INPUT 链，请检查权限、内核模块或其他程序的锁。'
        return 1
    }
}

show_iptables_ports() {
    check_iptables || return 1
    info 'IPv4 INPUT 链（含规则行号、流量计数及拒绝规则）'
    iptables -w 10 -L INPUT -n -v --line-numbers || return 1
    info 'INPUT 完整规则（可查看端口、协议和来源限制）'
    iptables -w 10 -S INPUT || return 1
    info '这里只查询本机 IPv4 INPUT；IPv6、Docker 转发端口和云安全组需分别检查。'
}

# 查询不安装软件、不写配置；仅在保存时准备持久化组件。
ensure_iptables_persistence() {
    local package status installed=1
    for package in iptables-persistent netfilter-persistent; do
        status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null) || status=
        [[ $status == 'install ok installed' ]] || installed=0
    done
    if (( ! installed )); then
        # iptables-persistent 与 ufw 可能冲突，不能让 apt 自动卸载原防火墙。
        status=$(dpkg-query -W -f='${Status}' ufw 2>/dev/null) || status=
        if [[ $status == 'install ok installed' ]]; then
            error '已安装 UFW，不能自动安装可能冲突的持久化组件；请先人工选择防火墙管理方式。'
            return 1
        fi
        command -v debconf-set-selections >/dev/null 2>&1 || {
            error '缺少 debconf-set-selections，无法安全预设持久化安装选项。'
            return 1
        }
        # 相当于安装界面对保存 IPv4 / IPv6 规则选择 Yes。
        # 安装前由调用方备份现有运行规则及 rules.v4 / rules.v6。
        printf '%s\n' \
            'iptables-persistent iptables-persistent/autosave_v4 boolean true' \
            'iptables-persistent iptables-persistent/autosave_v6 boolean true' |
            debconf-set-selections || return 1
        # 不刷新索引、不升级系统；索引过期时请从系统设置手动更新。
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove \
            iptables-persistent netfilter-persistent; then
            error '组件安装失败；若软件索引过期，请先执行“系统设置 → 更新系统”再重试。'
            return 1
        fi
    fi
    if ! command -v netfilter-persistent >/dev/null 2>&1 ||
        [[ ! -x /usr/share/netfilter-persistent/plugins.d/15-ip4tables ]]; then
        error '持久化组件或 IPv4 保存插件缺失。'
        return 1
    fi
}

check_firewall_manager() {
    local service
    for service in ufw.service firewalld.service nftables.service; do
        if systemctl is-active --quiet "$service"; then
            error "检测到 $service 正在管理规则，请使用对应工具；不会关闭或覆盖该服务。"
            return 1
        fi
    done
}

# 保存前备份整套现行规则和已有持久化文件。备份目录仅 root 可访问。
backup_iptables() {
    local backup
    install -d -m 700 /var/backups/sysenv-iptables || return 1
    backup=$(mktemp -d /var/backups/sysenv-iptables/rules-XXXXXXXX) || return 1
    if ! iptables-save > "$backup/live.v4"; then
        error "备份 IPv4 运行规则失败：$backup"
        return 1
    fi
    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > "$backup/live.v6" || {
            error "备份 IPv6 运行规则失败：$backup"
            return 1
        }
    fi
    local version
    for version in v4 v6; do
        if [[ -e /etc/iptables/rules.$version || -L /etc/iptables/rules.$version ]]; then
            [[ -f /etc/iptables/rules.$version && ! -L /etc/iptables/rules.$version ]] || {
                error '持久化文件不是普通文件，请人工核查。'
                return 1
            }
            cp -a -- "/etc/iptables/rules.$version" "$backup/saved.$version" || return 1
        fi
    done
    info "规则备份：$backup"
}

# 只归零链声明中的动态计数；保留规则、顺序及规则注释的原文。
normalize_iptables_rules() {
    awk '
        /^[[:space:]]*#/ { next }
        /^:/ && NF == 3 && $3 ~ /^\[[0-9]+:[0-9]+\]$/ { $3 = "[0:0]" }
        { print }
    ' "$1"
}

persist_iptables() {
    local snapshot
    # save 会保存当前整套规则，而不只是这次新增的端口。
    netfilter-persistent save || {
        error '保存失败；当前运行规则仍生效，但未确认重启后保留，请勿直接重启服务器。'
        return 1
    }
    [[ -s /etc/iptables/rules.v4 ]] || {
        error '保存命令未生成有效的 /etc/iptables/rules.v4。'
        return 1
    }
    snapshot=$(mktemp /tmp/sysenv-iptables-check.XXXXXXXX) || return 1
    if ! iptables-save > "$snapshot"; then
        rm -f -- "$snapshot"
        return 1
    fi
    # 时间注释及链计数会随流量变化；忽略这些字段比较实际规则。
    if ! diff -q \
        <(normalize_iptables_rules "$snapshot") \
        <(normalize_iptables_rules /etc/iptables/rules.v4) >/dev/null; then
        rm -f -- "$snapshot"
        error '磁盘规则与当前规则不一致，可能禁止了保存或有其他程序并发修改；请检查后重新保存。'
        return 1
    fi
    rm -f -- "$snapshot"
    if ! systemctl enable netfilter-persistent ||
        ! systemctl is-enabled --quiet netfilter-persistent; then
        error '规则已保存，但启用开机恢复失败，请检查服务。'
        return 1
    fi
    info 'IPv4 规则已核对保存到 /etc/iptables/rules.v4，已启用开机恢复。'
    info '未执行 start/reload，避免加载旧规则；本操作不改变 IPv6 的运行规则。'
}

# 子 shell 限制锁和 umask 的作用范围，不影响主菜单。
add_iptables_ports() (
    umask 077
    local protocol input token port proto check_status
    local -a ports=() protocols=()
    local -A seen=()
    check_iptables && check_firewall_manager || return 1
    read -r -p '协议 [tcp/udp/both，默认 tcp]：' protocol || return 1
    case ${protocol:-tcp} in
        tcp|TCP) protocols=(tcp) ;;
        udp|UDP) protocols=(udp) ;;
        both|BOTH) protocols=(tcp udp) ;;
        *) error '协议只能是 tcp、udp 或 both。'; return 1 ;;
    esac
    read -r -p '端口号（多个用空格或逗号分隔，例如 80,443,81）：' input || return 1
    input=${input//,/ }
    read -r -a ports <<< "$input"
    (( ${#ports[@]} > 0 )) || { error '至少输入一个端口。'; return 1; }
    for token in "${ports[@]}"; do
        [[ $token =~ ^[0-9]{1,5}$ ]] || { error "端口不合法：$token"; return 1; }
        port=$((10#$token))
        (( port >= 1 && port <= 65535 )) || { error "端口超出 1-65535：$token"; return 1; }
        seen[$port]=1
    done
    ports=("${!seen[@]}")
    info "IPv4：将对所有来源放行 ${protocols[*]} 端口 ${ports[*]}。"
    info '新规则插入 INPUT 第 1 行，优先于现有拒绝规则；保存会写入当前整套 IPv4/IPv6 规则。'
    confirm '确认添加并自动保存？' || return 0
    command -v flock >/dev/null 2>&1 || { error '缺少 flock。'; return 1; }
    exec 8>/run/sysenv-iptables.lock || return 1
    flock -n 8 || { error '另一个端口管理操作正在执行。'; return 1; }
    backup_iptables && ensure_iptables_persistence || return 1
    for proto in "${protocols[@]}"; do
        for port in "${ports[@]}"; do
            # 检查相同的不限制来源的 ACCEPT 规则，避免重复添加。
            if iptables -w 10 -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
                info "已有 $proto/$port 的允许规则，跳过；如仍无法访问，请检查前序限制。"
            else
                check_status=$?
                (( check_status == 1 )) || { error '检查已有规则失败。'; return 1; }
                if ! iptables -w 10 -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT; then
                    error '添加失败；尝试保存本次已成功添加的部分规则，请核对后重试。'
                    persist_iptables || true
                    return 1
                fi
                info "已添加 $proto/$port。"
            fi
        done
    done
    persist_iptables
)

# 仅按完整规则描述删除，不按易变的行号删除；不会删除来源受限、
# multiport、带额外条件或其他链中的规则，也不会额外插入 DROP 规则。
delete_iptables_ports() (
    umask 077
    local protocol input token port proto check_status removed=0
    local ssh_port extra
    local -a ports=() protocols=()
    local -A seen=()
    check_iptables && check_firewall_manager || return 1
    read -r -p '协议 [tcp/udp/both，默认 tcp]：' protocol || return 1
    case ${protocol:-tcp} in
        tcp|TCP) protocols=(tcp) ;;
        udp|UDP) protocols=(udp) ;;
        both|BOTH) protocols=(tcp udp) ;;
        *) error '协议只能是 tcp、udp 或 both。'; return 1 ;;
    esac
    read -r -p '删除哪些允许端口（多个用空格或逗号分隔）：' input || return 1
    input=${input//,/ }
    read -r -a ports <<< "$input"
    (( ${#ports[@]} > 0 )) || { error '至少输入一个端口。'; return 1; }
    for token in "${ports[@]}"; do
        [[ $token =~ ^[0-9]{1,5}$ ]] || { error "端口不合法：$token"; return 1; }
        port=$((10#$token))
        (( port >= 1 && port <= 65535 )) || { error "端口超出 1-65535：$token"; return 1; }
        seen[$port]=1
    done
    ports=("${!seen[@]}")
    # sudo 不一定保留 SSH_CONNECTION；只对明确识别出的当前管理端口拦截。
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        read -r _ _ _ ssh_port extra <<< "$SSH_CONNECTION"
        if [[ -z ${extra:-} && ${ssh_port:-} =~ ^[0-9]{1,5}$ ]]; then
            ssh_port=$((10#$ssh_port))
            for proto in "${protocols[@]}"; do
                if [[ $proto == tcp && -n ${seen[$ssh_port]:-} ]]; then
                    error "拒绝删除当前 SSH 会话使用的 TCP/$ssh_port，避免失去后续连接能力。"
                    return 1
                fi
            done
        fi
    fi
    info "将删除 IPv4 INPUT 中 ${protocols[*]} 端口 ${ports[*]} 的无来源限制、无额外条件 ACCEPT 规则（含重复项）。"
    info '请核对 SSH 管理端口并保持当前会话；删除允许规则不等于强制封禁，最终结果取决于其他规则和默认策略。'
    confirm '确认删除这些允许规则并自动保存？' || return 0
    command -v flock >/dev/null 2>&1 || { error '缺少 flock。'; return 1; }
    exec 8>/run/sysenv-iptables.lock || return 1
    flock -n 8 || { error '另一个端口管理操作正在执行。'; return 1; }
    backup_iptables && ensure_iptables_persistence || return 1
    for proto in "${protocols[@]}"; do
        for port in "${ports[@]}"; do
            while true; do
                if iptables -w 10 -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
                    if ! iptables -w 10 -D INPUT -p "$proto" --dport "$port" -j ACCEPT; then
                        error '删除失败；尝试保存已完成的部分操作，请核对后重试。'
                        persist_iptables || true
                        return 1
                    fi
                    removed=$((removed + 1))
                    info "已删除 $proto/$port 的一条允许规则。"
                else
                    check_status=$?
                    if (( check_status != 1 )); then
                        error '检查规则失败；尝试保存已完成的部分操作。'
                        persist_iptables || true
                        return 1
                    fi
                    info "$proto/$port 已无匹配的简单允许规则；带来源限制、注释等额外条件的规则请从查询结果中人工核对。"
                    break
                fi
            done
        done
    done
    persist_iptables || return 1
    info "本次删除 $removed 条允许规则，已自动保存。"
)

iptables_ports_menu() {
    local choice status
    while true; do
        printf '\n========== iptables 端口管理（IPv4） ==========\n'
        printf '  1. 查询 INPUT 规则及允许端口\n'
        printf '  2. 添加允许端口并自动保存\n'
        printf '  3. 删除允许端口并自动保存\n'
        printf '  0. 返回系统设置\n'
        read -r -p '请选择 [0-3]：' choice || return 0
        case $choice in
            1) show_iptables_ports ;;
            2) add_iptables_ports ;;
            3) delete_iptables_ports ;;
            0) return 0 ;;
            *) error '无效选项。'; continue ;;
        esac
        status=$?
        (( status == 0 )) || error "操作未完成（退出码：$status），请查看上述原因。"
    done
}

# ==================== 两级菜单入口 ====================

show_menu() {
    printf '\n================================================\n'
    printf '              Linux 环境初始化工具\n'
    printf '================================================\n'
    printf '  1. 系统设置\n'
    printf '  2. Docker 管理\n'
    printf '  0. 退出\n'
    printf '================================================\n'
}

system_settings_menu() {
    local choice status
    while true; do
        printf '\n================ 系统设置 ================\n'
        printf '  1. 更新系统\n'
        printf '  2. 开启 BBR 加速\n'
        printf '  3. 关闭、卸载防火墙\n'
        printf '  4. 开启交换内存\n'
        printf '  5. 创建用户\n'
        printf '  6. iptables 端口管理（IPv4）\n'
        printf '  7. 清理系统\n'
        printf '  0. 返回主菜单\n'
        read -r -p '请选择 [0-7]：' choice || return 0
        case $choice in
            1) update_system ;;
            2) open_bbr ;;
            3) stop_ufw ;;
            4) set_swap ;;
            5) create_user ;;
            6) iptables_ports_menu ;;
            7) info '清理系统功能暂未实现（保留原菜单入口）。' ;;
            0) return 0 ;;
            *) error '无效选项，请输入 0-7。'; continue ;;
        esac
        status=$?
        (( status == 0 )) || error "本次操作未完成（退出码：$status），已返回系统设置。"
    done
}

docker_management_menu() {
    local choice status
    while true; do
        printf '\n================ Docker 管理 ================\n'
        printf '  1. 安装 Docker\n'
        printf '  2. 创建 Docker 网络\n'
        printf '  3. 安装 Portainer Docker 管理工具\n'
        printf '  4. 移除指定容器\n'
        printf '  5. 卸载 Docker 及相关容器、镜像、卷\n'
        printf '  6. 从 Git 部署 Portainer Stack\n'
        printf '  0. 返回主菜单\n'
        read -r -p '请选择 [0-6]：' choice || return 0
        case $choice in
            1) install_docker ;;
            2) create_docker_network ;;
            3) install_portainer ;;
            4) remove_container ;;
            5) uninstall_docker ;;
            6) deploy_portainer_stack ;;
            0) return 0 ;;
            *) error '无效选项，请输入 0-6。'; continue ;;
        esac
        status=$?
        (( status == 0 )) || error "本次操作未完成（退出码：$status），已返回 Docker 管理。"
    done
}

main() {
    local choice
    if (( EUID != 0 )); then
        error '请使用 sudo bash sysenv.sh 或以 root 用户执行。'
        return 1
    fi
    trap cleanup_sysenv_session EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    # 启动只显示菜单。系统更新仅由“系统设置 → 更新系统”显式触发。
    while true; do
        show_menu
        read -r -p '请选择 [0-2]：' choice || { printf '\n'; cleanup_sysenv_session; return 0; }
        case $choice in
            1) system_settings_menu ;;
            2) docker_management_menu ;;
            0) cleanup_sysenv_session; info '已退出。'; return 0 ;;
            *) error '无效选项，请输入 0-2。' ;;
        esac
    done
}

# 直接执行文件或 bash -c/标准输入执行时启动；source 文件时仅加载函数。
# bash -c 没有 BASH_SOURCE，需单独识别，兼容 curl 下载后交给 bash -c 的用法。
if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]:-} == "$0" ]]; then
    main "$@"
fi
