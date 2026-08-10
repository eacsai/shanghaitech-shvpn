# 安全说明

## 信任边界

这是连接 `vpn.shanghaitech.edu.cn` 的非官方 aTrust/CAS 封装，不能保证学校未来的网关或认证变化仍兼容。SOCKS 只绑定 `127.0.0.1:11080`。

安装器固定 [zju-connect](https://github.com/Mythologyli/zju-connect) `v1.2.2`、commit `a759261b76ed653900911559400005b40a31392a`，并验证：

- `go.mod`: `d06b5a0423a5ce23887222d1e3f2b06b0f1c63f16873d87887c0c1147a5f7204`
- `go.sum`: `8af52b375ebe736a54883a39bdffff6cdfb8f55face981cbbd13e3362e2e0572`

之后才应用补丁、运行测试并源码构建；不下载预编译 VPN 二进制，不请求 `sudo`。

## 进程与路由

`shvpn` 只信任同时满足当前 UID、固定绝对可执行文件、固定完整 argv 和唯一回环监听者的 VPN 进程。停止时只向已验证进程发送 `SIGINT`，不会升级为 `SIGKILL`。不可信或含糊状态拒绝操作。

生命周期、安装/迁移、动态目标更新和卸载共享当前用户拥有的 0600 非阻塞配置锁；生命周期在配置锁内再取得操作锁。冲突返回 `75`，锁描述符 close-on-exec，VPN 子进程不会继承。`add/remove/uninstall` helper 必须通过所有者、可执行位和格式 2 清单哈希验证；分派器不会跨 helper 调用持锁。

SSH helper 只接受 0600 allowlist 中的最终 `HostName` 和有效端口 `1`–`65535`。VPN 停止时直连，可信运行时走 SOCKS，不可信时拒绝。路由检查与连接不是原子操作，因此同一 macOS 用户下的恶意进程理论上可能在检查后抢占端口；本项目不把同 UID 恶意进程视作可完全隔离的边界。

`Match final host` 在 alias 应用 `HostName` 后匹配，且只接受与 allowlist **完全一致**的字符串，不通过 DNS 扩展信任。用户已有 alias 不被复制或改写。

OpenSSH 多数值“先取得者生效”。安装器和 helper 会检查主配置及 `~/.ssh` 内安全、当前用户所有、非符号链接、深度/数量受限的 Include；发现已存在的 `ProxyCommand`/`ProxyJump` 冲突会在写入前失败。复杂、目录外或无法完整枚举的 Include 只警告，不伪称已完整检查。

这些检查用 `-F ~/.ssh/config`，不涵盖 `/etc/ssh/ssh_config`。MDM 或系统级配置可能覆盖后置规则；应另用不带 `-F` 的 `/usr/bin/ssh -G ALIAS` 核对最终 `proxycommand`。

`doctor` 只做本地解析，不建立远程连接。`reconnect` 仅在用户显式调用时，对已验证目标依次执行 `ssh -O check` 和 `ssh -O exit`；不删除 socket、不扫描或 kill SSH 进程，但可能中断终端、VS Code 或 Codex 会话。

## 文件、更新与卸载

安装器拒绝符号链接、非当前用户文件、损坏标记和不匹配哈希。首次安装保存基线；安装、重装和 `add/remove` 写入前保存时间戳备份。动态更新只改 SSH 托管块、目标 allowlist 和清单，保留托管块外配置，并在普通错误时回滚。

多文件更新无法抵抗任意时刻的断电或 `SIGKILL`。此类中断会 fail closed 并保留备份；使用仓库的 `./uninstall.zsh` 退役/恢复受信安装后再重装。格式 1→2 迁移若出现未被旧清单记录的 helper，安装器同样拒绝继续，独立卸载器仍可恢复。

`shvpn uninstall` 在停止可信 VPN 后取得配置锁、重复完整预检和监听状态检查，再恢复基线。修改过的托管块或含糊状态会让它在写入前停止。无关 SOCKS 监听者只会收到警告，绝不会被停止。卸载保留 `client-data.json`、日志和恢复归档。

## 隐私与报告

不要在 issue 或公开输出中提供密码、验证码、CAS callback、cookie/ticket、私钥、`client-data.json`、完整 VPN 日志、完整 SSH 配置、真实用户名/服务器地址或可识别个人的路径。`doctor` 也可能显示本地地址和 alias，分享前请删减。

安全问题请通过 GitHub Security 私下报告；账号或校园基础设施问题应联系学校官方支持。
