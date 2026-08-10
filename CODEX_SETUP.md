# 用 Codex 配置 ShanghaiTech shvpn

把下面整段提示词复制给 Codex，然后提供一个或多个 SSH 服务器地址即可。

```text
请帮我安装并配置 https://github.com/eacsai/shanghaitech-shvpn 。

安全要求：
1. 先阅读仓库 README.md、SECURITY.md 和 install.zsh。
2. 只询问一个或多个服务器地址；不要询问 SSH alias、端口、用户名，也不要询问、读取或输出密码、短信验证码、SSH 私钥、VPN callback URL、client-data.json 或完整 VPN 日志。
3. 不要修改或退出 Clash Verge，不要修改 macOS 系统代理、TUN、aTrust、远程服务器或我现有的 SSH 会话。
4. 确认是 Apple Silicon macOS 且 go version 为 go1.25.6 darwin/arm64。
5. 使用仓库规定的非交互格式执行安装：
   ./install.zsh --non-interactive --target HOST [继续重复 --target HOST ...] --add-path
   每个 --target 后只能有一个服务器地址，不要自行发明 alias、port、username 或其他参数。
6. 安装完成后只做本地验证：新开 zsh 后检查 command -v shvpn、shvpn status，以及用 /usr/bin/ssh -G HOST 验证 hostname 和 proxycommand。不要直接登录服务器，除非我另外批准只读 SSH 探测。
7. 首次认证或认证过期时，让我亲自在终端运行 shvpn login 并完成浏览器操作；不要代替我处理验证码或回调地址。
8. 如果任何文件是符号链接、所有者异常、已有托管标记不明确、哈希不匹配或端口状态不可信，立即停止并解释，不要强行覆盖、kill 或删除。
```

## Codex 应该看到的成功状态

- `command -v shvpn` 指向当前用户的 `~/.local/bin/shvpn`。
- `shvpn status`：退出码 `0` 表示可信 VPN 正在运行；`1` 表示安全停止；其他退出码表示拒绝继续。
- `ssh -G <服务器地址>` 中的 `hostname` 与用户提供值一致，`proxycommand` 指向安装时生成的绝对路径 `shanghaitech-ssh-route %h %p`。
- 未配置的服务器地址不包含本项目的 `ProxyCommand`。
- 用户名和非默认端口由用户在连接时通过 `ssh user@HOST`、`ssh -p PORT user@HOST` 提供；配置过的地址允许任意 `1`–`65535` 端口。

如果从旧版重装，旧 alias 以及安装器写入的 `Port`、`User` 会被地址模式替换；后续应直接使用服务器地址。

## 后续使用

```zsh
shvpn login   # 仅首次或认证过期
shvpn         # 后台启动
ssh <服务器地址>
shvpn stop
```
