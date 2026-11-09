#!/usr/bin/env bash
# Ubuntu 22.04 / 24.04, Debian; run interactively with sudo bash.
# Passwords only pass through Bash memory and chpasswd's standard input.
set +x
set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

CONFIG=/etc/ssh/sshd_config
BACKUP_ROOT=/var/backups/setup-ssh-user
backup='' work='' username='' password='' confirmation='' service='' original_user=''
sshd_options=()
service_needs_start=0
created=0 changed=0 committed=0 reload_attempted=0
sudoers_file='' sudoers_stage=''

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

cleanup() {
    local rc=$? restored=1
    trap - EXIT INT TERM HUP
    unset password confirmation
    if (( ! committed )); then
        # 只移除与本次临时文件属于同一 inode 的配置，不覆盖其他人并发写入的文件。
        if [[ -n $sudoers_stage && -e $sudoers_stage && $sudoers_file -ef $sudoers_stage ]]; then
            if ! rm -f -- "$sudoers_file"; then
                restored=0
                info "严重：撤销免密码 sudo 规则失败，请立即人工核查：$sudoers_file"
            fi
        fi
        if (( changed )); then
            # Only this file was changed; never overwrite unrelated Include files.
            if cp -a -- "$backup/ssh/sshd_config" "$CONFIG" && /usr/sbin/sshd "${sshd_options[@]}" -t -f "$CONFIG"; then
                info "已恢复 SSH 配置：$backup/ssh/sshd_config"
                if (( reload_attempted )); then
                    if ! systemctl reload "$service" || ! systemctl is-active --quiet "$service"; then
                        restored=0
                        info '严重：原配置已恢复到磁盘，但恢复 reload 失败。请保持当前会话，手动检查服务。'
                    fi
                fi
            else
                restored=0
                info "严重：自动恢复失败。请保持当前会话，使用备份手动恢复：$backup"
            fi
        fi
        if (( created )); then
            # Home was confirmed absent before useradd; only remove our new account.
            if (( restored )) && userdel -r -- "$username"; then
                info "已回滚新建用户：$username"
            else
                usermod -L -- "$username" || true
                info "新用户未完全删除，已尝试锁定密码，请人工核查：$username"
            fi
        fi
        [[ -z $backup ]] || info "备份保留于：$backup"
        (( rc != 0 )) || rc=1
    fi
    [[ -z $sudoers_stage ]] || rm -f -- "$sudoers_stage"
    [[ -z $work ]] || rm -rf -- "$work"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

[[ $EUID -eq 0 ]] || die '请使用 sudo bash setup-ssh-user.sh 或以 root 执行。'
[[ -t 0 && -t 1 ]] || die '必须在交互式终端执行；不支持管道输入密码。'
for tool in getent useradd userdel usermod chpasswd passwd systemctl flock cmp cp mktemp awk id stat visudo runuser ln chmod install; do
    command -v "$tool" >/dev/null || die "缺少命令：$tool"
done
[[ -x /usr/sbin/sshd && -x /bin/bash ]] || die '需要 OpenSSH Server 和 /bin/bash。'
[[ -f $CONFIG && ! -L $CONFIG ]] || die "配置不存在或是符号链接：$CONFIG；请人工处理。"
[[ $(stat -c %h "$CONFIG") == 1 ]] || die '配置存在硬链接，无法安全修改。'
[[ -r /etc/os-release ]] || die '无法识别系统。'
# /etc/os-release is owned by the OS, not user input.
. /etc/os-release
[[ ${ID:-} == ubuntu || ${ID:-} == debian ]] || die '当前仅支持 Ubuntu / Debian。'
exec 9>/run/setup-ssh-user.lock
flock -n 9 || die '另一个初始化脚本正在执行。'
# /run is volatile; socket activation can leave this directory absent until ssh starts.
[[ ! -L /run/sshd ]] || die '/run/sshd 是符号链接，请人工核查。'
if [[ ! -e /run/sshd ]]; then install -d -o root -g root -m 0755 /run/sshd; fi
for candidate in ssh.service sshd.service; do
    if systemctl is-active --quiet "$candidate"; then service=$candidate; break; fi
done
if [[ -z $service ]]; then
    for candidate in ssh sshd; do
        if systemctl is-active --quiet "$candidate.socket"; then
            service="$candidate.service"
            service_needs_start=1
            break
        fi
    done
fi
[[ -n $service ]] || die '没有运行中的 systemd SSH 服务或 SSH socket；未修改。'
exec_start=$(systemctl show "$service" -p ExecStart --value)
start_args=${exec_start#*argv[]=}
start_args=${start_args%% ;*}
# Exact allowlist for the standard AWS EC2 Instance Connect drop-in. Do not eval
# systemd output or permit arbitrary -o/-f/-p overrides.
aws_start='/usr/sbin/sshd -D -o AuthorizedKeysCommand /usr/share/ec2-instance-connect/eic_run_authorized_keys %u %f -o AuthorizedKeysCommandUser ec2-instance-connect'
case $start_args in
    '/usr/sbin/sshd -D'|'/usr/sbin/sshd -D $SSHD_OPTS'|'/usr/sbin/sshd -D -e') ;;
    "$aws_start"|"$aws_start "'$SSHD_OPTS')
        sshd_options=(-o 'AuthorizedKeysCommand /usr/share/ec2-instance-connect/eic_run_authorized_keys %u %f'
                      -o 'AuthorizedKeysCommandUser ec2-instance-connect') ;;
    *) die '不支持自定义 SSH 启动参数（包括 -f / -o / -p），请人工核对。' ;;
esac
environment_files=$(systemctl show "$service" -p EnvironmentFiles --value)
case $environment_files in
    ''|'/etc/default/ssh (ignore_errors=yes)'|'/etc/default/ssh (ignore_errors=no)') ;;
    *) die 'SSH 服务包含自定义环境文件，请人工核对。' ;;
esac
# Never source /etc/default/ssh. Any nonempty SSHD_OPTS is deliberately refused.
if [[ -f /etc/default/ssh ]] && ! awk '
    /^[[:space:]]*(#|$)/ {next}
    /^[[:space:]]*SSHD_OPTS[[:space:]]*=[[:space:]]*(""|\047\047)?[[:space:]]*(#.*)?$/ {next}
    /SSHD_OPTS/ {bad=1}
    END {exit bad}
' /etc/default/ssh; then
    die '/etc/default/ssh 含非空或无法解析的 SSHD_OPTS。'
fi
environment=$(systemctl show "$service" -p Environment --value)
[[ $environment != *SSHD_OPTS=* ]] || die 'systemd Environment 定义了 SSHD_OPTS，请人工核对。'
/usr/sbin/sshd "${sshd_options[@]}" -t -f "$CONFIG" || die '按服务启动参数检查原 SSH 配置失败；未修改。'
if (( service_needs_start )); then
    info "检测到 SSH socket 按需启动，正在启动 $service（保留 socket 配置）。"
    systemctl start "$service" || die 'SSH 服务启动失败；未创建用户或修改 SSH 配置。'
    systemctl is-active --quiet "$service" || die 'SSH 服务启动后未处于运行状态；未创建用户。'
fi

read -r -p '新用户名（小写字母开头，最多 32 字符）：' username
[[ $username =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die '用户名格式不合法。'
if getent passwd "$username" >/dev/null; then
    die "用户 $username 已存在；为避免改变已有密码和配置，本次不作修改（重复执行安全退出）。"
fi
getent group "$username" >/dev/null && die '同名组已存在，请选择其他用户名。'
home="/home/$username"
[[ ! -e $home && ! -L $home ]] || die "Home 路径已存在：$home"
# 新用户默认拥有所有命令的免密码 sudo；SSH 登录密码仍然保留。
sudoers_file="/etc/sudoers.d/99-setup-ssh-user-$username"
[[ -d /etc/sudoers.d && ! -L /etc/sudoers.d ]] || die 'sudoers.d 不存在或是符号链接；未创建用户。'
[[ $(stat -c %u /etc/sudoers.d) == 0 ]] || die 'sudoers.d 不属于 root；未创建用户。'
sudoers_dir_mode=$(stat -c %a /etc/sudoers.d)
(( (8#$sudoers_dir_mode & 0022) == 0 )) || die 'sudoers.d 可被非 root 用户写入；未创建用户。'
[[ ! -e $sudoers_file && ! -L $sudoers_file ]] || die '存在同名 sudo 规则，请先人工核查；未创建用户。'
visudo -c >/dev/null || die '现有 sudo 配置校验失败；未创建用户。'
getent group sudo >/dev/null || die 'sudo 组不存在，请先安装并配置 sudo；未创建用户。'
command -v sudo >/dev/null || die '尚未安装 sudo，请先安装并配置；未创建用户。'
sudo_enabled=是

# 多条连接只有在客户端地址、服务器地址和端口一致时才算同一核验条件。
# 不会从不同客户端中随意选一条作为“当前连接”。
select_unique_ssh_connection() {
    local remote server client_port server_port extra key previous=''
    connection=
    while read -r remote client_port server server_port extra; do
        [[ -n $remote && -z ${extra:-} ]] || continue
        key="$remote $server $server_port"
        if [[ -n $previous && $key != "$previous" ]]; then connection=; return 1; fi
        previous=$key
        connection="$remote $client_port $server $server_port"
    done <<< "$1"
    [[ -n $connection ]]
}

# 自动识别连接。无法确定真实客户端时，后续使用明确标注的本机静态核验。
detect_ssh_connection() {
    local process_id=${BASHPID:-$$} parent_id entry name sockets state local_endpoint peer_endpoint owners
    local candidate_connection='' depth=0 client_hint=${SSH_CLIENT:-} client_ip='' client_port='' server_port=''
    local terminal_record='' terminal_ip='' candidate_text='' remote server rport lport
    local -a ssh_processes=() related=() hinted=() terminal=() all=()
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        connection=$SSH_CONNECTION
        connection_source='SSH 连接环境'
        return 0
    fi
    while [[ $process_id =~ ^[0-9]+$ ]] && (( process_id > 1 && depth < 64 )); do
        if [[ -r /proc/$process_id/environ ]]; then
            while IFS= read -r -d '' entry; do
                case $entry in
                    SSH_CONNECTION=?*)
                        connection=${entry#SSH_CONNECTION=}
                        connection_source='原终端的 SSH 连接环境'
                        return 0 ;;
                    SSH_CLIENT=?*) [[ -n $client_hint ]] || client_hint=${entry#SSH_CLIENT=} ;;
                esac
            done < "/proc/$process_id/environ"
        fi
        if [[ -r /proc/$process_id/comm ]]; then
            IFS= read -r name < "/proc/$process_id/comm" || name=
            [[ $name != sshd* ]] || ssh_processes+=("$process_id")
        fi
        parent_id=$(awk '$1=="PPid:" {print $2}' "/proc/$process_id/status" 2>/dev/null) || break
        [[ $parent_id != "$process_id" ]] || break
        process_id=$parent_id
        depth=$((depth + 1))
    done
    if [[ -n $client_hint ]]; then
        read -r client_ip client_port server_port _ <<< "$client_hint"
    fi
    if command -v who >/dev/null 2>&1; then
        terminal_record=$(who --ips -m 2>/dev/null) || terminal_record=
        if [[ $terminal_record =~ \(([^()]*)\)[[:space:]]*$ ]]; then
            terminal_ip=${BASH_REMATCH[1]}
        fi
    fi
    command -v ss >/dev/null 2>&1 || return 1
    sockets=$(ss -H -tnp 2>/dev/null) || return 1
    while read -r state _ _ local_endpoint peer_endpoint owners; do
        [[ $state == ESTAB && $owners == *'"sshd'* ]] || continue
        server=${local_endpoint%:*}; server=${server#[}; server=${server%]}
        lport=${local_endpoint##*:}
        remote=${peer_endpoint%:*}; remote=${remote#[}; remote=${remote%]}
        rport=${peer_endpoint##*:}
        candidate_connection="$remote $rport $server $lport"
        all+=("$candidate_connection")
        if [[ -n $client_ip && $remote == "$client_ip" && $rport == "$client_port" && $lport == "$server_port" ]]; then
            hinted+=("$candidate_connection")
        fi
        if [[ -n $terminal_ip && $remote == "$terminal_ip" ]]; then terminal+=("$candidate_connection"); fi
        for process_id in "${ssh_processes[@]}"; do
            if [[ $owners == *"pid=$process_id,"* ]]; then
                related+=("$candidate_connection")
                break
            fi
        done
    done <<< "$sockets"
    printf -v candidate_text '%s\n' "${related[@]}"
    if select_unique_ssh_connection "$candidate_text"; then connection_source='关联 SSH 进程'; return 0; fi
    printf -v candidate_text '%s\n' "${hinted[@]}"
    if select_unique_ssh_connection "$candidate_text"; then connection_source='SSH 客户端信息'; return 0; fi
    printf -v candidate_text '%s\n' "${terminal[@]}"
    if select_unique_ssh_connection "$candidate_text"; then connection_source='当前终端登录记录'; return 0; fi
    printf -v candidate_text '%s\n' "${all[@]}"
    if select_unique_ssh_connection "$candidate_text"; then connection_source='唯一的现有 SSH 核验条件'; return 0; fi
    return 1
}

connection=
connection_source=
if ! detect_ssh_connection; then
    # 控制台 / 脱离原终端时没有可用客户端。取 sshd 配置中的监听端口，
    # 使用回环测试地址作静态比对，绝不把它冒充为真实外部连接。
    configured_port=$(/usr/sbin/sshd "${sshd_options[@]}" -T -f "$CONFIG" | awk '$1=="port" && !found {print $2; found=1}') ||
        die '无法读取 SSH 监听配置；未修改配置。'
    [[ $configured_port =~ ^[0-9]{1,5}$ ]] || die '无法从 sshd 配置中读取监听端口；未修改配置。'
    connection="127.0.0.1 65535 127.0.0.1 $configured_port"
    connection_source='本机静态核验（未识别到真实客户端）'
    info '未识别到可确定的 SSH 客户端，将使用本机测试地址核验配置；不需要填写 IP。'
    info '此检查不能证明外部客户端可以登录，完成后必须保持当前会话并另开终端测试。'
fi
read -r remote_addr remote_port local_addr local_port extra <<< "$connection"
[[ -z ${extra:-} ]] || die '自动识别的 SSH 连接格式异常；未修改配置。'
for address in "$remote_addr" "$local_addr"; do
    [[ $address =~ ^[0-9a-fA-F:.]+$ ]] || die '自动识别的连接地址格式不支持；未修改配置。'
done
for port in "$remote_port" "$local_port"; do
    [[ $port =~ ^[0-9]{1,5}$ ]] &&
        (( 10#$port >= 1 && 10#$port <= 65535 )) || die '自动识别的 SSH 端口不合法；未修改配置。'
done

# loginuid 在 sudo/su 后通常仍保留最初 SSH 登录用户；全部原账户仍会逐一比对。
original_user=${SUDO_USER:-}
if [[ -z $original_user || $original_user == root ]]; then
    original_user=
    login_uid=
    [[ ! -r /proc/self/loginuid ]] || IFS= read -r login_uid < /proc/self/loginuid || true
    if [[ $login_uid =~ ^[0-9]+$ && $login_uid != 4294967295 ]]; then
        original_user=$(getent passwd "$login_uid" | awk -F: 'NR==1 {print $1}') || original_user=
    fi
fi
if [[ -z $original_user ]]; then
    if getent passwd ubuntu >/dev/null; then original_user=ubuntu; else original_user=$(id -un); fi
fi
[[ $original_user =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*\$?$ ]] || die '无法安全识别原有登录用户。'
getent passwd "$original_user" >/dev/null || die '自动识别的原有登录用户不存在。'

# UseDNS=no 时 sshd 使用地址；启用 DNS 时核对反向名称的正向解析。
remote_host=$remote_addr
use_dns=$(/usr/sbin/sshd "${sshd_options[@]}" -T -f "$CONFIG" | awk '$1=="usedns" {print $2}')
if [[ $use_dns == yes ]]; then
    resolved_host=$(getent hosts "$remote_addr" | awk 'NR==1 {print $2}') || resolved_host=
    if [[ -n $resolved_host ]]; then
        resolved_host=${resolved_host,,}
        if ! getent ahosts "$resolved_host" | awk -v address="$remote_addr" '$1==address {found=1} END {exit !found}'; then
            die '无法安全核对客户端 DNS 名称，请检查服务器 DNS 后重试；未修改配置。'
        fi
        remote_host=$resolved_host
    fi
fi
[[ $remote_host =~ ^[a-zA-Z0-9_.:-]+$ ]] || die '自动识别的客户端主机名不合法。'
context="addr=$remote_addr,host=$remote_host,laddr=$local_addr,lport=$local_port"
info "核验来源：$connection_source；$remote_addr → $local_addr:$local_port；原有用户：$original_user"
effective() { /usr/sbin/sshd "${sshd_options[@]}" -T -f "$CONFIG" -C "user=$1,$context"; }
value() { awk -v k="$1" '$1==k {$1=""; sub(/^ /, ""); print; exit}' "$2"; }

work=$(mktemp -d /run/setup-ssh-user.XXXXXXXX)
getent passwd > "$work/passwd.before"
while IFS=: read -r existing _; do
    [[ $existing =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*\$?$ ]] || die '系统含无法安全核验的用户名。'
    effective "$existing" > "$work/before.$existing"
done < "$work/passwd.before"
[[ $(value pubkeyauthentication "$work/before.$original_user") == yes ]] || die '原用户在指定连接条件下未开启公钥认证，请先核对。'
/usr/sbin/sshd "${sshd_options[@]}" -T -f "$CONFIG" > "$work/global.before"

read -r -s -p '新用户密码：' password; printf '\n'
read -r -s -p '再次输入密码：' confirmation; printf '\n'
[[ -n $password && $password == "$confirmation" ]] || die '密码为空或两次输入不一致。'
unset confirmation

install -d -m 700 "$BACKUP_ROOT"
backup=$(mktemp -d "$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S).XXXXXXXX")
# Includes and host keys are backed up too; the directory must remain root-only.
cp -a -- /etc/ssh "$backup/ssh"
cp -a -- /etc/sudoers "$backup/sudoers"
cp -a -- /etc/sudoers.d "$backup/sudoers.d"
cp -- "$work/passwd.before" "$backup/passwd.before"
printf '%s\n%s\n' "$connection_source" "$context" > "$backup/connection-context.txt"
cp -- "$work/global.before" "$backup/global.before"
cp -- "$work/before.$original_user" "$backup/original-user.before"
printf '%s\n' "$original_user" > "$backup/original-user.txt"
useradd -m -U -d "$home" -s /bin/bash -- "$username"
created=1
if [[ $sudo_enabled == 是 ]]; then usermod -aG sudo -- "$username"; fi
# printf is a Bash builtin: password is never a process command-line argument.
if ! printf '%s:%s\n' "$username" "$password" | chpasswd; then
    unset password
    die '设置密码失败（可能不满足 PAM 密码策略）。'
fi
unset password
[[ $(passwd -S "$username" | awk '{print $2}') == P ]] || die '新用户密码未成功启用。'

# 含点号的临时文件不会被 @includedir 当作正式 sudo 规则加载。
# 使用同目录硬链接发布，目标已存在时 ln 会失败，不会覆盖其他配置。
sudoers_stage=$(mktemp /etc/sudoers.d/.setup-ssh-user.XXXXXXXX)
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$username" > "$sudoers_stage"
chmod 0440 "$sudoers_stage"
visudo -cf "$sudoers_stage" >/dev/null || die '新用户 sudo 规则语法错误。'
ln -- "$sudoers_stage" "$sudoers_file" || die '无法安全创建用户 sudo 规则。'
visudo -c >/dev/null || die '完整 sudo 配置校验失败。'
# shellcheck disable=SC2024 # Script already runs as root; redirect stays root-owned.
sudo -l -U "$username" > "$work/sudo.after"
grep -Eq 'NOPASSWD:[[:space:]]*ALL([[:space:]]|$)' "$work/sudo.after" ||
    die '用户免密码 sudo ALL 未生效，请核对 sudoers.d 是否被加载。'
# 强制忽略已有 sudo 认证缓存，实测新用户能否无交互执行 root 命令。
runuser -u "$username" -- sudo -k -n -u root -- /usr/bin/true ||
    die '免密码 sudo 实测失败，可能被其他 sudo 规则覆盖。'
cp -- "$work/sudo.after" "$backup/new-user.sudo"

# Simple user/group glob lists are checked; host/CIDR/negation lists require
# administrator review rather than an approximate authorization decision.
check_access() {
    local file=$1 key list token target matched
    local -a targets
    for key in denyusers allowusers denygroups allowgroups; do
        # sshd -T can print one allow/deny entry per line. Check every entry.
        list=$(awk -v k="$key" '$1==k {$1=""; sub(/^ /, ""); print}' "$file")
        [[ -n $list ]] || continue
        targets=("$username")
        if [[ $key == *groups ]]; then read -r -a targets <<< "$(id -nG "$username")"; fi
        matched=0
        for token in $list; do
            [[ $token =~ ^[a-zA-Z0-9_.*?\$-]+$ ]] || die "$key 含复杂规则（$token），请管理员人工核验；未放宽限制。"
            for target in "${targets[@]}"; do
                # Intentional unquoted RHS implements the supported glob subset.
                # shellcheck disable=SC2053 # Intentional supported glob matching.
                if [[ $target == $token ]]; then matched=1; fi
            done
        done
        if [[ $key == deny* && $matched == 1 ]]; then die "新用户被 $key 拒绝。"; fi
        if [[ $key == allow* && $matched == 0 ]]; then die "新用户不在 $key 允许范围内。"; fi
    done
    local methods method single_password=0
    methods=$(value authenticationmethods "$file")
    for method in $methods; do
        [[ $method != any && $method != password ]] || single_password=1
    done
    (( single_password )) || die "AuthenticationMethods=$methods 不允许单独使用密码；未降低认证要求。"
    [[ $(value forcecommand "$file") == none ]] || die '新用户存在 ForceCommand，无法保证交互登录。'
    [[ $(value chrootdirectory "$file") == none ]] || die '新用户存在 ChrootDirectory，需要人工配置环境。'
    [[ $(value permittty "$file") == yes ]] || die '新用户不允许终端登录。'
    [[ $(value refuseconnection "$file") != yes ]] || die '新用户被 RefuseConnection 拒绝。'
}
effective "$username" > "$work/new.before"
check_access "$work/new.before"
# Refuse stale blocks rather than append duplicates or change an existing rule.
if grep -Fqx "# BEGIN setup-ssh-user: $username" "$CONFIG"; then
    die '存在同名管理段但用户不存在，请先人工核查历史配置。'
fi
cmp -s "$CONFIG" "$backup/ssh/sshd_config" || die '配置在执行期间被其他程序修改。'
changed=1
cat >> "$CONFIG" <<EOF

# BEGIN setup-ssh-user: $username
# Only this new account; preceding global and Match policies remain untouched.
Match User $username
    PasswordAuthentication yes
Match all
# END setup-ssh-user: $username
EOF
/usr/sbin/sshd "${sshd_options[@]}" -t -f "$CONFIG" || die '修改后的 SSH 配置语法错误。'
effective "$username" > "$work/new.after"
[[ $(value passwordauthentication "$work/new.after") == yes ]] || die '已有 Match 规则优先，密码认证未生效；不会覆盖原规则。'
check_access "$work/new.after"
# The sole permitted effective change for the new user is PasswordAuthentication.
awk '$1!="passwordauthentication"' "$work/new.before" > "$work/new.filtered.before"
awk '$1!="passwordauthentication"' "$work/new.after" > "$work/new.filtered.after"
cmp -s "$work/new.filtered.before" "$work/new.filtered.after" || die '新用户的其他安全配置发生变化。'
/usr/sbin/sshd "${sshd_options[@]}" -T -f "$CONFIG" > "$work/global.after"
cmp -s "$work/global.before" "$work/global.after" || die '全局 SSH 配置发生变化。'
count=0
while IFS=: read -r existing _; do
    effective "$existing" > "$work/after.$existing"
    cmp -s "$work/before.$existing" "$work/after.$existing" || die "原有用户 $existing 的实际生效配置发生变化。"
    count=$((count + 1))
done < "$work/passwd.before"
cp -- "$work/new.after" "$backup/new-user.after"
cp -- "$work/after.$original_user" "$backup/original-user.after"
cp -- "$work/global.after" "$backup/global.after"
printf '%s\n' "$username" > "$backup/new-user.txt"
reload_attempted=1
systemctl reload "$service" || die 'SSH reload 失败。'
systemctl is-active --quiet "$service" || die 'reload 后 SSH 服务未运行。'
committed=1
info "创建的用户名：$username"
info "Home 目录：$home"
info "已加入 sudo 组：$sudo_enabled；所有命令免密码 sudo 已验证"
info "免密码 sudo 配置：$sudoers_file（可执行 sudo -i 切换为 root）"
info "SSH 服务状态：$service active，reload 成功"
info "密码认证配置：在上述核验条件下，新用户 PasswordAuthentication yes，允许单独密码认证"
info "原有用户认证配置：$original_user 公钥认证仍开启；$count 个原有账户的生效配置与修改前一致"
info "检查连接条件：$context（其他来源地址/主机名须分别复测）"
info "配置文件备份位置：$backup"
info '配置检查不等于真实登录验证；PAM、网络和外部访问控制仍须实测。'
info '请保持当前 SSH 会话不要关闭，使用新的终端窗口测试新用户的密码登录，确认成功后再退出原有会话。'
