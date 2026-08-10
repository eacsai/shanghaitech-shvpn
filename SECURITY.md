# 安全说明

## 信任边界

本项目是非官方客户端封装。它连接 `vpn.shanghaitech.edu.cn`，使用上科大 CAS/aTrust 流程，并在本机回环地址 `127.0.0.1:11080` 提供 SOCKS 服务。它不保证学校未来的网关、认证策略或协议变化仍然兼容。

安装器从 `Mythologyli/zju-connect` 的固定 tag `v1.2.2` 获取源码，要求 commit 为 `a759261b76ed653900911559400005b40a31392a`，并验证：

- `go.mod`: `d06b5a0423a5ce23887222d1e3f2b06b0f1c63f16873d87887c0c1147a5f7204`
- `go.sum`: `8af52b375ebe736a54883a39bdffff6cdfb8f55face981cbbd13e3362e2e0572`

随后才应用仓库内补丁、运行 aTrust 测试并构建。安装器不会下载预编译 VPN 二进制，也不会请求 `sudo`。

## 不要分享的内容

提交 issue 或寻求帮助时，请勿上传：

- `~/Library/Application Support/ShanghaitechVPN/client-data.json`
- `shvpn.log` 或未经删减的 VPN 输出
- CAS callback URL、cookie、ticket、短信验证码或密码
- `~/.ssh`、私钥、完整 SSH 配置
- 真实用户名、校内服务器地址或能识别个人身份的路径

请只提供经过删减的错误类型、命令退出码、macOS/架构和 `go version`。

## 本地进程安全

`shvpn` 只信任同时满足以下条件的 SOCKS 监听进程：当前 UID、固定绝对可执行文件、固定完整 argv，以及唯一的 `127.0.0.1:11080` 监听者。停止时只对已验证进程发送 `SIGINT`；不会升级为 `SIGKILL`。

`shvpn start`、`shvpn stop` 和 `shvpn login` 使用 zsh `zsystem flock` 对当前用户拥有的 0600 锁文件做非阻塞 advisory locking；冲突时退出码为 `75`。锁描述符由调用中的 `shvpn` 进程持续持有，并设置 close-on-exec，因此后台 VPN 客户端不会继承或长期占用操作锁。

SSH 路由助手只接受安装时写入 0600 allowlist 的服务器地址。已配置地址可使用 OpenSSH 在运行时传入的任意有效端口（`1`–`65535`）；未配置地址以及无效端口都会被拒绝。VPN 安全停止时走直连；VPN 可信运行时走 SOCKS；监听者、文件权限或进程身份含糊时拒绝连接。

安装器使用 `Match final host ...`，让 OpenSSH 在 alias 应用 `HostName` 后按最终主机名匹配。它不会给 `Host *` 安装全局代理，也不会复制或改写用户 alias。最终 `HostName` 必须与 allowlist 中某一行完全一致；项目不会通过 DNS 把域名和 IP 扩展成等价信任目标。

OpenSSH 对多数配置项采用“先取得的值生效”。因此，alias 较早设置的 `ProxyCommand` 或 `ProxyJump` 可能阻止本项目的后置规则。安装器和 `shvpn doctor` 会检查主配置以及 `~/.ssh` 内常见的安全 Include：仅遍历当前用户拥有、非符号链接、物理路径仍在 `~/.ssh` 内的普通文件，并限制深度、文件数和 alias 数；不会 source SSH 配置。复杂、目录外、不安全或无法完整枚举的 Include 会产生明确警告，不会伪称已检查全部 alias。用户可用 `shvpn doctor ALIAS` 对指定名字执行最终 `ssh -G` 验证。

自动枚举只收集字面量 Host 名称，不展开 `Host gpu-*` 一类模式；具体名字必须显式传给 `shvpn doctor`。安装器、`doctor` 和 `reconnect` 使用 `-F ~/.ssh/config` 绑定用户配置，因此按 OpenSSH 规则忽略 `/etc/ssh/ssh_config`。普通 `ssh` 默认仍读取系统配置；如果系统级 `ProxyCommand`/`ProxyJump` 先取得值，可能阻止后置的托管路由。在受 MDM 或集中 SSH 配置管理的 Mac 上，应额外用不带 `-F` 的 `/usr/bin/ssh -G ALIAS` 核对最终 `proxycommand`。这是系统配置边界，不应把仅有 `doctor` 的通过解释为已审计系统级规则。

`shvpn doctor` 不建立远程 SSH 连接，也不启动或停止 VPN。它读取托管文件、受限 SSH 配置和已知 VS Code settings 文件，并只判断 `remote.SSH.configFile`、`remote.SSH.path` 两个键是否存在；不会输出完整 settings。诊断会显示本地目标和 alias，公开分享前仍需删减。

`shvpn reconnect` 是用户显式调用的中断性操作。它只处理 `ssh -G` 最终主机在 allowlist 中、且有效 `ProxyCommand` 精确等于本项目助手的名字；对每个名字先执行 `ssh -O check`，成功后才执行 `ssh -O exit`。它不删除 ControlPath、不扫描或发送信号给 SSH 进程、不尝试远程 shell，也不会从 `start`、`stop` 或网络变化中自动触发。命令行覆盖的工具自有 ControlPath 不会被推断或处理。

路由助手先验证监听进程，再调用系统 `nc` 连接回环 SOCKS 端口；这两个动作无法成为同一个原子操作。因此，拥有同一 macOS 用户权限的恶意本地进程理论上可能在检查后抢占端口。该限制不扩大到局域网，因为 SOCKS 只绑定回环地址，但本项目不把“同一用户下的恶意进程”视为可完全隔离的威胁边界。

## 文件覆盖与恢复

安装器拒绝符号链接、非当前用户所有的文件、重复/损坏的托管标记和已修改的托管文件。首次安装会保存完整基线，之后每次写入前再创建带时间戳的哈希备份。

地址模式升级会把哈希一致、受信任的旧版 alias/host/port/user 目标文件和 SSH 托管块整体替换。旧安装器托管块内的 alias 及其生成的 `Port`、`User` 不会保留；用户在托管块外的 alias 不会被改写，并会按最终 `HostName` 自动接入。原始安装前基线仍由卸载器恢复。

`~/.local/bin/zju-connect` 可能与其他学校或其他用途的现有安装重名。如果它是安全的普通文件，本项目会备份后替换，并在卸载时恢复；如果是符号链接或状态不明确，则拒绝安装。依赖同一路径运行其他网关的用户应先确认这一影响。

卸载器会在任何用户修改或标记歧义存在时，在修改文件之前停止。它不会删除 VPN 登录状态和日志，也不会递归清理用户目录。

如果 `127.0.0.1:11080` 被不属于本项目的进程占用，卸载器会明确警告、绝不停止该进程，并继续恢复本项目文件。只有已经确认属于本项目的 VPN 进程无法在 `SIGINT` 后退出时，卸载才会中止。

## 报告安全问题

请通过 GitHub 仓库的 Security 页面私下报告可复现的安全问题，不要在公开 issue 中附带上述敏感材料。此项目没有上海科技大学官方支持承诺；账号或校园基础设施问题应走学校官方支持渠道。
