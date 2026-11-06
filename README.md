# DDNS

腾讯云 DNSPod 的 Linux `/bin/sh` DDNS 脚本，不依赖 Python 或 Bash。
默认把指定主机的**默认线路 A 记录**更新到当前出口公网 IPv4。

## 一条命令下载、安装、配置

在 Linux 上执行，替换域名和密钥（普通用户安装依赖需要 sudo）：

```sh
sh -c 'set -eu; f=$(mktemp); trap '\''rm -f "$f"'\'' EXIT; u=https://raw.githubusercontent.com/zwgwl258/DDNS/main/ddns.sh; if command -v curl >/dev/null 2>&1; then curl -fsSL "$u" -o "$f"; elif command -v wget >/dev/null 2>&1; then wget -O "$f" "$u"; else echo "请先安装 curl 或 wget" >&2; exit 1; fi; sh "$f" "$@"' sh --install --domain example.com --sub home --id '你的SecretId' --secret '你的SecretKey' --ttl 60
```

将 `home.example.com` 解析到运行机器的出口 IPv4：不存在则创建，已存在则更新，IP 和 TTL 未变则跳过。
根域名使用 `--sub '@'`，多级主机记录可用 `--sub a.b`。
`--domain` 是 DNSPod 中托管的完整主域名，不自动猜测注册域。

安装时自动补齐 curl、openssl、jq、证书和 cron；支持 apt-get、dnf、yum、apk、opkg、pacman。
有 curl/wget 才能执行最初下载；包管理器必须可用，软件源及 GitHub 必须可访问。
macOS、Windows 不在自动安装支持范围。精简容器无 init/cron 时需自行启动 cron。

## 自动更新与配置

- 安装后立即执行一次，每 5 分钟自动检查一次。
- 安装目录：`$HOME/.local/share/tencent-ddns`，权限 700。
- 配置：该目录的 `config.json`，权限 600；密钥仅保存在执行机器，不上传 GitHub。
- 重复安装会替换该用户的同一个 DDNS 配置，并备份旧脚本、配置和 crontab。
- `--ip 1.2.3.4` 可指定固定 IPv4；省略时每次重新检测公网 IP。
- cron 输出默认丢弃，手动诊断：`sh "$HOME/.local/share/tencent-ddns/ddns.sh" --run`。
- 多条匹配 A 记录时拒绝修改；其他线路、AAAA 不处理。CNAME 冲突由 API 报错。
- 公网 IP 使用 api4.ipify.org 查询，不向其发送腾讯云密钥。
- 只检测运行机器的出口地址，不保证端口转发或公网入站可达。

## 注意

id/secret 是腾讯云 SecretId / SecretKey，不是旧版 DNSPod ID / Token。
使用仅有目标域名必要读写权限的子账号。也支持环境变量 `TENCENTCLOUD_SECRET_ID`、`TENCENTCLOUD_SECRET_KEY`，此时省略 --id/--secret。
直接把密钥放命令里会进入 shell 历史和短暂进程参数，不要分享完整命令。
TTL 默认 60，最低 TTL 取决于套餐；不支持时明确报错，不擅自调整。
机器时间必须准确，否则腾讯云签名会失败。

## 停用与回滚

使用 `crontab -e` 删除包含 `# tencent-ddns:` 的对应行即可停用。
旧配置和脚本保存在安装目录的 `config.json.bak`、`ddns.sh.bak`；恢复时手动复制回对应文件。
`crontab.bak` 是安装前整个计划表的备份，恢复前请注意不要覆盖后来新增的其他任务。
停用或恢复本地文件不会恢复云端 A 记录，云端地址需在 DNSPod 控制台自行改回。

## 验证范围

已通过 sh 语法、帮助入口及模拟 API 测试：创建、更新、无变化跳过、重复记录拒绝、鉴权失败。运行测试：`sh tests/run.sh`（需要 jq 和 openssl）。没有使用真实腾讯云密钥进行云端写入测试，也未逐一验证所有发行版安装。
