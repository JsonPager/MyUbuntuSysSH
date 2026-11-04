#!/usr/bin/env bash
# 从公共 Git 模板创建 Portainer Web Editor 类型的 Docker Standalone Stack。
# 不执行系统更新，不覆盖已有 Stack；用户名密码换取临时 JWT，不持久保存凭据。
set +x
set -Eeuo pipefail
export LC_ALL=C
umask 077

STACK_REPOSITORY='JsonPager/MyUbuntuSysSH'
STACK_DIRECTORY='stacks'
work='' api_base='' auth_file='' stack_id='' stack_name=''
post_started=0
session_dir='' login_user=''
declare -a tls_options=()

info() { printf '\n[提示] %s\n' "$*"; }
die() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }
confirm() {
    local answer
    read -r -p "$1 [y/N]：" answer || return 1
    [[ $answer == y || $answer == Y ]]
}
cleanup() {
    unset login_password
    [[ -z $work ]] || rm -rf -- "$work"
}
interrupted() {
    if (( post_started )); then
        info "部署请求可能已提交，请到 Portainer 检查 Stack $stack_name；不会自动删除或重复创建。"
    fi
    exit 130
}
trap cleanup EXIT
trap interrupted INT TERM HUP

# 会话缓存仅保留 JWT；父 sysenv 正常退出时负责清除。
setup_session_cache() {
    session_dir=${SYSENV_PORTAINER_SESSION_DIR:-}
    [[ -n $session_dir ]] || return 0
    [[ $session_dir =~ ^/run/sysenv-portainer-session\.[A-Za-z0-9_-]+$ && -d $session_dir && ! -L $session_dir ]] ||
        die '临时登录缓存路径不合法。'
    [[ $(stat -c %u "$session_dir") == 0 && $(stat -c %a "$session_dir") == 700 ]] ||
        die '临时登录缓存权限不安全。'
}
discard_cached_login() {
    [[ -n $session_dir ]] || return 0
    rm -f -- "$session_dir/login.json" "$session_dir/auth.header"
}
save_cached_login() {
    [[ -n $session_dir ]] || return 0
    jq -n --arg url "$api_base" --arg ca "${ca_file:-}" --arg user "$login_user" \
        '{url: $url, ca: $ca, user: $user}' > "$session_dir/login.json.new"
    cp -- "$auth_file" "$session_dir/auth.header.new"
    chmod 600 "$session_dir/login.json.new" "$session_dir/auth.header.new"
    mv -f -- "$session_dir/auth.header.new" "$session_dir/auth.header"
    mv -f -- "$session_dir/login.json.new" "$session_dir/login.json"
}
load_cached_login() {
    local file
    [[ -n $session_dir ]] || return 1
    for file in "$session_dir/login.json" "$session_dir/auth.header"; do
        [[ -f $file && ! -L $file ]] || return 1
        [[ $(stat -c %u "$file") == 0 && $(stat -c %a "$file") == 600 ]] || return 1
    done
    jq -e '(.url | type == "string") and (.ca | type == "string") and (.user | type == "string")' \
        "$session_dir/login.json" >/dev/null 2>&1 || return 1
    [[ $(wc -l < "$session_dir/auth.header") == 1 ]] || return 1
    grep -Eq '^Authorization: Bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$' \
        "$session_dir/auth.header" || return 1
    api_base=$(jq -r '.url' "$session_dir/login.json")
    ca_file=$(jq -r '.ca' "$session_dir/login.json")
    login_user=$(jq -r '.user' "$session_dir/login.json")
    validate_portainer_address
    tls_options=()
    if [[ -n $ca_file ]]; then
        [[ -f $ca_file && -r $ca_file ]] || return 1
        tls_options=(--cacert "$ca_file")
    fi
    auth_file="$work/auth.header"
    cp -- "$session_dir/auth.header" "$auth_file"
}
validate_portainer_address() {
    local authority
    [[ $api_base =~ ^https?://[^/@?#[:space:]]+(/[A-Za-z0-9._~%/-]+)?$ ]] ||
        die '地址格式不合法，请输入 http(s)://主机:端口，可带反向代理子路径。'
    if [[ $api_base == http://* ]]; then
        authority=${api_base#http://}; authority=${authority%%/*}
        [[ $authority =~ ^(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?$ ]] ||
            die '远程 Portainer 请使用 HTTPS；本机可用 http://127.0.0.1:9000。'
    fi
}

# 不跟随重定向，避免把 Portainer 认证头发送到其他地址。
api_request() {
    local method=$1 path=$2 output=$3 body=${4:-} timeout=${5:-30} allow_expired=${6:-0} status
    local -a options=(--silent --show-error --connect-timeout 10 --max-time "$timeout"
        --proto '=http,https' --request "$method" --header "@$auth_file"
        --output "$output" --write-out '%{http_code}')
    if [[ -n $body ]]; then
        options+=(--header 'Content-Type: application/json' --data-binary "@$body")
    fi
    if ! status=$(curl "${options[@]}" "${tls_options[@]}" "$api_base/api$path"); then
        if [[ $method == POST ]] && (( post_started )); then
            info '请求失败或超时，但服务端可能已收到部署请求。请先检查 Portainer，勿直接重复提交。'
        fi
        die '无法完成 Portainer 请求，请检查地址、网络及 HTTPS 证书。'
    fi
    case $status in
        2??) ;;
        401|403)
            discard_cached_login
            if [[ $allow_expired == 1 && $method == GET ]]; then return 77; fi
            die 'Portainer 登录已失效或权限不足，请重新进入部署菜单登录；已提交的部署请先到页面核查。' ;;
        422)
            if [[ $path == /auth ]]; then die 'Portainer 登录失败，请检查用户名和密码；单点登录账号请使用可直接登录的管理员账号。'; fi
            die 'Portainer 拒绝处理此请求，请在页面查看具体原因。' ;;
        409) die 'Portainer 返回冲突，可能已有同名 Stack 或部署正在进行；请到页面检查。' ;;
        3??) die 'Portainer 地址发生重定向，请填写最终服务地址后重试。' ;;
        *) die "Portainer 请求失败（HTTP $status），请在 Portainer 页面或日志中查看原因。" ;;
    esac
    jq -e . "$output" >/dev/null || die 'Portainer 返回了无效 JSON，请检查是否填写了正确的服务地址。'
}

github_get() {
    local url=$1 output=$2
    if ! curl --fail --silent --show-error --proto '=https' --connect-timeout 15 --max-time 60 \
        --header 'Accept: application/vnd.github+json' --user-agent 'sysenv-stack-deployer' \
        "$url" -o "$output"; then
        die 'Git 模板读取失败，可能是网络问题、文件不存在或 GitHub API 限流。'
    fi
    jq -e . "$output" >/dev/null || die 'GitHub 返回了无效 JSON。'
}

# 返回零基序号。用户选择 0 时取消，不会执行 API 写操作。
choose_index() {
    local count=$1 input
    read -r -p "请选择 [1-$count，0 返回]：" input || return 1
    [[ $input =~ ^[0-9]{1,6}$ ]] || die '请选择有效的菜单编号。'
    (( 10#$input != 0 )) || return 1
    (( 10#$input <= count )) || die '菜单编号超出范围。'
    selected_index=$((10#$input - 1))
}

select_template() {
    local name path sha size index selected_index
    local -a names=() paths=() hashes=()
    github_get "https://api.github.com/repos/$STACK_REPOSITORY/contents/$STACK_DIRECTORY?ref=main" "$work/templates.json"
    jq -e 'type == "array"' "$work/templates.json" >/dev/null || die '模板目录格式不正确。'
    jq -r --arg directory "$STACK_DIRECTORY/" '
        sort_by(.name)[] | select(.type == "file") |
        select(.name | test("^[A-Za-z0-9][A-Za-z0-9_.-]*\\.(yml|yaml)$")) |
        select(.path == ($directory + .name)) |
        [.name, .path, .sha, (.size | tostring)] | @tsv
    ' "$work/templates.json" > "$work/templates.tsv"
    while IFS=$'\t' read -r name path sha size; do
        [[ $sha =~ ^[a-f0-9]{40}$ && $size =~ ^[0-9]{1,8}$ ]] || die '模板元数据不合法。'
        (( size > 0 && size <= 1048576 )) || die '模板为空或超过 1 MiB。'
        names+=("$name"); paths+=("$path"); hashes+=("$sha")
    done < "$work/templates.tsv"
    (( ${#names[@]} > 0 )) || die 'stacks/ 下没有可用的 .yml / .yaml 模板。'
    printf '\n========== Git Stack 模板 ==========\n'
    for index in "${!names[@]}"; do printf '  %d. %s\n' "$((index + 1))" "${names[$index]}"; done
    choose_index "${#names[@]}" || return 1
    template_path=${paths[$selected_index]}
    template_sha=${hashes[$selected_index]}
    # 按目录返回的 blob SHA 读取，避免选择和下载之间 main 发生变化。
    github_get "https://api.github.com/repos/$STACK_REPOSITORY/git/blobs/$template_sha" "$work/blob.json"
    jq -e --arg sha "$template_sha" '
        .sha == $sha and .encoding == "base64" and (.content | type == "string")
    ' "$work/blob.json" >/dev/null || die '模板版本或编码校验失败。'
    # GitHub 的 base64 字符串带有换行，需先去掉换行再解码。
    jq -j '.content | gsub("[\r\n]"; "") | @base64d' "$work/blob.json" > "$work/compose.yml" || die '模板 base64 解码失败。'
    [[ -s $work/compose.yml ]] || die '下载的模板为空。'
    default_stack=${names[$selected_index]%.*}
    default_stack=${default_stack,,}
}

login_portainer() {
    local login_password
    info '使用 Portainer 网页登录的用户名和密码即可；新安装的 Portainer 需先在页面创建管理员。'
    local entered_user
    IFS= read -r -p "Portainer 用户名 [${login_user:-admin}]：" entered_user || exit 0
    login_user=${entered_user:-${login_user:-admin}}
    IFS= read -r -s -p 'Portainer 登录密码（隐藏输入，仅本次使用）：' login_password || exit 0
    printf '\n'
    [[ -n $login_password ]] || die '密码不能为空。'
    auth_file="$work/auth.header"
    : > "$auth_file"
    # 用 root 专属临时文件交给 jq，密码不出现在 jq/curl 进程参数或环境中。
    printf '%s' "$login_user" > "$work/login.username"
    printf '%s' "$login_password" > "$work/login.password"
    unset login_password
    jq -n --rawfile username "$work/login.username" --rawfile password "$work/login.password" \
        '{username: $username, password: $password}' > "$work/login.json"
    rm -f -- "$work/login.username" "$work/login.password"
    api_request POST '/auth' "$work/login-response.json" "$work/login.json"
    rm -f -- "$work/login.json"
    jq -e '.jwt | if type == "string" then test("^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$") else false end' \
        "$work/login-response.json" >/dev/null || die '登录接口未返回有效临时凭据，请检查 Portainer 的登录方式。'
    printf 'Authorization: Bearer ' > "$auth_file"
    jq -jr '.jwt' "$work/login-response.json" >> "$auth_file"
    printf '\n' >> "$auth_file"
    rm -f -- "$work/login-response.json"
    save_cached_login
    info 'Portainer 登录成功，本次 sysenv 会话后续部署将复用登录。'
}

connect_portainer() {
    ca_file=''
    setup_session_cache
    if load_cached_login; then
        # 只用 GET 验证缓存；过期重新登录，不自动重试部署 POST。
        if api_request GET '/endpoints?excludeSnapshots=true' "$work/cached-endpoints.json" '' 30 1; then
            info "复用本次会话的 Portainer 登录：$api_base（用户 $login_user），无需再次输入密码。"
            return 0
        fi
        info '之前的临时登录已失效，请重新输入用户名和密码。'
        login_portainer
        return 0
    fi
    discard_cached_login
    read -r -p 'Portainer 地址 [http://127.0.0.1:9000]：' api_base || exit 0
    api_base=${api_base:-http://127.0.0.1:9000}
    api_base=${api_base%/}
    validate_portainer_address
    tls_options=()
    if [[ $api_base == https://* ]]; then
        read -r -p '可信 CA 证书路径 [留空使用系统证书]：' ca_file || exit 0
        if [[ -n $ca_file ]]; then
            [[ -f $ca_file && -r $ca_file ]] || die 'CA 证书不可读。'
            tls_options=(--cacert "$ca_file")
        fi
    fi
    login_user='admin'
    login_portainer
}

select_environment() {
    local selected_index index id name
    local -a ids=() names=()
    api_request GET '/endpoints?excludeSnapshots=true' "$work/endpoints.json"
    jq -e 'type == "array"' "$work/endpoints.json" >/dev/null || die '环境列表格式不正确。'
    jq -r '.[] | select(.Type == 1 or .Type == 2) |
        select((.Id | type) == "number" and .Id > 0) |
        [.Id, (.Name | tojson)] | @tsv' "$work/endpoints.json" > "$work/endpoints.tsv"
    while IFS=$'\t' read -r id name; do
        [[ $id =~ ^[0-9]+$ ]] || die '环境 ID 不合法。'
        ids+=("$id"); names+=("$name")
    done < "$work/endpoints.tsv"
    (( ${#ids[@]} > 0 )) || die '未找到有权限访问的 Docker 环境，请先在 Portainer 中连接 local 环境。'
    printf '\n========== 目标 Docker 环境 ==========\n'
    for index in "${!ids[@]}"; do printf '  %d. %s（ID=%s）\n' "$((index + 1))" "${names[$index]}" "${ids[$index]}"; done
    if (( ${#ids[@]} == 1 )); then selected_index=0; else choose_index "${#ids[@]}" || return 1; fi
    environment_id=${ids[$selected_index]}
    environment_name=${names[$selected_index]}
    api_request GET "/endpoints/$environment_id/docker/info" "$work/docker-info.json"
    jq -e 'type == "object" and (.ServerVersion | type == "string")' "$work/docker-info.json" >/dev/null || die '无法确认该环境为 Docker。'
    jq -e '(.Swarm.LocalNodeState // "inactive") == "inactive"' "$work/docker-info.json" >/dev/null || die '当前入口只支持 Docker Standalone，暂不支持 Swarm / Kubernetes / Edge。'
}

assert_stack_absent() {
    api_request GET '/stacks' "$work/existing-stacks.json"
    jq -e 'type == "array"' "$work/existing-stacks.json" >/dev/null || die 'Stack 列表格式不正确。'
    if jq -e --arg name "$stack_name" --argjson endpoint "$environment_id" '
        any(.[]; .Name == $name and ((.EndpointId // .EndpointID) == $endpoint))
    ' "$work/existing-stacks.json" >/dev/null; then
        die '目标环境已有同名 Stack，请到 Portainer 页面编辑和重建；本脚本不会覆盖。'
    fi
}

wait_for_deployment() {
    local deadline=$((SECONDS + 600)) state
    info '请求已提交，正在等待 Portainer 报告部署结果（最长 10 分钟）……'
    while (( SECONDS < deadline )); do
        api_request GET "/stacks/$stack_id" "$work/stack-status.json"
        jq -e --argjson id "$stack_id" --argjson endpoint "$environment_id" --arg name "$stack_name" '
            .Id == $id and .Name == $name and ((.EndpointId // .EndpointID) == $endpoint)
        ' "$work/stack-status.json" >/dev/null || die '服务端返回的 Stack 身份与目标不一致，请到 Portainer 核查。'
        state=$(jq -r '.Status' "$work/stack-status.json")
        case $state in
            1) return 0 ;;
            3) sleep 3 ;;
            2) die 'Stack 已创建但处于停止状态，请到 Portainer 页面检查。' ;;
            4) die 'Portainer 报告部署失败，请到 Stack 页面查看错误；不会自动删除已有资源。' ;;
            *) die "无法确认部署结果（状态 $state），请到 Portainer 页面检查，勿重复创建。" ;;
        esac
    done
    die '等待部署超时，任务可能仍在后台进行，请到 Portainer 页面检查，勿重复创建。'
}

main() {
    [[ $EUID -eq 0 ]] || die '请使用 sudo bash deploy-portainer-stack.sh。'
    [[ -t 0 ]] || die '请在交互式终端运行，密码需要隐藏输入。'
    command -v curl >/dev/null 2>&1 || die '缺少 curl，请先安装 curl。'
    if ! command -v jq >/dev/null 2>&1; then
        confirm '需要 jq 处理接口数据，是否安装 jq（不更新系统）？' || exit 0
        apt-get install -y --no-remove jq || die 'jq 安装失败；若索引过期，请先执行 系统设置 → 更新系统。'
    fi
    command -v flock >/dev/null 2>&1 || die '缺少 flock。'
    exec 8>/run/sysenv-portainer-stack.lock
    flock -n 8 || die '另一个 Stack 部署操作正在进行。'
    work=$(mktemp -d /tmp/sysenv-portainer.XXXXXXXX)
    select_template || exit 0
    printf '\n========== 模板内容：%s ==========\n' "$template_path"
    cat -- "$work/compose.yml"
    info '该入口按单文件 Compose 创建，可在 Portainer 的 Editor 中编辑。模板依赖的外部网络、路径和环境变量需在目标环境准备。'
    read -r -p "Stack 名称 [$default_stack]：" stack_name || exit 0
    stack_name=${stack_name:-$default_stack}
    [[ $stack_name =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || die 'Stack 名称需以小写字母或数字开头，只含小写字母、数字、下划线或连字符，最多 63 字符。'
    connect_portainer
    select_environment || exit 0
    assert_stack_absent
    info "模板：$STACK_REPOSITORY/$template_path（blob $template_sha）"
    info "目标：$api_base；环境：$environment_name（ID=$environment_id）；Stack：$stack_name"
    confirm '确认创建并部署此 Stack？' || exit 0
    jq -n --arg name "$stack_name" --rawfile compose "$work/compose.yml" \
        '{Name: $name, StackFileContent: $compose, Env: []}' > "$work/create.json"
    post_started=1
    # POST 不自动重试，防止超时后重复创建；使用 string 方式让 YAML 存入 Portainer。
    api_request POST "/stacks/create/standalone/string?endpointId=$environment_id" "$work/create-response.json" "$work/create.json" 600
    stack_id=$(jq -er '.Id | select(type == "number" and . > 0)' "$work/create-response.json") || die '创建请求已返回，但未取得 Stack ID；请到 Portainer 检查，勿重复创建。'
    wait_for_deployment
    api_request GET "/stacks/$stack_id/file" "$work/stored-file.json"
    jq -e '.StackFileContent | type == "string"' "$work/stored-file.json" >/dev/null || die '无法核验 Portainer 存储的 YAML，请到页面检查。'
    jq -j '.StackFileContent' "$work/stored-file.json" > "$work/stored.yml"
    cmp -s "$work/compose.yml" "$work/stored.yml" || die 'Portainer 保存的 YAML 与模板不一致，请到页面核查。'
    post_started=0
    info "Portainer 报告部署完成：$stack_name（ID=$stack_id），YAML 已核对保存。"
    info '请打开 Portainer → Stacks → 对应 Stack → Editor，查看或修改后重新部署；容器运行及健康状态请在页面确认。'
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]:-} == "$0" ]]; then main "$@"; fi
