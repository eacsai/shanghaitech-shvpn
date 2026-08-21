# Linux 桌面安装

Linux 版适用于 `amd64` 或 `arm64` 桌面。它不会建立 TUN、修改系统路由或接管全局代理；只有安装时明确列出的 SSH `HostName` 会在 VPN 运行时经过本机 `127.0.0.1:11080`。

## 1. 准备依赖

Ubuntu/Debian：

```bash
sudo apt-get update
sudo apt-get install -y git zsh openssh-client lsof netcat-openbsd python3 python3-pip ca-certificates
```

另外安装 Google Chrome 和与本机架构匹配的 Go 1.25.6，并检查：

```bash
uname -m
zsh --version
go version
python3 --version
google-chrome --version || google-chrome-stable --version
nc -h 2>&1 | grep -- '-X'
```

`go version` 应显示 `go1.25.6 linux/amd64` 或 `go1.25.6 linux/arm64`。需要 OpenBSD 版 `nc`；BusyBox 或传统 netcat 不支持本项目所需的 SOCKS5 参数。

## 2. 安装

把需要经过 VPN 的服务器地址逐个传给 `--target`：

```bash
git clone --branch codex/linux-support --single-branch \
  https://github.com/eacsai/shanghaitech-shvpn.git
cd shanghaitech-shvpn
./install.zsh --non-interactive \
  --target gpu1.example.edu \
  --target gpu2.example.edu \
  --add-path
```

`--target` 必须是 SSH 最终 `HostName`（通常是 IP），不要填 alias、用户名或端口。安装器会识别已经指向这些地址的 SSH alias。

Go 1.25.6 请从 [Go 官方发行页](https://go.dev/dl/) 安装与 `uname -m` 对应的包，并校验 SHA-256：

- `go1.25.6.linux-amd64.tar.gz`：`f022b6aad78e362bcba9b0b94d09ad58c5a70c6ba3b7582905fababf5fe0181a`
- `go1.25.6.linux-arm64.tar.gz`：`738ef87d79c34272424ccdf83302b7b0300b8b096ed443896089306117943dd5`

不要用发行版自带的其他 Go 版本构建。安装到用户目录即可，例如 `~/.local/opt/go`，安装 shvpn 时把该 `bin` 放在 `PATH` 最前面。

重新登录桌面会话，或先执行 `source ~/.profile`。安装器会自动识别已有 SSH alias；只要 alias 最终的 `HostName` 与某个 target 完全相同，终端、VS Code Remote-SSH 和调用系统 `ssh` 的 Codex/Grok 都会使用同一套无感路由。

## 3. 登录与使用

首次登录必须在 Linux 图形桌面的终端中运行：

```bash
shvpn login
```

该终端必须继承 `DISPLAY` 或 `WAYLAND_DISPLAY`。脚本会启动独立 Chrome 窗口，你亲自完成 CAS/短信验证；callback 会自动捕获，不需要复制。以后可用：

```bash
shvpn             # 后台启动并复用登录状态
ssh gpu-alias     # 或 ssh 服务器地址
shvpn doctor gpu-alias
shvpn stop
```

从纯 SSH shell 启动 Grok/Codex 时，可以使用已经运行的 VPN 和 `ssh` 路由，但若登录过期，应回到有桌面的终端执行 `shvpn login`。不要手工设置虚假的 `DISPLAY`。

终端出现 `SMS verification code:` 时，在**同一个终端**输入短信验证码，没有回显是正常的。不要把验证码发到聊天里，也不要复制 callback URL。

## 4. 验证与维护

```bash
shvpn status
shvpn doctor
ssh -G gpu-alias | grep -E '^(hostname|user|port|proxycommand) '
shvpn add NEW_HOST_OR_ALIAS
shvpn remove OLD_HOST_OR_ALIAS
shvpn reconnect gpu-alias   # 仅在网络切换后需要，可能中断现有会话
shvpn uninstall
```

Linux 状态目录默认是 `~/.local/state/shanghaitech-shvpn/`，设置了 `XDG_STATE_HOME` 时跟随该变量。登录 profile、VPN 登录状态和日志在卸载后保留，不要上传或分享。

## 5. 本地 SSH 建议（不随 shvpn 安装）

这些是本机 OpenSSH 配置，安装器不会代做，也不要把私钥、密码或真实内网地址提交到 Git。

免密登录：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
ssh-copy-id -i ~/.ssh/id_ed25519.pub gpu-alias
```

`ssh-copy-id` 需要在能弹出密码提示的真实终端里执行一次。首次连接若提示 host fingerprint，先核对再输入 `yes`。

只给需要走 VPN 的 alias 打开连接复用，可加快第二次及以后的 `ssh`：

```sshconfig
Host gpu-alias
    ControlMaster auto
    ControlPath ~/.ssh/cm/%C
    ControlPersist 8h
```

并创建 `mkdir -p -m 700 ~/.ssh/cm`。

复用会把第一次 SSH 的走线记住一段时间。`shvpn` / `shvpn stop` 或换网络之后，旧连接可能还走之前的路径。这时再执行：

```bash
shvpn reconnect gpu-alias
```

或 `ssh -O exit gpu-alias`。平时在同一网络里反复 SSH，不必 reconnect。

## 6. Linux 登录排障

| 现象 | 原因与处理 |
|---|---|
| 停在 “opening the dedicated ShanghaiTech CAS login window”，Chrome 不出现 | VPN 客户端把 CAS 提示写到 stdout，管道下 Go 会全量缓冲。当前分支用 PTY 读取提示；请使用本仓库 Linux 分支，不要用只含 macOS 锁文件的旧提交。 |
| `SMS verification requires an interactive terminal`，Chrome 随即关闭 | 必须在图形桌面终端运行 `shvpn login`。当前分支在 `/dev/tty` 不可用时回退到 stdin。 |
| `THESE PACKAGES DO NOT MATCH THE HASHES`（playwright） | 登录依赖锁需要包含本机架构的 Linux wheel。当前分支已加入 amd64 Playwright / greenlet 官方哈希。 |
| `Go go1.25.6 linux/amd64 is required` | 构建只用官方 Go 1.25.6，并把该 `go` 放在 `PATH` 最前。 |
| Chrome 窗口空白或无法启动 | 容器/无沙箱桌面需要 `--no-sandbox` 等参数；当前分支会传给专用登录 Chrome。 |

不要把 `client-data.json`、CAS cookie、callback、完整日志或 SSH 私钥提交到 GitHub。
