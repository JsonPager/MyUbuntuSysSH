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

# ==================== 每月流量监控 ====================

# 子 shell 隔离关机监控安装器的严格模式、锁、变量及回滚 trap。
traffic_monitor() (
# Ubuntu / Debian, systemd, vnStat 2.x. Upload this single file with LF endings.
set +x
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die '请使用 sudo bash sysenv.sh 执行。'
command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || die '需要运行中的 systemd。'

runner=/usr/local/lib/serverman/traffic_guard.py
config=/etc/serverman-traffic/config.json
if [[ ${1:-install} != install && ( ! -f $runner || ! -f $config ) ]]; then
    die '尚未安装流量监控，请先选择“安装 / 修改流量阈值和 Bark 地址”。'
fi
case ${1:-install} in
    status)
        printf '定时器启用状态：'; systemctl is-enabled serverman-traffic.timer || true
        printf '定时器运行状态：'; systemctl is-active serverman-traffic.timer || true
        exec python3 "$runner" status ;;
    test-bark) exec python3 "$runner" test-bark ;;
    disable)
        systemctl disable --now serverman-traffic.timer
        systemctl stop serverman-traffic.service
        printf '已停用流量关机监控；保留配置及 vnStat 历史数据。\n'
        exit ;;
    install) ;;
    *) die '未知流量监控操作。' ;;
esac

[[ -t 0 && -t 1 ]] || die '安装需要交互式终端。'
[[ -r /etc/os-release ]] || die '无法识别系统。'
. /etc/os-release
[[ $ID == ubuntu || $ID == debian ]] || die '目前支持 Ubuntu / Debian。'
for tool in apt-get flock ip python3; do
    command -v "$tool" >/dev/null || die "缺少命令：$tool"
done

work=$(mktemp -d /run/serverman-traffic-install.XXXXXXXX)
backup= changed=0 committed=0 timer_active=0 timer_enabled=0 vnstat_active=0 vnstat_enabled=0
files=(/etc/vnstat.conf "$runner" "$config"
    /etc/systemd/system/vnstat.service.d/serverman-traffic.conf
    /etc/systemd/system/serverman-traffic.service
    /etc/systemd/system/serverman-traffic.timer)
cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    unset bark
    if (( changed && ! committed )); then
        printf '安装未完成，正在恢复本次修改前的配置。\n' >&2
        systemctl stop serverman-traffic.timer serverman-traffic.service || true
        for path in "${files[@]}"; do
            if [[ -e $backup$path ]]; then
                cp -a -- "$backup$path" "$path" || true
            else
                rm -f -- "$path"
            fi
        done
        systemctl daemon-reload || true
        if (( vnstat_active )); then systemctl restart vnstat.service || true
        else systemctl stop vnstat.service || true; fi
        if (( ! vnstat_enabled )); then systemctl disable vnstat.service || true; fi
        if (( timer_enabled )); then systemctl enable serverman-traffic.timer || true
        else systemctl disable serverman-traffic.timer || true; fi
        if (( timer_active )); then systemctl start serverman-traffic.timer || true; fi
        printf '备份目录：%s；请检查上面的恢复结果。\n' "$backup" >&2
    fi
    rm -rf -- "$work"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

printf '按 UTC 自然月统计指定网卡的 RX + TX；阈值单位 GB（1 GB = 1,000,000,000 字节）。\n'
printf '达到阈值后尝试 Bark 通知并关机；通知失败也会继续关机。\n'
ip -brief link
default_iface=$(ip -o route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
read -r -p "监控的公网网卡 [${default_iface:-请填写}]：" iface
iface=${iface:-$default_iface}
[[ $iface =~ ^[a-zA-Z0-9_.:-]{1,15}$ && $iface != lo && -d /sys/class/net/$iface ]] || die '网卡不存在或名称不合法。'
read -r -p '每月关机阈值（GB，例如 900）：' threshold
read -r -s -p 'Bark 完整地址（隐藏输入）：' bark
printf '\n'
printf '首次安装：补充值填写本月已用但尚未被 vnStat 记录的流量；已有完整统计则填 0。\n'
printf '重新配置：原补充值不会自动沿用，请重新填写；下个月自动不再计入。\n'
read -r -p '当月未记录流量补充值（GB）[0]：' offset
offset=${offset:-0}
# Secret is passed over stdin, never as a command-line argument or printed.
printf '%s\n%s\n%s\n%s\n' "$iface" "$threshold" "$bark" "$offset" |
    python3 -c '
import datetime, decimal, json, re, sys, urllib.parse
iface, threshold, url, offset = sys.stdin.read().splitlines()
def amount(value, positive=False):
    if not re.fullmatch(r"[0-9]{1,9}(\.[0-9]{1,9})?", value):
        raise ValueError("流量必须是非负数字，最多 9 位整数和 9 位小数")
    n = decimal.Decimal(value) * 1000000000
    if positive and n <= 0:
        raise ValueError("阈值必须大于 0")
    return int(n)
try:
    p = urllib.parse.urlsplit(url)
    if (p.scheme != "https" or not p.hostname or p.username or p.password
            or p.query or p.fragment or not p.path.strip("/")
            or any(c.isspace() or ord(c) < 32 for c in url)):
        raise ValueError("Bark 地址须为 HTTPS 服务地址加设备 Key，不能含空白、查询参数或片段")
    p.port
    cfg = dict(interface=iface, threshold_bytes=amount(threshold, True),
               bark_url=url.rstrip("/"), offset_bytes=amount(offset),
               offset_month=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m"))
except ValueError as e:
    sys.exit(str(e) if not str(e).startswith("Port") else "Bark 端口不合法")
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(cfg, f)
' "$work/config.json"
unset bark

if ! command -v vnstat >/dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y vnstat
fi
vnstat --version | head -n 2
vnstat --version | grep -Eq 'vnStat 2\.' || die '需要 vnStat 2.x。'
systemctl cat vnstat.service >/dev/null || die '找不到 vnstat.service。'
[[ -f /etc/vnstat.conf && ! -L /etc/vnstat.conf ]] || die '需要普通文件 /etc/vnstat.conf。'

cat > "$work/traffic_guard.py" <<'PYTHON_RUNNER'
#!/usr/bin/env python3
"""Monthly vnStat quota guard. No credentials in arguments or logs."""
import datetime as dt
import decimal
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

CONFIG = Path('/etc/serverman-traffic/config.json')
LOCK = Path('/run/serverman-traffic.lock')
STATE = Path('/var/lib/serverman-traffic')
VNSTAT_CONFIG = '/etc/vnstat.conf'
UTC = dt.timezone.utc


def run(args):
    return subprocess.run(args, check=True, capture_output=True, text=True,
                          timeout=8, env={**os.environ, 'TZ': 'UTC', 'LC_ALL': 'C'})


def load_config():
    cfg = json.loads(CONFIG.read_text(encoding='utf-8'))
    if (not isinstance(cfg['threshold_bytes'], int) or cfg['threshold_bytes'] <= 0
            or not isinstance(cfg['offset_bytes'], int) or cfg['offset_bytes'] < 0):
        raise ValueError('invalid quota')
    p = urllib.parse.urlsplit(cfg['bark_url'])
    if p.scheme != 'https' or not p.hostname or not p.path.strip('/'):
        raise ValueError('invalid Bark URL')
    return cfg


def usage(cfg, now):
    result = json.loads(run(['vnstat', '--config', VNSTAT_CONFIG, '--json', 'm',
                             '-i', cfg['interface']]).stdout)
    # vnStat 1.x reports KiB; never accept it as a byte-based 2.x database.
    if str(result['jsonversion']) != '2':
        raise ValueError('unsupported vnStat JSON version')
    interfaces = [i for i in result['interfaces'] if i['name'] == cfg['interface']]
    if len(interfaces) != 1:
        raise ValueError('monitored interface not found')
    interface = interfaces[0]
    updated = interface['updated']
    stamp = (dt.datetime.fromtimestamp(updated['timestamp'], UTC)
             if type(updated.get('timestamp')) is int
             else dt.datetime(**updated['date'], **updated['time'], tzinfo=UTC))
    if not -10 <= (now - stamp).total_seconds() <= 180:
        raise ValueError('vnStat database is stale')
    rows = [row for row in interface['traffic']['month']
            if row['date']['year'] == now.year and row['date']['month'] == now.month]
    if len(rows) != 1:
        raise ValueError('current month is not available yet')
    row = rows[0]
    if any(type(row[k]) is not int or row[k] < 0 for k in ('rx', 'tx')):
        raise ValueError('invalid traffic counters')
    offset = cfg['offset_bytes'] if cfg['offset_month'] == now.strftime('%Y-%m') else 0
    return row['rx'] + row['tx'] + offset


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Do not forward a device key to another endpoint.
        return None


def notify(cfg, title, body):
    url = cfg['bark_url'].rstrip('/') + '/' + urllib.parse.quote(title, safe='')
    url += '/' + urllib.parse.quote(body, safe='')
    request = urllib.request.Request(url, headers={'User-Agent': 'ServerMan-Traffic/1'})
    # Ignore proxy environment; keep the HTTPS request bounded, no retries.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    def deadline(signum, frame):
        raise TimeoutError('notification deadline')
    previous = signal.signal(signal.SIGALRM, deadline)
    signal.alarm(6)
    try:
        with opener.open(request, timeout=5) as response:
            payload = json.loads(response.read(65536))
            if response.status != 200 or payload.get('code') != 200:
                raise ValueError('Bark rejected notification')
        return True
    except Exception:
        # urllib exceptions include the full URL (a secret), so never print them.
        print('Bark 通知失败（地址已隐藏）。', file=sys.stderr, flush=True)
        return False
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)


def gb(value):
    return f'{decimal.Decimal(value) / 1000000000:.3f}'


def main(command='check'):
    cfg = load_config()
    if command == 'test-bark':
        return 0 if notify(cfg, '流量监控测试', 'Bark 连通性测试，不执行关机。') else 1
    if command not in ('check', 'status'):
        raise ValueError('invalid command')
    with LOCK.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('另一个安装或检测任务正在执行。', flush=True)
            return 1
        now = dt.datetime.now(UTC)
        used = usage(cfg, now)
        month = now.strftime('%Y-%m')
        summary = (f'{month} UTC，网卡 {cfg["interface"]}，入站+出站 '
                   f'{gb(used)} GB / 阈值 {gb(cfg["threshold_bytes"])} GB')
        print(summary, flush=True)
        if command == 'status' or used < cfg['threshold_bytes']:
            return 0
        print('达到阈值，尝试通知并请求关机。', flush=True)
        # Notification and persistence failures must never suppress shutdown.
        try:
            STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
            marker = STATE / (month + '-notified')
            if not marker.exists() and notify(cfg, '服务器流量达到阈值，即将关机',
                                            socket.gethostname() + '\n' + summary):
                marker.touch(mode=0o600)
        except Exception:
            print('通知状态记录失败，继续关机。', file=sys.stderr, flush=True)
        run(['systemctl', '--no-block', 'poweroff'])
        return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'check'))
    except Exception:
        # Config/command output can contain credentials: log a fixed message only.
        print('流量检测失败：请检查配置、vnStat 服务及当前月份数据；未执行关机。',
              file=sys.stderr, flush=True)
        sys.exit(1)
PYTHON_RUNNER

# Serialise installation with checks. Taking this lock never runs the guard.
exec 9>/run/serverman-traffic.lock
flock -n 9 || die '另一个安装或检测任务正在运行，请稍后重试。'
systemctl is-active --quiet serverman-traffic.timer && timer_active=1
systemctl is-enabled --quiet serverman-traffic.timer 2>/dev/null && timer_enabled=1
systemctl is-active --quiet vnstat.service && vnstat_active=1
systemctl is-enabled --quiet vnstat.service 2>/dev/null && vnstat_enabled=1
backup=$(mktemp -d /var/backups/serverman-traffic.XXXXXXXX)
for path in "${files[@]}"; do
    [[ ! -L $path ]] || die "管理文件是符号链接，停止安装：$path"
    [[ ! -e $path || -f $path ]] || die "管理路径不是普通文件：$path"
    if [[ -e $path ]]; then
        mkdir -p -- "$backup$(dirname "$path")"
        cp -a -- "$path" "$backup$path"
    fi
done
changed=1
if (( timer_active )); then systemctl stop serverman-traffic.timer; fi
if systemctl is-active --quiet serverman-traffic.service; then
    systemctl stop serverman-traffic.service
fi
install -d -m 700 /etc/serverman-traffic /var/lib/serverman-traffic
install -d -m 755 /usr/local/lib/serverman /etc/systemd/system/vnstat.service.d
install -m 600 "$work/config.json" "$config"
install -m 700 "$work/traffic_guard.py" "$runner"
python3 - /etc/vnstat.conf <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
values = dict(UpdateInterval=5, PollInterval=5, SaveInterval=1, MonthRotate=1)
lines = [line for line in p.read_text().splitlines()
         if not line.split() or line.split()[0] not in values]
p.write_text('\n'.join(lines) + '\n\n# Managed by sysenv.sh traffic guard\n' +
             ''.join(f'{k} {v}\n' for k, v in values.items()))
PY
cat > /etc/systemd/system/vnstat.service.d/serverman-traffic.conf <<'UNIT'
[Service]
Environment=TZ=UTC
UNIT
cat > /etc/systemd/system/serverman-traffic.service <<'UNIT'
[Unit]
Description=Monthly vnStat quota guard (Bark and poweroff)
After=network.target vnstat.service
Wants=vnstat.service

[Service]
Type=oneshot
Environment=TZ=UTC
UMask=0077
ExecStart=/usr/bin/python3 /usr/local/lib/serverman/traffic_guard.py check
TimeoutStartSec=30
# systemctl poweroff stops this service too; do not kill its own shutdown request.
UNIT
cat > /etc/systemd/system/serverman-traffic.timer <<'UNIT'
[Unit]
Description=Check monthly traffic every 10 seconds

[Timer]
OnBootSec=15s
OnUnitInactiveSec=10s
AccuracySec=1s
RandomizedDelaySec=0
Unit=serverman-traffic.service

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
# Explicit config bypasses ~/.vnstatrc; existing history is never removed.
if ! vnstat --config /etc/vnstat.conf --dbiflist 1 2>/dev/null | grep -Fxq -- "$iface"; then
    vnstat --config /etc/vnstat.conf --add -i "$iface"
fi
systemctl enable vnstat.service
systemctl restart vnstat.service
systemctl is-active --quiet vnstat.service || die 'vnStat 未能启动。'
systemd-analyze verify /etc/systemd/system/serverman-traffic.service /etc/systemd/system/serverman-traffic.timer
systemctl enable serverman-traffic.timer
printf '已配置：网卡 %s，阈值 %s GB，当月补充 %s GB，Bark 地址已保存（不显示）。\n' "$iface" "$threshold" "$offset"
printf '监控即将启用；若已有统计加补充值达到阈值，首次检测就会关机。\n'
printf '后续管理：系统设置 → 每月流量监控 → 查看状态 / 测试通知 / 停用。\n'
printf '日志：sudo journalctl -u serverman-traffic.service -n 30 --no-pager\n'
printf '配置备份：%s\n' "$backup"
# Release before starting the timer so its first invocation can acquire the lock.
flock -u 9
systemctl start serverman-traffic.timer
committed=1


)

traffic_monitor_menu() {
    local choice status
    while true; do
        printf '\n========== 每月流量监控（vnStat + Bark） ==========\n'
        printf '  1. 安装 / 修改流量阈值和 Bark 地址\n'
        printf '  2. 查看监控状态和本月流量\n'
        printf '  3. 发送 Bark 测试通知（不关机）\n'
        printf '  4. 停用流量关机监控\n'
        printf '  0. 返回系统设置\n'
        read -r -p '请选择 [0-4]：' choice || return 0
        case $choice in
            1) traffic_monitor install ;;
            2) traffic_monitor status ;;
            3) traffic_monitor test-bark ;;
            4) traffic_monitor disable ;;
            0) return 0 ;;
            *) error '无效选项，请输入 0-4。'; continue ;;
        esac
        status=$?
        (( status == 0 )) || error "流量监控操作未完成（退出码：$status），请查看上述原因。"
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
        printf '  8. 每月流量监控（vnStat + Bark）\n'
        printf '  0. 返回主菜单\n'
        read -r -p '请选择 [0-8]：' choice || return 0
        case $choice in
            1) update_system ;;
            2) open_bbr ;;
            3) stop_ufw ;;
            4) set_swap ;;
            5) create_user ;;
            6) iptables_ports_menu ;;
            7) info '清理系统功能暂未实现（保留原菜单入口）。' ;;
            8) traffic_monitor_menu ;;
            0) return 0 ;;
            *) error '无效选项，请输入 0-8。'; continue ;;
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

