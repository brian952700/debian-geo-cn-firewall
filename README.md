# Debian 中国大陆 IP 端口过滤

适用于 Debian 12 / 13（systemd）。使用 nftables 丢弃来自 IPdeny 中国大陆 IPv4 / IPv6 网段、访问本机 TCP 或 UDP `30000–60000` 的流量。其他端口继续由现有防火墙管理。Docker 常规端口映射按宿主机端口匹配。

## 一键安装

在服务器上执行。需要 `curl` 和 root 权限，已是 root 时可去掉 `sudo`。

```bash
curl -fsSLo geo-cn-install.sh https://raw.githubusercontent.com/brian952700/debian-geo-cn-firewall/main/install.sh && sudo bash geo-cn-install.sh
```

默认匹配所有非回环网卡上发往本机地址的连接。只限制指定入站网卡时，给脚本传网卡名，例如 `sudo bash geo-cn-install.sh ens3`。

如果 SSH 端口也在该范围内，且你从中国大陆地址连接，请通过云厂商控制台安装。

## 更新与检查

重新运行安装命令会下载最新网段并替换规则。安装后会开机加载。用 `sudo nft list chain inet geo_cn incoming` 查看丢包计数。如果现有防火墙重载时清空了整个 nftables 规则集，运行 `sudo systemctl start geo-cn.service` 恢复本规则。

## 卸载

```bash
sudo systemctl disable --now geo-cn.service
sudo nft delete table inet geo_cn
sudo rm -f /etc/geo-cn.nft /etc/systemd/system/geo-cn.service
sudo systemctl daemon-reload
```

网段来源为 [IPdeny](https://www.ipdeny.com/ipblocks/)。过滤按服务器看到的源 IP 判断，经过代理或 CDN 的连接会匹配代理或 CDN 的地址。
