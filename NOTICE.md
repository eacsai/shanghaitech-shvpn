# Notices and attribution

This project is unofficial and is not affiliated with or endorsed by ShanghaiTech University, Sangfor Technologies, or the upstream zju-connect maintainers.

The VPN client source is fetched at install time from:

- Project: `Mythologyli/zju-connect`
- URL: https://github.com/Mythologyli/zju-connect
- Tag: `v1.2.2`
- Commit: `a759261b76ed653900911559400005b40a31392a`
- License: GNU Affero General Public License v3.0

The repository patch modifies `client/atrust/node.go` and adds focused regression tests. It keeps compacted probe results aligned with their original nodes when unsupported IPv6 endpoints are skipped and falls back to the first probeable node when all probes fail.

ShanghaiTech's official VPN instructions are published at:
https://it.shanghaitech.edu.cn/2021/0424/c8423a63191/page.htm

The official instructions describe the supported aTrust client workflow. This repository provides a community-maintained experimental alternative and makes no compatibility or support guarantee.
