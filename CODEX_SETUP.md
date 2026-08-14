# 用 Codex 配置 ShanghaiTech shvpn

把下面整段提示词复制给 Codex，再提供一个或多个服务器地址。Codex 不需要 SSH alias。

```text
请帮我安装并配置 https://github.com/eacsai/shanghaitech-shvpn 。

1. 先阅读 README.md、SECURITY.md 和 install.zsh；只询问一个或多个服务器地址。
2. 不要询问、读取或输出密码、验证码、SSH 私钥、VPN callback URL、client-data.json、完整日志或完整 SSH 配置。
3. 不要修改或退出 Clash Verge，不要修改系统代理、TUN、aTrust、远程服务器或现有 SSH 会话。
4. 确认设备是 Apple Silicon macOS、go version 为 go1.25.6 darwin/arm64，并有 Python 3.10–3.14（含 pip）和 Google Chrome。
5. 使用：
   ./install.zsh --non-interactive --target HOST [重复 --target HOST ...] --add-path
   每个 --target 后只放一个服务器地址，不自行发明 alias、端口或用户名。
6. 安装后只做本地验证：新开 zsh 后检查 command -v shvpn、shvpn status、shvpn doctor，以及 /usr/bin/ssh -G HOST 的 hostname 和 proxycommand。除非我另行批准，不要登录远程服务器。
7. doctor 返回 0 才能报告全部通过；1 表示核心正常但需解释警告；2 表示状态不可信并应停止；64 表示参数错误。
8. 首次认证或过期时，让我亲自在终端运行 shvpn login 并完成专用 Chrome 窗口中的登录。脚本会自动捕获 callback；不要读取、输出或要求我复制它，也不要代替我处理验证码。
9. 遇到符号链接、所有者异常、哈希不匹配、托管标记歧义、SSH 冲突或不可信端口时立即停止，不要强制覆盖、kill 或删除。
```

成功时，`command -v shvpn` 指向 `~/.local/bin/shvpn`；配置目标的 `ssh -G HOST` 中 `hostname` 与输入完全一致，`proxycommand` 指向绝对路径的 `shanghaitech-ssh-route %h %p`；未配置目标不应获得该代理。

用户已有 alias 会按最终 `HostName` 自动接入，字符串必须与某个已配置地址完全一致，不能通过 DNS 推断等价。安全的 `~/.ssh` Include 会被检查；若枚举不完整，只解释警告并建议用户运行 `shvpn doctor ALIAS`，不要把 alias 变成安装必填项。

后续可用 `shvpn add HOST_OR_ALIAS` 和 `shvpn remove HOST_OR_ALIAS` 管理目标。不要自动运行 `shvpn reconnect`：它会请求匹配的 ControlMaster 退出，可能中断终端、VS Code 或 Codex。卸载优先使用 `shvpn uninstall`；只有命令内卸载不可用或迁移中断时才使用仓库的 `./uninstall.zsh`。
