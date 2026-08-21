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
git clone https://github.com/eacsai/shanghaitech-shvpn.git
cd shanghaitech-shvpn
./install.zsh --non-interactive \
  --target gpu1.example.edu \
  --target gpu2.example.edu \
  --add-path
```

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
