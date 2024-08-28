#!/bin/bash

# 首先开启bbr
function openbbr() {
    echo "net.core.default_qdisc=fq" >>/etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >>/etc/sysctl.conf
    sysctl -p
    sysctl net.ipv4.tcp_congestion_control
}

# 关闭、卸载防火墙
function stopufw() {
    read -p "是否关闭并禁用防火墙？(y/n): " isstopufw
    if [[ $isstopufw == "y" || $isstopufw == "Y" ]]; then
        systemctl stop ufw
        systemctl disable ufw

        read -p "是否卸载防火墙？(y/n): " isrmufw
        if [[ $isrmufw == "y" || $isrmufw == "Y" ]]; then
            apt remove ufw -y
        fi
    fi
}

# 设置交换内存
function setswap() {
    local currentswap=$(free -m | grep Swap | awk '{print $2}')
    if [ "$currentswap" -eq 0 ]; then
        read -p "为设置交换内存,是否设置？(y/n): " issetswap
        if [[ $issetswap == "y" || $issetswap == "Y" ]]; then
            while true; do
                read -p "输入设置交换内存大小(单位M): " setswapcount
                if [[ "$setswapcount" =~ ^[0-9]+$ ]]; then
                    sudo fallocate -l "$setswapcount"M /swapfile
                    sudo chmod 600 /swapfile
                    sudo mkswap /swapfile
                    sudo swapon /swapfile
                    sudo swapon --show
                    sudo free -h
                    echo "/swapfile swap swap defaults 0 0" >>/etc/fstab

                    # 检查文件是否存在并可写
                    if [[ ! -f /etc/sysctl.conf ]]; then
                        echo "/etc/sysctl.conf 文件不存在，将尝试创建。"
                        touch /etc/sysctl.conf
                    fi

                    # 删除现有 vm.swappiness 行
                    sed -i '/^vm.swappiness *=.*/d' /etc/sysctl.conf

                    # 在文件末尾添加新行
                    echo "vm.swappiness = $setswapcount" >>/etc/sysctl.conf

                    # 使配置立即生效
                    sysctl -p
                    currentswap=$(free -m | grep Swap | awk '{print $2}')
                    echo "当前交换内存,大小(M):$currentswap"
                    break
                else
                    echo "请输入正整数"
                fi
            done
        fi
    else
        echo "已开启交换内存,大小(M):$currentswap"
    fi
}

# 验证docker是否安装，如果已经安装了，就启动
function checkdocker() {
    if ! command -v docker &>/dev/null; then
        # docker 服务不存在
        return 1
    fi
    # 如果没有启动就启动docker
    if ! systemctl is-active docker; then
        systemctl start docker
        if ! systemctl is-active docker; then
            return 2
        else
            return 0
        fi
    else
        return 0
    fi
}

# 检测mynet网络是否存在
function check_network() {
    local network_exists=$(docker network ls -q --filter name=mynet 2>/dev/null)

    if [[ -z "$network_exists" ]]; then
        echo 1
    else
        echo 0
    fi
}

# 创建docker网络
dockernet = "4"
function createdockernet() {
    # 验证docker
    if ! [ $checkdocker -eq 0 ]; then
        echo "docker未安装或者无法启动"
        return 1
    fi
    # 验证网络是否已经存在
    if [[ $check_network -eq 0 ]]; then
        echo "已存在mynet网络"
        return 1
    fi

    while true; do
        read -p "创建docker网络(ipv4输入4，ipv6输入6): " dockernet
        if [[ $dockernet == "4" ]]; then
            docker network create --driver bridge --subnet 192.168.0.0/24 --gateway 192.168.0.1 mynet
            break
        else
            if [[ $dockernet == "6" ]]; then
                docker network create --driver bridge --ipv6 --subnet f602:fa3f:0:0::/64 --subnet 192.168.0.0/24 --gateway 192.168.0.1 mynet
                break
            fi
        fi
    done
}

# 验证docker状态及网络创建情况，返回 0 可以继续
function checkdockerandnet() {
    # 验证docker
    if ! [ $checkdocker -eq 0 ]; then
        # echo "docker未安装或者无法启动"
        return 1
    fi
    # 验证网络是否已经存在
    if [[ $check_network -eq 1 ]]; then
        #echo "不存在mynet网络"
        return 1
    fi

    return 0
}

# 更新系统
sudo apt update && sudo apt upgrade -y

while true; do
    echo "请选择要执行的操作："
    echo "1. 开启bbr加速"
    echo "2. 关闭、卸载防火墙"
    echo "3. 开启交换内存"
    echo "4. 安装docker"
    echo "5. 创建docker网络"
    echo "6. 创建NPM容器"
    echo "7. 创建Reality容器"
    echo "8. 创建3X-UI容器"
    echo "9. 创建owncloud容器"
    echo "10. 卸载docker及相关容器、镜像、卷"
    echo "11. 清理系统"
    echo "12. 退出"
    read -p "请输入您的选择: " choice
    case $choice in
    1)
        openbbr
        ;;
    2)
        stopufw
        ;;
    3)
        setswap
        ;;
    4)
        curl -L https://raw.githubusercontent.com/JsonPager/docker/main/ubuntu_docker.sh -o ubuntu_docker.sh && chmod +x ubuntu_docker.sh && ./ubuntu_docker.sh
        ;;
    5)
        createdockernet
        ;;
    6)
        if [[ $checkdockerandnet -eq 0 ]]; then
            if [[ $dockernet == "4" ]]; then
                docker run --privileged=true -itd --name=npm -p 80:80 -p 81:81 -p 443:443 --network=mynet --ip 192.168.0.2 -v /opt/dockerservice/npm/data:/data -v /opt/dockerservice/npm/letsencrypt:/etc/letsencrypt --restart=always jc21/nginx-proxy-manager:latest
            else
                if [[ $dockernet == "6" ]]; then
                    docker run --privileged=true -itd --name=npm -p 80:80 -p 81:81 -p 443:443 --network=mynet --ip 192.168.0.2 --ip6 f602:fa3f:0:0::2 -v /opt/dockerservice/npm/data:/data -v /opt/dockerservice/npm/letsencrypt:/etc/letsencrypt --restart=always jc21/nginx-proxy-manager:latest
                fi
            fi
        else
            echo "请检查docker服务和docker网络"
        fi
        ;;   
    7)
        echo "创建Reality容器"
        ;;
    8)
        echo "创建3X-UI容器"
        ;;
    9)
        echo "创建owncloud容器"
        ;;
    10)
        curl -L https://raw.githubusercontent.com/JsonPager/docker/main/undocker.sh -o undocker.sh && chmod +x undocker.sh && ./undocker.sh
        ;;
    11)
        echo "清理系统"
        ;;
    12)
        echo "退出"
        exit 1
        ;;
    *)
        echo "无效输入"
        ;;
    esac
done
