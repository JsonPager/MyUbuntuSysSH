#!/usr/bin/env bash
# 配置并安装 Docker，软件索引统一由系统设置菜单更新。

configure_docker_source() (
    local suite=$1 arch=$2 key=/etc/apt/keyrings/docker.asc
    local uri=https://download.docker.com/linux/ubuntu
    local targets entry source line staged='' key_tmp='' apt_errors backup
    trap '[[ -z $staged ]] || rm -f -- "$staged"; [[ -z $key_tmp ]] || rm -f -- "$key_tmp"' EXIT
    apt_errors=$(mktemp) || return 1
    # APT 会展开这些字段占位符。
    # shellcheck disable=SC2016
    if ! targets=$(LC_ALL=C apt-get indextargets --no-release-info \
        --format '$(REPO_URI)|$(RELEASE)|$(SOURCESENTRY)' 2>"$apt_errors"); then
        cat "$apt_errors" >&2
        rm -f -- "$apt_errors"
        return 1
    fi
    # APT may collapse duplicate source entries into one index target.
    entry=$(awk -F'|' '$1 ~ /^https?:\/\/download\.docker\.com\/linux\/ubuntu\/?$/ { print $2 "|" $3 }' <<< "$targets" | sort -u)
    if [[ -n $entry ]] && grep -q 'configured multiple times' "$apt_errors"; then
        cat "$apt_errors" >&2
        rm -f -- "$apt_errors"
        echo 'APT 有重复的软件源配置，请先按上述文件位置核对 Docker 源。' >&2
        return 1
    fi
    rm -f -- "$apt_errors"

    if [[ -n $entry ]]; then
        if [[ $entry == *$'\n'* || ${entry%%|*} != "$suite" ]]; then
            echo 'Docker 软件源存在多个配置或发行代号与当前 Ubuntu 不一致，请先核对。' >&2
            printf '%s\n' "$entry" >&2
            return 1
        fi
        entry=${entry#*|}
        source=${entry%:*}
        line=${entry##*:}
        [[ $line =~ ^[1-9][0-9]*$ && -f $source && ! -L $source ]] || return 1
        staged=$(mktemp "${source}.sysenv.XXXXXXXX") || return 1
        case $source in
            *.list)
                awk -v n="$line" -v key="$key" -v uri="$uri" '
                    NR == n {
                        if ($0 !~ /^[[:space:]]*deb[[:space:]]/ || !index($0, uri)) exit 2
                        if ($0 !~ /[[:space:]\[]signed-by=/) {
                            if ($0 ~ /^[[:space:]]*deb[[:space:]]+\[/)
                                sub(/\[/, "[signed-by=" key " ")
                            else sub(/deb[[:space:]]+/, "deb [signed-by=" key "] ")
                        }
                    }
                    { print }
                    END { if (NR < n) exit 2 }
                ' "$source" > "$staged" || return 1
                ;;
            *.sources)
                # 只迁移 Docker 独立 stanza，保留其他源及已有的签名设置。
                awk -v key="$key" -v uri="$uri" '
                    NF == 0 { flush(); print; next }
                    {
                        stanza=stanza $0 "\n"
                        if ($0 ~ /^[[:space:]]*#/) next
                        if ($0 ~ /^[[:space:]]/) {
                            if (field=="uris:") {
                                for (i=1; i<=NF; i++) if ($i==uri || $i==uri "/") docker=1
                                uri_count+=NF
                            }
                            next
                        }
                        field=tolower($1)
                        if (tolower($1)=="signed-by:") signed=1
                        if (tolower($1)=="enabled:" && tolower($2)=="no") disabled=1
                        if (field=="uris:") {
                            for (i=2; i<=NF; i++) if ($i==uri || $i==uri "/") docker=1
                            uri_count+=NF-1
                        }
                    }
                    END { flush(); if (matches != 1) exit 2 }
                    function flush() {
                        printf "%s", stanza
                        if (docker && !disabled) {
                            if (uri_count != 1) exit 2
                            matches++
                            if (!signed) print "Signed-By: " key
                        }
                        stanza=field=""; signed=disabled=docker=uri_count=0
                    }
                ' "$source" > "$staged" || {
                    echo "无法安全识别 Docker 软件源，请核对 $source。" >&2
                    return 1
                }
                ;;
            *) echo "无法自动迁移 Docker 软件源：$source" >&2; return 1 ;;
        esac
        # 现有源已绑定自己的密钥时，继续沿用它。
        if cmp -s "$source" "$staged" && ! grep -Fq -- "$key" "$staged"; then return 0; fi
    else
        source=/etc/apt/sources.list.d/docker.sources
        if [[ -e $source || -L $source ]]; then
            echo "Docker 软件源文件已存在但未启用，请核对 $source。" >&2
            return 1
        fi
        staged=$(mktemp "${source}.sysenv.XXXXXXXX") || return 1
        printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s\n' \
            "$uri" "$suite" "$arch" "$key" > "$staged" || return 1
    fi

    install -m 0755 -d /etc/apt/keyrings || return 1
    key_tmp=$(mktemp "${key}.XXXXXXXX") || return 1
    if ! curl -fsSL --proto '=https' --connect-timeout 15 --max-time 60 "$uri/gpg" -o "$key_tmp" ||
        ! grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "$key_tmp"; then
        echo '下载 Docker 软件源密钥失败。' >&2
        return 1
    fi
    chmod 0644 "$key_tmp" && mv -fT -- "$key_tmp" "$key" || return 1
    key_tmp=''
    if ! cmp -s "$source" "$staged"; then
        if [[ -f $source ]]; then
            backup=$(mktemp "${source}.sysenv.XXXXXXXX.bak") || return 1
            cp -p -- "$source" "$backup" || return 1
        fi
        chmod 0644 "$staged" && mv -fT -- "$staged" "$source" || return 1
        staged=''
    fi
)

install_docker() {
    local arch suite candidate package status yn
    local -a conflicts=()
    if (( EUID != 0 )); then
        echo '请用 sudo 执行 Docker 安装脚本。' >&2
        return 1
    fi
    # shellcheck disable=SC1091
    suite=$(. /etc/os-release; [[ $ID == ubuntu ]] && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}") || {
        echo '此 Docker 安装入口需要 Ubuntu。' >&2
        return 1
    }
    [[ $suite =~ ^[a-z][a-z0-9-]*$ ]] || return 1
    arch=$(dpkg --print-architecture) || return 1
    printf 'Ubuntu %s (%s)\n' "$suite" "$arch"
    if ! apt-get install -y --no-remove ca-certificates curl; then
        echo '依赖安装失败，请执行“系统设置 → 更新系统”后重试。' >&2
        return 1
    fi
    configure_docker_source "$suite" "$arch" || return 1
    candidate=$(LC_ALL=C apt-cache policy docker-ce | awk '$1=="Candidate:" {print $2}')
    if [[ -z $candidate || $candidate == '(none)' ]] ||
        ! apt-cache madison docker-ce | awk -F'|' -v version="$candidate" -v suite="$suite" '
            { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2) }
            $2 == version && $3 ~ ("download\\.docker\\.com/linux/ubuntu/?[[:space:]]+" suite "/stable[[:space:]]") { found=1 }
            END { exit !found }
        '; then
        echo 'Docker 软件源已配置，请先执行“系统设置 → 更新系统”，再选择“安装 Docker”。'
        return 1
    fi
    for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc docker docker-engine; do
        status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null) || status=''
        if [[ $status == installed ]]; then conflicts+=("$package"); fi
    done
    if (( ${#conflicts[@]} )); then apt-get remove "${conflicts[@]}" || return 1; fi
    apt-get install -y docker-ce docker-ce-cli containerd.io || return 1
    systemctl --no-pager status docker
    docker --version

    # 仅在目标空闲时保留旧脚本的可选数据目录迁移。
    if [[ -d /var/lib/docker && ! -L /var/lib/docker && ! -e /opt/docker && ! -L /opt/docker ]]; then
        read -r -p '是否将 Docker 数据目录迁移到 /opt/docker？[y/N]：' yn || return 0
        if [[ $yn == [Yy] ]]; then
            systemctl stop docker.socket docker.service || return 1
            if ! mv -T -- /var/lib/docker /opt/docker; then
                systemctl start docker.service
                return 1
            fi
            if ! ln -sT -- /opt/docker /var/lib/docker; then
                mv -T -- /opt/docker /var/lib/docker && systemctl start docker.service
                return 1
            fi
            systemctl start docker.service || return 1
        fi
    fi
}

install_docker
