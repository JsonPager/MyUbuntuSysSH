# 从 Git 部署 Portainer Stack

运行最新版 `sysenv.sh`，选择 **2. Docker 管理 → 6. 从 Git 部署 Portainer Stack**。

1. 从 `MyUbuntuSysSH/stacks/` 的 `.yml` / `.yaml` 文件中选择模板。
2. 查看模板并填写 Stack 名称，默认使用文件名，例如 `bark`。
3. 填写 Portainer 地址，默认 `http://127.0.0.1:9000`。HTTPS 自签名服务可填写可信 CA 文件路径，不会跳过证书校验。
4. 使用 Portainer 的登录用户名和密码（用户名默认 `admin`，密码隐藏输入）。脚本自动登录换取临时 JWT，无需手动创建 Access token。首次安装仍需在页面创建管理员；仅使用单点登录的账号不适用这个密码登录入口。
5. 选择目标 Docker 环境，确认后部署。只有一个环境时自动选择，环境 ID 从 API 获取。

同一次 `sysenv.sh` 会话内，第一次登录后会复用 Portainer 地址、证书设置、用户名和临时 JWT；安装第二个、第三个 Stack 不用再次输入用户名和密码。每次部署前会用只读请求检查登录是否有效，失效时重新输入用户名和密码，不会自动重试部署请求。退出主菜单、输入结束或常规中断会清除会话缓存；重新运行脚本需重新登录。若需切换 Portainer 服务或账号，退出后重新运行即可。旧版正在运行的 `sysenv.sh` 需要先退出，再启动最新版才能获得此功能。

脚本通过 `POST /api/stacks/create/standalone/string?endpointId=实际环境ID` 创建 Stack，YAML 内容存入 Portainer。之后打开 **Stacks → 对应 Stack → Editor**，可直接编辑和重新部署；它不会持续同步 Git，也不会把页面修改写回 Git。

模板列表来自公共仓库 `stacks/` 的直接子文件，下载使用所选文件的不可变 blob SHA。模板中的变量、外部网络、目标服务器路径及其他文件须先准备。当前仅支持单文件 Compose 和 Docker Standalone（本地 Docker 或普通 Docker Agent），不支持 Swarm、Kubernetes 或 Edge。

`bark.yml` 依赖外部 `mynet` 网络及其中的静态 IPv4/IPv6 地址；宿主端口绑定 `127.0.0.1:38080`，沿用模板本身的访问范围。

已有同名 Stack 时停止，不覆盖、不重建、不删除已有资源；在 Portainer 页面管理已有 Stack。如果接口超时或等待超过 10 分钟，后台部署可能仍在进行，应先查看页面再决定下一步。Portainer 2.41 起创建可能异步执行，因此脚本轮询 Stack 状态：Active 才报告完成，Error / Inactive / 未知状态会明确报错，并核对 Portainer 保存的 YAML。Active 不代表所有容器健康检查已通过。

登录密码仅在本次认证期间写入 root 专属临时目录的 0600 文件，生成 JSON 请求后清理；登录完成立即删除密码请求和登录响应。JWT 通过认证头文件交给 curl，不把密码或 JWT 放在进程参数、环境变量或日志中。同次 sysenv 会话的 JWT 放在 `/run` 下独立的 root 专属临时目录（0700，文件 0600），会话结束删除；不缓存密码。直接单独运行部署脚本时仍在该次调用结束后清除凭据。SIGKILL 无法执行清理，异常残留仅 root 可读，系统重启后 `/run` 中的临时缓存也会消失。不要把凭据发到聊天或写入 Git。不跟随 Portainer API 重定向。明文 HTTP 仅允许回环地址；远程服务使用 HTTPS。curl / jq 是依赖；缺少 jq 时可选择仅安装 jq，不自动执行系统更新。

参考：[Portainer 官方 Stack API](https://github.com/portainer/portainer-skills/blob/main/portainer-api/references/stacks.md)、[页面编辑 Stack](https://docs.portainer.io/user/docker/stacks/edit)、[异步部署状态](https://docs.portainer.io/faqs/troubleshooting/stacks-deployments-and-updates/why-did-my-api-client-start-getting-409-errors-after-upgrading)。

开发验证覆盖 Bash 语法、ShellCheck 和本地模拟 HTTP API，验证请求内容、凭据保护、环境选择、同名拒绝、异步完成/失败及保存内容比对。尚未在用户服务器的真实 Portainer 上部署。

安装好 curl、jq、Python 3 后，可执行 `sudo python3 tests/test_portainer_stack.py` 重跑本地模拟测试；测试使用临时 HTTP 服务，不会创建真实 Docker 容器。
