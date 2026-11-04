#!/usr/bin/env bash
# 安装 Docker；不自动刷新软件索引或升级系统。
install_docker() {
   local arch candidate
   arch=$(dpkg --print-architecture) || return 1
   echo "$arch"
   # 仅安装本功能依赖；失败时由用户从系统设置中手动更新索引。
   if ! apt install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common; then
       echo '依赖安装失败，请执行“系统设置 → 更新系统”后重试。' >&2
       return 1
   fi
   if ! (set -o pipefail; curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -); then
       echo '导入 Docker 软件源密钥失败。' >&2
       return 1
   fi
   # --no-update 禁止 add-apt-repository 隐式刷新软件包索引。
   sudo add-apt-repository --no-update -y "deb [arch=$arch] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" || return 1
   candidate=$(apt-cache policy docker-ce | awk '/Candidate:/ {print $2; exit}')
   if [[ -z $candidate || $candidate == '(none)' ]]; then
       echo 'Docker 软件源已配置，但尚无可安装索引。'
       echo '请执行“系统设置 → 更新系统”，然后重新选择“Docker 管理 → 安装 Docker”。'
       return 1
   fi
   # 确认可安装后才继续原有安装步骤；不执行系统更新。
   apt-get remove docker-ce docker-ce-cli containerd.io docker docker-engine docker.io containerd runc || return 1
   rm -rf /opt/docker
   apt install -y docker-ce docker-ce-cli containerd.io || return 1
   echo "安装完成，查看服务状态"
   systemctl --no-pager status docker
   echo "查看版本号"
   docker -v
   read -p "检查服务及版本状态，确认是否继续安装 ? [Y/n] :" yn
	[ -z "${yn}" ] && yn="y"
	if [[ $yn == [Yy] ]]; then
	        echo "停止服务"
	        systemctl stop docker
                        echo "创建新的docker路径"
                        mkdir -p /opt/docker
                        echo "将原docker的文件移动到新的位置"
                        mv /var/lib/docker/* /opt/docker
                        echo "进入原docker路径下"
                        cd /var/lib
                        echo "删除docker文件夹"
                        rm -rf docker
                        echo "添加原docker路径的link到新的位置"
                        ln -s /opt/docker/ /var/lib/docker
                        echo "查看link文件夹的内容，确定link起效"
                        ls -la docker
                        echo "回到root"
                        cd
                        echo "启动docker"
                        systemctl restart docker
                        echo "查看docker状态"
                        systemctl --no-pager status docker
	fi
}

install_docker
