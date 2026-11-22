# 中国大陆 IP 端口过滤

支持 Debian 12 / 13（systemd）和 Alpine Linux（OpenRC）。用 nftables 丢弃来自 IPdeny 中国大陆 IPv4 / IPv6 网段、访问本机 TCP 或 UDP `30000–60000` 的流量。其他端口继续由现有防火墙管理。Docker 常规端口映射按宿主机端口匹配。

## 一键安装

在服务器的终端执行。以下命令假设你已登录 root 并装有 `curl`。普通用户可用 `sudo sh` 或 `doas sh` 执行脚本。

```sh
curl -fsSLo geo-cn-install.sh https://raw.githubusercontent.com/brian952700/debian-geo-cn-firewall/main/install.sh && sh geo-cn-install.sh
```

Alpine 精简安装缺少 `curl` 时，先以 root 执行 `apk add --no-cache curl ca-certificates`。Debian 缺少 `curl` 时，先执行 `apt-get update && apt-get install -y curl ca-certificates`。

脚本会显示系统、端口、来源范围和网卡，确认后按五步执行。首次安装默认匹配所有非回环网卡上的本机入站连接。更新时默认沿用先前选定的网卡。

如果 SSH 也使用 `30000–60000` 范围内的端口，并且你从中国大陆地址连接，请通过云厂商控制台安装。

## 自动化与颜色

```sh
sh geo-cn-install.sh --yes             # 跳过确认，更新时沿用原网卡
sh geo-cn-install.sh --yes ens3        # 只匹配 ens3 入站
sh geo-cn-install.sh --yes --all-interfaces
NO_COLOR=1 sh geo-cn-install.sh          # 关闭颜色，保留交互
```

## 更新与检查

重新下载并运行安装脚本即可更新网段或升级旧版。用 `nft list chain inet geo_cn incoming` 查看规则与丢包计数。

如果现有防火墙重载时清空了整个 nftables 规则集，Debian 执行 `systemctl start geo-cn.service`，Alpine 执行 `rc-service geo-cn reload`。

## 卸载

Debian：

```sh
systemctl disable --now geo-cn.service
rm -f /etc/systemd/system/geo-cn.service
systemctl daemon-reload
```

Alpine：

```sh
rc-update del geo-cn default
rc-service geo-cn stop
rm -f /etc/init.d/geo-cn
```

最后删除当前规则及其配置，两种系统都适用：

```sh
nft -f - <<'EOF'
add table inet geo_cn
delete table inet geo_cn
EOF
rm -f /etc/geo-cn.nft
```

网段来源为 [IPdeny](https://www.ipdeny.com/ipblocks/)。过滤按服务器看到的源 IP 判断，经代理或 CDN 转发时，服务器通常看到的是转发节点的 IP。
