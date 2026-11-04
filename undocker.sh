#!/bin/bash

# 检查docker服务是否存在
if ! command -v docker &>/dev/null; then
    echo "Docker服务不存在"
    exit 1
fi

# 检查 Docker 服务是否正在运行
if ! systemctl is-active docker; then
    echo "Docker服务未运行，正在启动..."
    systemctl start docker
    if ! systemctl is-active docker; then
        echo "启动 Docker 服务失败，正在卸载 Docker..."
        # 删除旧包
        apt-get remove docker-ce docker-ce-cli containerd.io docker docker-engine docker.io containerd runc        
        # 删除link的文件夹
        rm -rf /opt/docker
        rm -rf /var/lib/docker
        exit 1
    else
        echo "Docker 服务启动成功！"
    fi
else
    echo "Docker 运行中"
fi

for container_id in $(docker ps -a -q); do
    # 获取容器名称
    container_name=$(docker inspect --format='{{.Name}}' "$container_id")
    container_name=${container_name#"/"} # 去除名称前面的 /
    echo "正在删除容器$container_name"
    # 检查容器是否存在挂载卷
    # volumes=$(docker inspect --format='{{.Mounts}}' "$container_id")
    volumes=$(docker inspect --format='{{json .Mounts}}' "$container_id")

    # 停止容器
    docker stop "$container_id"
    # 删除容器
    docker rm "$container_id"

    # 如果有挂载卷，则提示用户是否删除
    if [[ -n "$volumes" ]]; then
        read -p "容器 $container_name ($container_id) 存在挂载卷，是否删除？(y/n): " delete_volume
        if [[ $delete_volume == "y" || $delete_volume == "Y" ]]; then
            # 获取卷名并删除
            for volume in $(echo "$volumes" | jq -r '.[].Source'); do
                echo "需要删除的卷$volume"
                rm -rf "$volume"
            done
        fi
    fi
done

docker rmi $(docker images -q)

systemctl stop docker
systemctl disable docker

# 删除旧包
apt-get remove docker-ce docker-ce-cli containerd.io docker docker-engine docker.io containerd runc
# 删除link的文件夹
rm -rf /opt/docker
rm -rf /var/lib/docker
