#!/bin/sh
# Tencent Cloud DNSPod DDNS. No Python or Bash required.
set -eu
umask 077
die() { printf '%s\n' "错误：$*" >&2; exit 1; }
usage() {
    echo '安装：sh ddns.sh --install --domain example.com --sub home --id AKIDxxx --secret xxx [--ttl 60]'
    echo '单次：sh ddns.sh --domain example.com --sub home --id AKIDxxx --secret xxx [--ip IPv4]'
    echo '已安装：sh "$HOME/.local/share/tencent-ddns/ddns.sh" --run'
}
MODE=once DOMAIN= SUB=@ ID=${TENCENTCLOUD_SECRET_ID:-} SECRET=${TENCENTCLOUD_SECRET_KEY:-} TTL=60 IP=
BASE=${HOME:?}/.local/share/tencent-ddns
while [ "$#" -gt 0 ]; do
    case "$1" in
        --install) MODE=install; shift ;;
        --run) MODE=run; shift ;;
        --help|-h) usage; exit 0 ;;
        --domain|--sub|--id|--secret|--ttl|--ip)
            [ "$#" -ge 2 ] || die "$1 缺少参数"
            case "$1" in
                --domain) DOMAIN=$2;; --sub) SUB=$2;; --id) ID=$2;;
                --secret) SECRET=$2;; --ttl) TTL=$2;; --ip) IP=$2; EXPLICIT_IP=1;;
            esac
            shift 2 ;;
        *) die "未知参数：$1" ;;
    esac
done

as_root() {
    if [ "$(id -u)" = 0 ]; then "$@";
    elif command -v sudo >/dev/null 2>&1; then sudo "$@";
    else die '安装依赖需要 root 或 sudo'; fi
}
deps() {
    missing=
    for tool in curl openssl jq; do command -v "$tool" >/dev/null 2>&1 || missing=1; done
    if [ "$MODE" = install ]; then command -v crontab >/dev/null 2>&1 || missing=1; fi
    [ -n "$missing" ] || return 0
    [ "$MODE" = install ] || die '缺少 curl / openssl / jq，请先使用 --install'
    if command -v apt-get >/dev/null 2>&1; then
        as_root apt-get update
        as_root apt-get install -y curl openssl jq ca-certificates cron
    elif command -v apk >/dev/null 2>&1; then
        as_root apk add curl openssl jq ca-certificates busybox-suid
    elif command -v dnf >/dev/null 2>&1; then
        as_root dnf install -y curl openssl jq ca-certificates cronie
    elif command -v yum >/dev/null 2>&1; then
        as_root yum install -y curl openssl jq ca-certificates cronie
    elif command -v opkg >/dev/null 2>&1; then
        as_root opkg update
        as_root opkg install curl openssl-util jq ca-bundle
    elif command -v pacman >/dev/null 2>&1; then
        as_root pacman -S --needed --noconfirm curl openssl jq ca-certificates cronie
    else die '无法识别包管理器，请手动安装 curl openssl jq 和 cron'; fi
    for tool in curl openssl jq crontab; do command -v "$tool" >/dev/null 2>&1 || die "依赖仍不可用：$tool"; done
}
deps
if [ "$MODE" = run ]; then
    [ -r "$BASE/config.json" ] || die '配置不存在，请先安装'
    DOMAIN=$(jq -er '.domain' "$BASE/config.json")
    SUB=$(jq -er '.sub' "$BASE/config.json")
    ID=$(jq -er '.id' "$BASE/config.json")
    SECRET=$(jq -er '.secret' "$BASE/config.json")
    TTL=$(jq -er '.ttl' "$BASE/config.json")
    IP=$(jq -r '.ip // ""' "$BASE/config.json")
fi
[ -n "$DOMAIN" ] && [ -n "$SUB" ] && [ -n "$ID" ] && [ -n "$SECRET" ] || die '必须提供 --domain --id --secret'
case "$TTL" in ''|*[!0-9]*) die 'TTL 必须是整数';; esac
[ "$TTL" -ge 1 ] && [ "$TTL" -le 604800 ] || die 'TTL 范围为 1–604800'
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
hash() { openssl dgst -sha256 | sed 's/^.*= //'; }
hex() { od -An -v -tx1 | tr -d ' \n'; }
hmac_hex() { openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" -binary; }
api() {
    action=$1 body=$2
    timestamp=$(date +%s)
    date_utc=$(date -u +%Y-%m-%d)
    scope="$date_utc/dnspod/tc3_request"
    payload_hash=$(printf '%s' "$body" | hash)
    canonical_hash=$(printf 'POST\n/\n\ncontent-type:application/json; charset=utf-8\nhost:dnspod.tencentcloudapi.com\n\ncontent-type;host\n%s' "$payload_hash" | hash)
    key=$(printf 'TC3%s' "$SECRET" | hex)
    key=$(printf '%s' "$date_utc" | hmac_hex "$key" | hex)
    key=$(printf dnspod | hmac_hex "$key" | hex)
    key=$(printf tc3_request | hmac_hex "$key" | hex)
    signature=$(printf 'TC3-HMAC-SHA256\n%s\n%s\n%s' "$timestamp" "$scope" "$canonical_hash" | hmac_hex "$key" | hex)
    # Keep Authorization out of curl's process arguments.
    printf 'Authorization: TC3-HMAC-SHA256 Credential=%s/%s, SignedHeaders=content-type;host, Signature=%s\n' "$ID" "$scope" "$signature" > "$WORK/headers"
    printf '%s' "$body" > "$WORK/body"
    curl -fsS --connect-timeout 10 --max-time 30 https://dnspod.tencentcloudapi.com \
        -H @"$WORK/headers" -H 'Content-Type: application/json; charset=utf-8' \
        -H "X-TC-Action: $action" -H 'X-TC-Version: 2021-03-23' \
        -H "X-TC-Timestamp: $timestamp" --data-binary @"$WORK/body" > "$WORK/response"
    jq -e '.Response | type == "object"' "$WORK/response" >/dev/null || die 'API 返回无效 JSON'
}
check_api() {
    code=$(jq -r '.Response.Error.Code // empty' "$WORK/response")
    [ -z "$code" ] || die "$code：$(jq -r '.Response.Error.Message' "$WORK/response")"
}
if [ -z "$IP" ]; then
    IP=$(curl -4fsS --connect-timeout 10 --max-time 20 https://api4.ipify.org) || die '公网 IPv4 获取失败'
fi
printf '%s\n' "$IP" | awk -F. 'NF!=4 {exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || length($i)>3 || $i>255) exit 1}' || die '无效 IPv4'
query=$(jq -cn --arg d "$DOMAIN" --arg s "$SUB" '{Domain:$d,SubDomain:$s,RecordType:"A",RecordLineId:"0",Limit:100}')
api DescribeRecordList "$query"
code=$(jq -r '.Response.Error.Code // empty' "$WORK/response")
if [ "$code" = ResourceNotFound.NoDataOfRecord ]; then
    records='[]'
else
    check_api
    records=$(jq -c --arg s "$SUB" '[.Response.RecordList[] | select(.Name==$s and .Type=="A" and .LineId=="0")]' "$WORK/response")
fi
count=$(printf '%s' "$records" | jq length)
[ "$count" -le 1 ] || die '存在多条默认线路 A 记录，拒绝误改'
payload=$(jq -cn --arg d "$DOMAIN" --arg s "$SUB" --arg ip "$IP" --argjson ttl "$TTL" '{Domain:$d,SubDomain:$s,RecordType:"A",RecordLine:"默认",RecordLineId:"0",Value:$ip,TTL:$ttl}')
if [ "$count" = 1 ]; then
    if printf '%s' "$records" | jq -e --arg ip "$IP" --argjson ttl "$TTL" '.[0] | .Value==$ip and .TTL==$ttl' >/dev/null; then
        echo "无需更新：$SUB.$DOMAIN -> $IP"
    else
        record_id=$(printf '%s' "$records" | jq '.[0].RecordId')
        payload=$(printf '%s' "$payload" | jq -c --argjson id "$record_id" '. + {RecordId:$id}')
        api ModifyRecord "$payload"; check_api
        echo "已更新：$SUB.$DOMAIN -> $IP TTL=$TTL"
    fi
else
    api CreateRecord "$payload"; check_api
    echo "已创建：$SUB.$DOMAIN -> $IP TTL=$TTL"
fi

if [ "$MODE" = install ]; then
    # Cron percent/newline and shell quoting must not be allowed in the install path.
    case "$BASE" in *[!a-zA-Z0-9_./-]*) die 'HOME 路径包含不支持的字符';; esac
    [ -f "$0" ] || die '请先下载为文件再安装，不支持管道执行'
    mkdir -p "$BASE"; chmod 700 "$BASE"
    [ ! -f "$BASE/config.json" ] || cp -p "$BASE/config.json" "$BASE/config.json.bak"
    [ ! -f "$BASE/ddns.sh" ] || cp -p "$BASE/ddns.sh" "$BASE/ddns.sh.bak"
    cp "$0" "$BASE/ddns.sh.new"; chmod 700 "$BASE/ddns.sh.new"; mv "$BASE/ddns.sh.new" "$BASE/ddns.sh"
    jq -n --arg d "$DOMAIN" --arg s "$SUB" --arg id "$ID" --arg secret "$SECRET" --argjson ttl "$TTL" --arg ip "$IP" \
        '{domain:$d,sub:$s,id:$id,secret:$secret,ttl:$ttl,ip:$ip}' > "$BASE/config.json.new"
    # Only persist an explicitly supplied IP; auto-detected addresses must refresh each run.
    if [ -z "${EXPLICIT_IP:-}" ]; then jq '.ip=""' "$BASE/config.json.new" > "$WORK/config"; cp "$WORK/config" "$BASE/config.json.new"; fi
    chmod 600 "$BASE/config.json.new"; mv "$BASE/config.json.new" "$BASE/config.json"
    LC_ALL=C crontab -l > "$WORK/cron.old" 2> "$WORK/cron.error" || {
        grep -qi 'no crontab' "$WORK/cron.error" || die "读取 crontab 失败：$(cat "$WORK/cron.error")"
    }
    cp "$WORK/cron.old" "$BASE/crontab.bak"
    awk -v marker="# tencent-ddns:$BASE" 'index($0,marker)==0' "$WORK/cron.old" > "$WORK/cron.new"
    printf '*/5 * * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/sh %s/ddns.sh --run >/dev/null 2>&1 # tencent-ddns:%s\n' "$BASE" "$BASE" >> "$WORK/cron.new"
    crontab "$WORK/cron.new" || die '配置已保存，但安装 crontab 失败'
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if systemctl list-unit-files cron.service --no-legend 2>/dev/null | grep -q cron.service; then as_root systemctl enable --now cron;
        else as_root systemctl enable --now crond; fi
    elif command -v rc-service >/dev/null 2>&1; then
        as_root rc-update add crond default; as_root rc-service crond start
    elif [ -x /etc/init.d/cron ]; then
        as_root /etc/init.d/cron start
        [ ! -x /sbin/uci ] || { as_root /etc/init.d/cron enable; }
    else
        echo '警告：已写入计划，但无法自动启动 cron。容器中需自行运行 cron 守护进程。' >&2
    fi
    echo "安装完成：$BASE，每 5 分钟检查一次；配置权限 600。"
fi
