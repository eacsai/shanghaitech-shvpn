# ShanghaiTech shvpn

在 Apple Silicon Mac 上，以一个简单的 `shvpn` 命令连接上海科技大学 VPN，并且只让你指定的 SSH 服务器经过 VPN。Clash Verge、浏览器和其他网络流量不会被接管。

> 这是社区维护的非官方实验项目，与上海科技大学、深信服或 zju-connect 上游均无隶属或背书关系。学校支持的方式仍以[上科大信息化办公室的 VPN 说明](https://it.shanghaitech.edu.cn/2021/0424/c8423a63191/page.htm)为准。

## 它解决什么问题

- 不安装 aTrust 图形客户端；从固定版本的开源 [zju-connect](https://github.com/Mythologyli/zju-connect) 源码构建。
- `shvpn login` 负责首次登录或登录过期后的浏览器 CAS 流程。
- `shvpn` 后台启动，`shvpn stop` 安全关闭。
- 只有安装时列出的 SSH 目标使用本地 SOCKS 端口 `127.0.0.1:11080`。
- 在校内、VPN 未启动时，同一个服务器地址或现有 SSH alias 自动走直连。
- 终端、VS Code Remote-SSH 以及调用系统 OpenSSH 的 Codex 使用同一份配置。
- `shvpn doctor` 在本地检查 VPN、SSH alias、VS Code 和 Codex/OpenSSH 兼容性。
- `shvpn reconnect` 可选地关闭这些服务器的配置型 SSH 复用连接，让下一次连接重新选路。
- 不退出、不修改 Clash Verge，也不启用 TUN 或 macOS 系统代理。

## 支持范围

- Apple Silicon Mac：`Darwin/arm64`
- macOS 12 或更高版本
- Go **1.25.6**、Git、zsh、OpenSSH、`codesign`、`nc`

版本 1 暂不支持 Intel Mac、Linux 或 Windows。安装器不会使用 `sudo`，也不会替你安装 Homebrew 或 Go。开始前请确认：

```zsh
uname -m      # 应输出 arm64
go version    # 应包含 go1.25.6 darwin/arm64
```

## 最简单的安装方式

```zsh
git clone https://github.com/eacsai/shanghaitech-shvpn.git
cd shanghaitech-shvpn
./install.zsh
```

安装器只会反复询问需要通过 VPN 访问的服务器地址，至少需要一个。它不会询问 SSH alias、端口、用户名、密码、短信验证码、SSH 私钥或 VPN 回调地址。

安装结束后新开一个终端：

```zsh
shvpn login    # 第一次使用；登录过期时也运行它
shvpn          # 以后后台启动
shvpn status
shvpn doctor   # 纯本地检查，不登录服务器
ssh gpu1.example.edu   # 换成你配置的服务器地址
shvpn stop
```

`shvpn` 会优先复用已经保存的登录状态。只有状态过期、学校要求重新验证或首次设备认证时，才需要再次完成 CAS/手机验证。项目不会尝试保存或自动填写短信验证码。

## 让 Codex 帮你配置

打开 [CODEX_SETUP.md](CODEX_SETUP.md)，复制其中的提示词给 Codex。Codex 只需要向你确认一个或多个服务器地址。

Codex 不需要、也不应该读取你的密码、私钥、`client-data.json` 或完整 VPN 日志。

非交互安装的固定格式是：

```zsh
./install.zsh --non-interactive \
  --target gpu1.example.edu \
  --target gpu2.example.edu \
  --add-path
```

每个 `--target` 后只写一个服务器地址。如果不希望修改 `~/.zshrc`，使用 `--no-path`；此时安装器会输出 `$HOME/.local/bin/shvpn` 的完整命令。

安装器不会询问或复制 alias。它使用 OpenSSH 的最终主机匹配：如果你已有如下配置，`ssh gpu`、VS Code 中的 `gpu` 和 Codex 使用的 `gpu` 都会自动接入同一条路由，同时保留原有 `User`、`Port`、`IdentityFile` 和 ControlMaster 设置：

```sshconfig
Host gpu
    HostName gpu1.example.edu
    User alice
```

这里的 `HostName` 必须与安装时提供的某一个服务器地址**完全一致**。项目不会把域名和 IP 通过 DNS 推断为同一个信任目标。例如安装的是 `192.0.2.10` 时，`HostName gpu1.example.edu` 不会自动视作这个地址。

常见的 `Include ~/.ssh/conf.d/*` 也会工作。安装器和 `doctor` 会在严格的所有者、非符号链接、`~/.ssh` 范围和数量限制内检查这些文件。如果某个复杂或目录外的 Include 无法安全枚举，安装器会警告；连接仍按 OpenSSH 的最终 `HostName` 匹配，建议另外运行：

```zsh
shvpn doctor gpu
```

`Host gpu-*` 这类通配 Host 组不能被自动枚举；请用具体名字运行 `shvpn doctor gpu-01`。另外，安装器、`doctor` 和 `reconnect` 会用 `-F ~/.ssh/config` 绑定本项目管理的用户配置，因此不会读取 `/etc/ssh/ssh_config`。普通 `ssh` 仍会读取系统配置；如果学校、公司 MDM 或其他系统级配置提前设置了 `ProxyCommand`/`ProxyJump`，它可能按 OpenSSH 的“先取得的值生效”规则覆盖本项目。此类 Mac 请再运行不带 `-F` 的 `/usr/bin/ssh -G 具体名字`，确认最终 `proxycommand` 仍指向 `shanghaitech-ssh-route`。

用户名和非默认端口在连接时照常交给 OpenSSH，例如：

```zsh
ssh alice@gpu1.example.edu
ssh -p 2222 alice@gpu1.example.edu
```

从最早的 alias/host/port/user 版本重装时，旧安装器自己生成的 alias 定义仍会随旧托管块移除；用户在托管块外已有的 alias 不会被改写，并会自动按最终 `HostName` 接入。请把需要长期保留的 alias 放在你自己的非托管 SSH 配置中。

## 网络路径

```text
ssh gpu                       # 或 ssh gpu1.example.edu
  └─ ProxyCommand（仅这个服务器地址）
       ├─ shvpn 正在可信运行 → 127.0.0.1:11080 → 上科大 VPN → GPU
       ├─ shvpn 已停止       → 直接连接 GPU（适合校内）
       └─ 状态不可信         → 拒绝连接
```

SSH 已存在的 ControlMaster 连接会继续使用建立时的路径；新终端、VS Code 或 Codex 新建的 SSH 连接才会自动选择当前路径。

## 检查与重新选路

```zsh
shvpn doctor                 # 自动检查目标和常见配置中的 alias
shvpn doctor gpu gpu2        # 额外检查复杂 Include 中的指定 alias
```

`doctor` 只读取本地受限配置并对绑定的用户配置运行 `ssh -F ~/.ssh/config -G`，不会登录服务器；它不检查上文所述的系统级 SSH 配置：

- 退出码 `0`：核心路由和已检测集成正常；
- 退出码 `1`：核心路由正常，但 Include、VS Code 自定义 SSH 路径等存在需要说明的警告；
- 退出码 `2`：托管文件、目标路由或 VPN 监听状态不可信；
- 退出码 `64`：参数无效。

诊断输出会显示本地服务器地址和 alias，公开求助前请自行删减。

切换网络后，如果旧 ControlMaster 没有及时失效，可以显式运行：

```zsh
shvpn reconnect              # 检查并关闭已配置目标/alias 的复用主连接
shvpn reconnect gpu          # 额外指定未被自动枚举的 alias
```

它只会对最终 `HostName` 在 allowlist 中、且有效 `ProxyCommand` 正是本项目助手的名字先执行 `ssh -O check`，成功后才执行 `ssh -O exit`。它不删除 socket、不扫描或 kill SSH 进程，也绝不会由 `start`/`stop` 自动触发。该命令可能中断匹配主连接上的 VS Code、Codex 或终端会话；命令行单独覆盖 `ControlPath` 的工具自有连接无法被安全推断，需要由该工具自行关闭。

## 安全与可撤销性

- 上游固定为 `v1.2.2` / `a759261b76ed653900911559400005b40a31392a`，并验证 `go.mod`、`go.sum` 后才应用补丁。
- VPN 进程按当前用户、可执行文件、完整命令参数和 SOCKS 监听者共同校验；不可信状态不会被停止或代理。
- `start`、`stop`、`login` 通过 zsh 原生的非阻塞 advisory lock 串行执行；锁冲突返回 `75`，后台 VPN 不会继承锁描述符。
- SSH 与 PATH 配置使用明确的托管标记；重复安装不会重复追加。
- 安装前的文件会按哈希备份在 `~/.local/lib/shanghaitech-shvpn/backups/`。
- 如果已经存在 `~/.local/bin/zju-connect`，安装器只会在它是当前用户拥有的普通文件时备份并替换；符号链接或不明确状态会被拒绝。卸载时会恢复原文件。
- 详细边界见 [SECURITY.md](SECURITY.md)。

卸载：

```zsh
./uninstall.zsh
```

卸载器先通过可信的 `shvpn` 停止 VPN，然后恢复安装前文件。任何被用户修改或含糊的托管内容都会让卸载在修改前停止。VPN 登录状态和日志不会被删除。

## 常见问题

### `shvpn` 提示登录过期

```zsh
shvpn login
```

按照终端提示在浏览器完成 CAS；浏览器跳转后，把完整 callback URL 粘贴回终端。随后再运行 `shvpn`。

### 为什么没有代理所有校园地址？

这是刻意的安全边界。本项目只为安装时列出的 SSH 服务器地址生成 `ProxyCommand`，因此不会影响网页、Clash 或其他应用。列入允许清单的地址可以使用任意有效 SSH 端口（`1`–`65535`，例如 `ssh -p 2222 ...`）；未列出的地址仍会被拒绝。

### VS Code 仍走旧路径

先运行 `shvpn doctor <alias>`。确认核心路由正常后，关闭对应的 Remote-SSH 窗口并重新连接。如果启用了 OpenSSH ControlMaster，可以选择运行 `shvpn reconnect <alias>`；它只在你显式调用时请求关闭匹配连接。

## 补丁与许可证

本仓库对 zju-connect v1.2.2 的节点选择逻辑做了一个小修复：当不可探测的 IPv6 节点被跳过时，保持探测结果与原节点对齐，并在全部探测失败时回退到第一个可探测节点。回归测试只使用 RFC 文档示例地址。

本项目及修改内容按 [GNU AGPL v3](LICENSE) 发布。上游归属与固定版本详见 [NOTICE.md](NOTICE.md)。

---

**English summary:** An unofficial, source-built Apple-Silicon macOS helper for ShanghaiTech aTrust/CAS. It exposes `shvpn` and routes only explicitly configured SSH server addresses through a local SOCKS proxy, leaving Clash and other traffic unchanged. See the Chinese guide above for requirements and safety boundaries.
