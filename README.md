# iptv-gateway — IPTV 融合网关

组播 RTP / RTSP → HTTP-TS 转换网关，带 Web 管理界面与 EPG（XMLTV）。
适配**山西联通 IPTV**（中兴/华为平台，单播 RTSP + 组播 RTP 双路源）。

纯 Go 静态二进制（`CGO_ENABLED=0`），无任何运行时依赖，不需要 Docker。
同一份程序与同一个 `install.sh` 覆盖 x86_64、arm64、armv7 三种架构，
以及 systemd 与 OpenWrt/iStoreOS 的 procd 两种 init 系统 —— 装的时候自动判定。

| 部署方式 | 适用 | 说明 |
| --- | --- | --- |
| **在线一键安装**（推荐） | 飞牛 fnOS / 任意 Linux（amd64、arm64、armv7） | 一条命令，自动选架构 + 选服务方式 |
| 离线包安装 | 同上，无外网 / DNS 被污染的路由器 | Releases 下载对应架构包，解压执行 `bash install.sh` |
| Docker Compose | 任意有 Docker 的主机 | 见项目源码仓库 `docker-compose.yaml` |

## 在线一键安装

SSH 进入 NAS / 服务器 / 路由器，执行：

```bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/wzy80119-cell/iptv-gateway/main/install.sh | sudo bash
```

- 前缀 `https://gh-proxy.com/` 是给 `raw.githubusercontent.com` 加速的（国内直连普遍被 DNS
  污染，实测超时）。Release 资产的下载加速已内置在脚本里，默认顺序
  `gh-proxy.com → ghfast.top → GitHub 直连`，失败自动换源。
- 路由器上通常已经是 root，`sudo` 可省；但脚本需要 **bash**（不是 sh）：
  iStoreOS 自带 bash，纯 BusyBox 的 OpenWrt 先 `opkg install bash`。
- 能直连 GitHub 的主机可以去掉前缀，并用 `GH_PROXY=` 关闭资产加速：

```bash
curl -fsSL https://raw.githubusercontent.com/wzy80119-cell/iptv-gateway/main/install.sh | sudo bash -s -- upgrade
```

脚本自动完成的事：

- 按 `uname -m` 选架构资产：x86_64 → `iptv-gateway-linux-native.zip`，
  aarch64/arm64 → `iptv-gateway-linux-arm64.tar.gz`，armv7 → `iptv-gateway-linux-armv7.tar.gz`
- 按 `/etc/openwrt_release`、`/proc/1/comm` 选服务方式：systemd unit 或 `/etc/init.d/iptv-gateway`（procd）
- 安装二进制到 `/usr/local/bin/iptv-gateway`，配置到 `/etc/iptv-gateway/`
  （`iptv-gateway.conf` + `m3u/` 播放列表），数据到 `/var/lib/iptv-gateway/data/`
- 清理配置里指向已消失网卡的 `upstream-interface*` 残留值
- 注册服务（开机自启、崩溃自动拉起），健康检查通过后打印管理界面与订阅地址

### 可选参数

```bash
# 安装指定版本
curl -fsSL .../install.sh | sudo bash -s -- --version 1.2.29

# 子命令：状态 / 升级 / 卸载（支持管道方式）
curl -fsSL .../install.sh | sudo bash -s -- status
curl -fsSL .../install.sh | sudo bash -s -- upgrade
curl -fsSL .../install.sh | sudo bash -s -- uninstall          # 保留配置与数据
curl -fsSL .../install.sh | sudo bash -s -- uninstall --purge  # 全部删除

# 环境变量
IPTV_NIC=eth1                # 直接把 IPTV 内网网卡指定为该网卡（各设备网卡名不一）
GH_PROXY=https://ghfast.top/ # 换其它 GitHub 加速前缀（默认 gh-proxy.com，设为空则直连）
GH_REPO=owner/repo           # 换发布仓库
GH_TOKEN=xxx                 # 私有仓库访问令牌
```

## 离线安装

到 [Releases](https://github.com/wzy80119-cell/iptv-gateway/releases) 下载本机架构对应的包
（ARM 是 tar.gz，因为 OpenWrt/iStoreOS 上没有 unzip）：

```bash
# x86_64
unzip iptv-gateway-linux-native.zip -d /tmp/
cd /tmp/iptv-gateway-v*-linux-native && sudo bash install.sh

# arm64 / armv7（软路由、OpenWrt、iStoreOS）
tar xzf iptv-gateway-linux-armv7.tar.gz -C /tmp/
cd /tmp/iptv-gateway-v*-linux-armv7 && bash install.sh
```

包内 `README-NATIVE.txt` 是按本架构生成的说明。

## 管理与订阅地址

**都是「服务器 IP + 10010 端口」直接进**，不需要子路径：

- 管理界面：`http://<设备地址>:10010/`
- 订阅列表：`http://<设备地址>:10010/playlist.m3u`（EPG 地址自动指向本机）
- 状态：`http://<设备地址>:10010/status.json`

早期版本的 `/app/iptv-gateway/` 前缀入口仍然等价可用（同一进程、同一份数据，
配置项 `app_path_prefix` 可改）；页面里的链接按请求实际前缀生成，两个入口不会互相打架。
其它未知前缀（如旧 rtp2httpd 的 `/app/rtp2httpd/`）一律 404，避免新旧网关串路。

## 出口网卡自动识别

换设备、换网卡名（`eth1` / `br-IPTV` / `enp9s0` / `ppp0`…）都不用改配置：
服务启动后拿播放列表里的真实上游地址（RTSP 单播组、组播组）逐个网卡做连通性实测，
自动把可达的网卡写进 `upstream-interface*`。结果三处可核对：

- `status.json` 的 `upstream_interfaces`
- Web 界面「参数配置 → 上游网卡」
- `bash install.sh status` 的「出口网卡」行

手动指定过且该网卡仍存在时，一律以手动值为准，不会被自动识别覆盖。

## 先决条件

- 设备在 IPTV 专网/VLAN 内：光猫 IPTV LAN 口桥接到独立网卡并拿到运营商内网地址。
  只有宽带侧地址（如 10.72.x）的机器会自动识别不到出口，也就取不到直播源
  ——这是网络可达性问题，与安装无关。
- 双网卡机器需关闭反向路径校验（网卡名按实际替换）：
  ```bash
  sysctl -w net.ipv4.conf.all.rp_filter=0
  sysctl -w net.ipv4.conf.<IPTV网卡>.rp_filter=0
  ```
- OpenWrt / iStoreOS / ImmortalWrt / HWRT 一类路由器还要**放开防火墙**：系统默认把 IPTV 口归到
  `input REJECT` 的 `wan` zone，于是信令发得出去、流媒体进不来——表现为「新建流 → 6 秒
  （组播 1.5 秒）内无数据」、所有频道 502。给 IPTV 口单独建一个 `input ACCEPT` 的 zone 即可
  （实测：只改防火墙、不动二进制，立刻出流，3 路 RTSP 与 1 路组播各 15 秒 15–16.6MB）。
  ```bash
  grep -A6 "config zone" /etc/config/firewall   # 看 IPTV 口落在哪个 zone
  iptables -S | grep -E 'zone_.*_input'          # 该 zone 的 input 是不是 REJECT
  ```
- 端口 `10010` 未被占用（旧 Docker 版在跑请先 `docker stop iptv-gateway`；
  旧 rtp2httpd 用 7000，可并存对比）

## 日常操作

```bash
bash install.sh status      # 版本/频道数/订阅地址/出口网卡

journalctl -u iptv-gateway -f        # systemd 日志
systemctl restart iptv-gateway       # systemd 重启

logread -e iptv-gateway              # OpenWrt/iStoreOS 日志
/etc/init.d/iptv-gateway restart     # OpenWrt/iStoreOS 重启
```

- 配置：`/etc/iptv-gateway/iptv-gateway.conf`
- 播放列表：`/etc/iptv-gateway/m3u/`（改完在 Web 界面点「从播放列表重新导入」）
- 数据：`/var/lib/iptv-gateway/data/`（升级与卸载默认保留）

## 飞牛 fnOS FPK 版

另有按 fnOS FPK 规范打包的安装包（个人自用，不上架应用中心）：
`iptv-gateway-vX.Y.Z-fnos-x86.fpk`，在 fnOS「应用中心 → 手动安装」使用。
详见项目源码仓库 `tools/fpk/`。

## 从源码构建

```bash
# x86_64
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -tags netgo,timetzdata -ldflags "-s -w -X main.Version=1.2.29" -o iptv-gateway-linux-amd64 .
# arm64
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -tags netgo,timetzdata -ldflags "-s -w -X main.Version=1.2.29" -o iptv-gateway-linux-arm64 .
# armv7（32 位，OpenWrt/iStoreOS 旧路由器）
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -tags netgo,timetzdata -ldflags "-s -w -X main.Version=1.2.29" -o iptv-gateway-linux-armv7 .
```

纯标准库实现，`go build` 即可，无第三方依赖。
32 位 ARM 上 64 位原子操作要求 8 字节对齐，代码里相关计数器统一用 `atomic.Int64/Uint64`
类型而不是裸 `int64`，改这块时别退回去，否则 armv7 会在导入频道时直接 panic。
