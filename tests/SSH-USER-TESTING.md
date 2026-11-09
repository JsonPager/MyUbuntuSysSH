# AWS SSH 用户创建兼容验证

2026-11-09 修复：

- 检查配置前补建缺失的 `/run/sshd`，使用 root:root、0755；拒绝该路径为符号链接。
- 当 SSH 服务未运行但标准 `ssh.socket` / `sshd.socket` 正在监听时，先校验启动参数和配置，再启动对应服务。保留 socket，不执行 stop、restart、disable 或 enable。
- 接受已核对的 EC2 Instance Connect 标准启动参数组合。所有语法检查、生效配置比对和回滚检查都传入相同的 AuthorizedKeysCommand / AuthorizedKeysCommandUser，保留 AWS 密钥获取方式。
- 其他自定义启动参数、非空 SSHD_OPTS、已有访问限制仍按原策略拒绝，不改写 AWS systemd drop-in。

在 Ubuntu / Debian 的独立测试环境执行：

```bash
bash -n setup-ssh-user.sh
python3 tests/check-start-args.py
sudo python3 tests/test_ssh_preflight.py
sudo bash tests/run-isolated.sh
```

集成测试需要 OpenSSH Server、OpenSSH Client、sudo、Python 3、util-linux、iproute2；需要 root 能创建 mount / PID / network namespaces。不要直接运行 `tests/integration.py`。源码和 sshd 二进制须位于 `/etc`、`/home`、`/run`、`/var` 以外。

本次实际结果：WSL Ubuntu 24.04，OpenSSH 9.6p1-3ubuntu13.20，Bash 语法、9 项启动参数用例、11 项服务预检用例及全部 16 组隔离集成场景通过。OpenSSH 与 libwrap 从 Ubuntu 官方软件包下载解包，未安装或更改宿主 SSH。

隔离测试覆盖真实新用户密码登录、原用户通过 AuthorizedKeysCommand 获取密钥的公钥登录、免密码 sudo、原有用户密码和 authorized_keys 保持不变、重复执行、访问名单、多因素限制、Match 冲突、密码设置失败、信号中断及 reload 失败回滚。测试使用复制的 `/etc`、独立网络、tmpfs `/home` / `/run` / `/var`，不修改宿主账户。

边界：systemd 使用测试适配器，AWS 密钥获取程序使用测试 helper，PAM 设置为 UsePAM no。这不等于 AWS 实机或真实 EC2 Instance Connect 后端验收。实际服务器执行后，应保持原连接，另开终端分别验证原有密钥登录和新用户密码登录；安全组、PAM 和其他既有访问策略仍可能阻止登录。
