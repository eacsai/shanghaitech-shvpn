# ShanghaiTech shvpn

在 Apple Silicon Mac 上用 `shvpn` 连接上海科技大学 VPN，并且只让指定的 SSH 服务器经过 VPN。Clash Verge、浏览器、系统代理和其他网络流量不受影响。

> 非官方社区项目，与上海科技大学、深信服或 zju-connect 上游无隶属或背书关系。官方支持方式见[上科大信息化办公室 VPN 说明](https://it.shanghaitech.edu.cn/2021/0424/c8423a63191/page.htm)。

## 能做什么

- 从固定版本的开源 [zju-connect](https://github.com/Mythologyli/zju-connect) 源码构建，不安装 aTrust 图形客户端。
- VPN 开启时，只有 allowlist 中 SSH 目标经 `127.0.0.1:11080`；VPN 停止时同一命令直接连接，适合校内网。
- 终端、VS Code Remote-SSH 和调用系统 OpenSSH 的 Codex 共用 `~/.ssh/config`，无需切换配置。
- 已有 SSH alias、`User`、`Port`、`IdentityFile` 和 ControlMaster 设置继续生效。
- 不退出或修改 Clash Verge，不启用 TUN，不修改 macOS 系统代理。

## 要求与安装

目前支持 macOS 12+、Apple Silicon（`Darwin/arm64`），需要 Git、zsh、OpenSSH、`codesign`、`nc`、**Go 1.25.6 darwin/arm64**、**Python 3.10–3.14（含 pip）**和 **Google Chrome**。安装不使用 `sudo`，也不代装这些依赖。

```zsh
uname -m
go version
git clone https://github.com/eacsai/shanghaitech-shvpn.git
cd shanghaitech-shvpn
./install.zsh
```

安装器只询问至少一个需要代理的服务器地址，不询问 alias、用户名、端口、密码、验证码、私钥或 callback URL。安装后新开终端，首次或登录过期时运行 `shvpn login`：它会打开独立的 Chrome 登录窗口，自动捕获并安全提交 CAS callback，成功后自动切换到后台 VPN。以后运行 `shvpn` 即可复用登录状态。

非交互安装：

```zsh
./install.zsh --non-interactive \
  --target gpu1.example.edu \
  --target gpu2.example.edu \
  --add-path
```

不想修改 `~/.zshrc` 时把 `--add-path` 换成 `--no-path`，并使用安装器输出的完整命令路径。

## 命令

| 命令 | 用法 |
|---|---|
| `shvpn` | 后台启动 VPN，等同于 `shvpn start` |
| `shvpn start` | 后台启动；已有可信实例时安全地保持不变 |
| `shvpn login` | 打开专用 Chrome 窗口完成 CAS，自动处理 callback 并后台启动 VPN |
| `shvpn status` | 检查 VPN 是否可信运行、停止或处于不可信状态 |
| `shvpn stop` | 只向已验证属于本项目的 VPN 进程发送 `SIGINT` |
| `shvpn add HOST_OR_ALIAS` | 添加一个服务器地址，或解析一个现有 SSH alias 后添加其最终 `HostName` |
| `shvpn remove HOST_OR_ALIAS` | 删除地址或 alias 对应的最终目标；不允许删除最后一个目标 |
| `shvpn doctor [ALIAS ...]` | 本地检查 VPN、SOCKS、SSH 路由、VS Code 和 Codex；不登录服务器 |
| `shvpn reconnect [ALIAS ...]` | 显式关闭匹配目标的配置型 SSH 复用主连接，让下次连接重新选路 |
| `shvpn uninstall` | 恢复安装前文件并卸载；保留 VPN 登录状态、日志和恢复归档 |

例子：

```zsh
shvpn login
shvpn
shvpn add gpu3.example.edu
shvpn add gpu-alias
ssh gpu-alias
shvpn doctor gpu-alias
shvpn remove gpu3.example.edu
shvpn stop
```

`add/remove` 不关闭已有 SSH、VS Code 或 Codex 会话。删除 alias 会删除它最终指向的 allowlist 目标，因此所有共享该 `HostName` 的 alias 都不再走 VPN。若只剩一个目标，请直接使用 `shvpn uninstall`，或者先添加新目标再删除旧目标。

## SSH alias 与精确匹配

假设安装或添加的是 `gpu1.example.edu`：

```sshconfig
Host gpu
    HostName gpu1.example.edu
    User alice
    Port 2222
```

此时 `ssh gpu`、VS Code 的 `gpu` 和 Codex 的 `gpu` 都会自动接入。关键规则是：最终 `HostName` 字符串必须与 allowlist 中一行**完全一致**。项目不会通过 DNS 推断域名与 IP 等价；安装 `192.0.2.10` 不会自动信任 `gpu1.example.edu`。

常见的安全 `Include ~/.ssh/conf.d/*` 会被检查。复杂、目录外、通配 Host 或无法安全枚举的 Include 会给出警告；可显式运行：

```zsh
shvpn doctor gpu-01
```

安装器、动态配置 helper、`doctor` 和 `reconnect` 用 `-F ~/.ssh/config` 验证用户配置，因此不会审计 `/etc/ssh/ssh_config`。普通 `ssh` 仍会读取系统配置；若 MDM 或系统级配置更早设置了 `ProxyCommand`/`ProxyJump`，请额外运行不带 `-F` 的 `/usr/bin/ssh -G ALIAS`，确认最终 `proxycommand` 指向 `shanghaitech-ssh-route`。

## 路径选择与重连

```text
ssh gpu
  └─ 仅最终 HostName 命中 allowlist
       ├─ shvpn 可信运行 → 本地 SOCKS → 上科大 VPN → 服务器
       ├─ shvpn 已停止   → 直连（校内网）
       └─ 状态不可信     → 拒绝连接
```

已有 ControlMaster 会继续使用创建时的路径。只有新连接会自动选择当前路径；网络切换后可选择 `shvpn reconnect`。它只对已验证目标先运行 `ssh -O check` 再运行 `ssh -O exit`，不会扫描或 kill SSH 进程，但可能中断对应的终端、VS Code 或 Codex 会话，所以永远不会由 `start/stop` 自动触发。

`doctor` 退出码：`0` 全部通过，`1` 核心正常但有警告，`2` 托管文件、路由或监听状态不可信，`64` 参数错误。输出可能包含本地服务器地址或 alias，公开求助前请删减。

## 登录、安全与恢复

`shvpn` 会复用已保存的登录状态。首次使用、状态过期或学校要求重新验证时，运行 `shvpn login`，亲自在专用 Chrome 窗口完成 CAS；无需复制、查看或粘贴 callback URL。若学校要求短信验证，终端会关闭回显后读取验证码，本项目不会保存或自动填写验证码。

自动登录使用锁定哈希的 Playwright 1.62.0 Python 包，但不会下载 Playwright 自带浏览器；只调用本机 Google Chrome。CAS 登录复用状态保存在 `~/Library/Application Support/ShanghaitechVPN/cas-chrome-profile/`，与日常 Chrome 配置隔离，且卸载时默认保留，避免每次重新登录。该目录可能含有效 SSO 状态，不要复制、同步或公开。

安装、`add/remove`、VPN 生命周期和卸载使用同一非阻塞配置锁；并发操作返回 `75`。托管文件按哈希校验，所有配置写入前保存时间戳备份到 `~/.local/lib/shanghaitech-shvpn/backups/`。发现符号链接、所有者异常、哈希变化、SSH 冲突或标记歧义时会在写入前失败关闭（fail closed）。

普通错误会自动回滚。极端的断电或 `SIGKILL` 可能留下已备份但未完成的多文件更新；此时不要手工猜测清单，使用仓库中的 `./uninstall.zsh` 恢复/退役受信安装，再重新安装。旧格式迁移中出现未被清单记录的 helper 或登录运行时也采用同一恢复方式。

`shvpn uninstall` 不删除 `client-data.json`、日志或卸载恢复归档，也绝不会停止占用 SOCKS 端口的无关进程。若命令内卸载不可用，可在仓库目录运行 `./uninstall.zsh`。

请勿公开密码、验证码、CAS callback、cookie/ticket、私钥、`client-data.json`、完整日志、完整 SSH 配置或真实校内地址。详细边界见 [SECURITY.md](SECURITY.md)。让 Codex 代为配置时可复制 [CODEX_SETUP.md](CODEX_SETUP.md)。

## 补丁与许可证

仓库固定 zju-connect `v1.2.2` / `a759261b76ed653900911559400005b40a31392a`，并修复跳过不可探测 IPv6 节点时的节点/探测结果对齐及全部失败时的回退逻辑。回归测试只用 RFC 文档示例地址。

项目按 [GNU AGPL v3](LICENSE) 发布，上游归属见 [NOTICE.md](NOTICE.md)。

---

**English summary:** An unofficial, source-built Apple-Silicon macOS helper for ShanghaiTech aTrust/CAS. It routes only explicitly managed SSH `HostName` values through the local VPN SOCKS listener and leaves Clash and other traffic unchanged.
