#!/bin/sh
set -eu

blue= green= yellow= red= reset=
if [ -t 1 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
    blue=$(printf '\033[1;36m')
    green=$(printf '\033[1;32m')
    yellow=$(printf '\033[1;33m')
    red=$(printf '\033[1;31m')
    reset=$(printf '\033[0m')
fi

die() {
    printf '\n%s[错误]%s %s\n' "$red" "$reset" "$*" >&2
    exit 1
}

step() {
    printf '\n%s[%s/5]%s %s\n' "$blue" "$1" "$reset" "$2"
}

ok() {
    printf '  %s[完成]%s %s\n' "$green" "$reset" "$*"
}

confirm=no
interface=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            printf '%s\n' '用法：sh install.sh [--yes] [网卡名 | --all-interfaces]' \
                '  -y, --yes          跳过安装确认，用于自动化' \
                '  --all-interfaces   选择所有非回环网卡' \
                '  NO_COLOR=1         关闭彩色输出'
            exit 0
            ;;
        -y|--yes) confirm=yes ;;
        --all-interfaces)
            [ -z "$interface" ] || die '请只指定一种网卡范围。'
            interface='*'
            ;;
        -*|'') die "未知参数：$1。使用 --help 查看用法。" ;;
        *)
            [ -z "$interface" ] || die '请只指定一种网卡范围。'
            interface=$1
            ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] || die '请以 root 权限运行。'
[ -r /etc/os-release ] || die '无法读取系统版本。'
. /etc/os-release

case "${ID-}:${VERSION_ID-}" in
    debian:12|debian:13)
        [ -d /run/systemd/system ] || die 'Debian 需要运行 systemd。'
        init=systemd
        ;;
    alpine:*)
        [ -x /sbin/openrc-run ] && command -v rc-update >/dev/null ||
            die 'Alpine 需要 OpenRC。'
        init=OpenRC
        ;;
    *) die '支持 Debian 12、Debian 13 和 Alpine Linux（OpenRC）。' ;;
esac

config=/etc/geo-cn.nft
if [ -z "$interface" ]; then
    interface='*'
    if [ -r "$config" ]; then
        saved=$(sed -n 's/^[[:space:]]*iifname "\([^"]*\)" fib daddr type local .*/\1/p' "$config" | head -n 1)
        if [ -n "$saved" ]; then interface=$saved; fi
    fi
fi

printf '\n%s中国大陆 IP 端口过滤%s\n' "$blue" "$reset"
printf '  %-12s %s (%s)\n' '系统' "${PRETTY_NAME:-$ID}" "$init"
printf '  %-12s %s\n' '协议和端口' 'TCP / UDP 30000–60000'
printf '  %-12s %s\n' '来源范围' '中国大陆 IPv4 / IPv6'

if [ "$confirm" = no ] && [ -t 0 ] && [ -t 1 ]; then
    current=$interface
    if [ "$current" = '*' ]; then current='所有非回环网卡'; fi
    printf '\n入站网卡 [%s]（回车保留，输入 * 选择全部）：' "$current"
    IFS= read -r selection || die '输入已结束，安装取消。'
    if [ -n "$selection" ]; then interface=$selection; fi
fi

case "$interface" in
    '*')
        scope='所有非回环网卡'
        interface_match='iifname != "lo"'
        ;;
    lo|*[!a-zA-Z0-9_.:-]*)
        die "无效的入站网卡：$interface"
        ;;
    *)
        [ "${#interface}" -le 15 ] && ip link show dev "$interface" >/dev/null 2>&1 ||
            die "找不到入站网卡：$interface"
        scope=$interface
        interface_match="iifname \"$interface\""
        ;;
esac
printf '  %-12s %s\n' '入站网卡' "$scope"

if [ "$confirm" = no ]; then
    [ -t 0 ] && [ -t 1 ] || die '非交互安装请传入 --yes。'
    printf '\n%s[提示]%s 如果 SSH 也使用此端口范围，建议从服务器控制台安装。\n' "$yellow" "$reset"
    printf '应用规则并设置开机加载？[y/N] '
    IFS= read -r answer || die '输入已结束，安装取消。'
    case "$answer" in
        y|Y|yes|YES) ;;
        *) printf '\n已取消。\n'; exit 0 ;;
    esac
fi

step 1 '检查运行依赖'
if ! command -v nft >/dev/null || ! command -v curl >/dev/null ||
   ! command -v flock >/dev/null || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
    printf '  正在安装所需软件包…\n'
    if [ "$init" = systemd ]; then
        apt-get update -qq && apt-get install -y -qq nftables curl ca-certificates util-linux ||
            die '依赖安装失败，请检查 APT 输出。'
    else
        apk add --no-cache --quiet nftables curl ca-certificates 'cmd:flock' ||
            die '依赖安装失败，请检查 APK 软件源。'
    fi
fi
nft_bin=$(command -v nft) || die '找不到 nft 命令。'
mkdir -p /run/lock
exec 9>/run/lock/geo-cn-install.lock
flock -n 9 || die '已有安装进程正在运行，请稍后重试。'
tmp=$(mktemp -d /etc/.geo-cn-install.XXXXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ok '依赖检查通过'

download() {
    curl -fLsS --retry 3 --connect-timeout 15 --max-time 120 \
        --proto '=https' --proto-redir '=https' "$1" -o "$2" || die '下载网段失败。'
    [ -s "$2" ] || die '下载的网段列表为空。'
    if LC_ALL=C grep -qEv "$3" "$2"; then die '下载的网段格式有误。'; fi
}

step 2 '下载中国大陆网段'
download https://ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone \
    "$tmp/cn4" '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
ok "IPv4：$(awk 'END {print NR}' "$tmp/cn4") 个网段"
download https://ipdeny.com/ipv6/ipaddresses/aggregated/cn-aggregated.zone \
    "$tmp/cn6" '^[0-9A-Fa-f:]+/[0-9]{1,3}$'
ok "IPv6：$(awk 'END {print NR}' "$tmp/cn6") 个网段"

step 3 '生成并检查 nftables 规则'
cat > "$tmp/geo-cn.nft" <<EOF
add table inet geo_cn
delete table inet geo_cn

table inet geo_cn {
    set cn4 {
        type ipv4_addr
        flags interval
        auto-merge
        elements = { $(awk 'NR > 1 {printf ", "} {printf "%s", $0}' "$tmp/cn4") }
    }

    set cn6 {
        type ipv6_addr
        flags interval
        auto-merge
        elements = { $(awk 'NR > 1 {printf ", "} {printf "%s", $0}' "$tmp/cn6") }
    }

    chain incoming {
        type filter hook prerouting priority -110; policy accept;

        $interface_match fib daddr type local ct direction original meta l4proto { tcp, udp } th dport 30000-60000 ip saddr @cn4 counter drop
        $interface_match fib daddr type local ct direction original meta l4proto { tcp, udp } th dport 30000-60000 ip6 saddr @cn6 counter drop
    }
}
EOF
chmod 0644 "$tmp/geo-cn.nft"
"$nft_bin" -c -f "$tmp/geo-cn.nft" || die '规则检查失败。'
ok '两条拦截规则通过检查'

step 4 '应用 IPv4 / IPv6 规则'
"$nft_bin" -f "$tmp/geo-cn.nft" || die '规则加载失败。'
mv -f -- "$tmp/geo-cn.nft" "$config"
ok 'TCP / UDP 30000–60000 已启用过滤'

step 5 "设置 $init 开机加载"
if [ "$init" = systemd ]; then
    cat > "$tmp/geo-cn.service" <<EOF
[Unit]
Description=Load China IP port filtering rules
After=nftables.service firewalld.service ufw.service
Before=docker.service

[Service]
Type=oneshot
ExecStart=$nft_bin -f /etc/geo-cn.nft

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$tmp/geo-cn.service"
    mv -f -- "$tmp/geo-cn.service" /etc/systemd/system/geo-cn.service
    systemctl daemon-reload && systemctl enable --quiet geo-cn.service ||
        die '规则已生效，但未能设置 systemd 开机加载。'
else
    cat > "$tmp/geo-cn" <<EOF
#!/sbin/openrc-run
description="Load China IP port filtering rules"
extra_commands="reload"

depend() {
    need localmount
    after nftables
    before docker
}

start() {
    ebegin "Loading geo-cn firewall rules"
    "$nft_bin" -f /etc/geo-cn.nft
    eend \$?
}

stop() {
    ebegin "Removing geo-cn firewall rules"
    "$nft_bin" -f - <<'RULES'
add table inet geo_cn
delete table inet geo_cn
RULES
    eend \$?
}

reload() {
    start
}
EOF
    chmod 0755 "$tmp/geo-cn"
    mv -f -- "$tmp/geo-cn" /etc/init.d/geo-cn
    rc-update add geo-cn default >/dev/null ||
        die '规则已生效，但未能设置 OpenRC 开机加载。'
fi
ok '已启用开机加载'

printf '\n%s安装完成%s\n' "$green" "$reset"
printf '  查看规则与计数：nft list chain inet geo_cn incoming\n\n'
