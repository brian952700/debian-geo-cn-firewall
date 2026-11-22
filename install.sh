#!/usr/bin/env bash
set -euo pipefail

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

if [[ $# -eq 1 && $1 == --help ]]; then
    printf 'Usage: bash install.sh [external-interface]\n'
    exit 0
fi
(( $# <= 1 )) || die 'Usage: bash install.sh [external-interface]'
(( EUID == 0 )) || die 'Run as root or use sudo.'

source /etc/os-release
[[ $ID == debian && ( $VERSION_ID == 12 || $VERSION_ID == 13 ) ]] ||
    die 'This installer requires Debian 12 or Debian 13.'
[[ -d /run/systemd/system ]] || die 'This installer requires systemd.'

if (( $# == 1 )); then
    [[ $1 =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || die 'Invalid interface name.'
    ip link show dev "$1" >/dev/null || die "Interface not found: $1"
    interface_match="iifname \"$1\""
else
    interface_match='iifname != "lo"'
fi

if ! command -v nft >/dev/null || ! command -v curl >/dev/null ||
    [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    apt-get update
    apt-get install -y nftables curl ca-certificates
fi

exec 9>/run/lock/geo-cn-install.lock
flock 9
tmp=$(mktemp -d /etc/.geo-cn-install.XXXXXXXX)
trap 'rm -rf -- "$tmp"' EXIT

download() {
    local url=$1 output=$2 pattern=$3
    curl -fLsS --retry 3 --connect-timeout 15 --max-time 120 \
        --proto '=https' --proto-redir '=https' "$url" -o "$output"
    [[ -s $output ]] || die "Empty IP list: $url"
    if LC_ALL=C grep -qEv "$pattern" "$output"; then
        die "Unexpected IP list format: $url"
    fi
}

download https://ipdeny.com/ipblocks/data/aggregated/cn-aggregated.zone \
    "$tmp/cn4" '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
download https://ipdeny.com/ipv6/ipaddresses/aggregated/cn-aggregated.zone \
    "$tmp/cn6" '^[0-9A-Fa-f:]+/[0-9]{1,3}$'

cat > "$tmp/geo-cn.nft" <<EOF
add table inet geo_cn
delete table inet geo_cn

table inet geo_cn {
    set cn4 {
        type ipv4_addr
        flags interval
        auto-merge
        elements = { $(paste -sd, "$tmp/cn4") }
    }

    set cn6 {
        type ipv6_addr
        flags interval
        auto-merge
        elements = { $(paste -sd, "$tmp/cn6") }
    }

    chain incoming {
        type filter hook prerouting priority -110; policy accept;

        $interface_match fib daddr type local ct direction original meta l4proto { tcp, udp } th dport 30000-60000 ip saddr @cn4 counter drop
        $interface_match fib daddr type local ct direction original meta l4proto { tcp, udp } th dport 30000-60000 ip6 saddr @cn6 counter drop
    }
}
EOF

cat > "$tmp/geo-cn.service" <<'EOF'
[Unit]
Description=Load China IP port filtering rules
After=nftables.service firewalld.service ufw.service
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/geo-cn.nft

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$tmp/geo-cn.nft" "$tmp/geo-cn.service"
nft -c -f "$tmp/geo-cn.nft"
nft -f "$tmp/geo-cn.nft"
mv -fT -- "$tmp/geo-cn.nft" /etc/geo-cn.nft
mv -fT -- "$tmp/geo-cn.service" /etc/systemd/system/geo-cn.service
systemctl daemon-reload
systemctl enable geo-cn.service
nft list chain inet geo_cn incoming
