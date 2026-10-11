# iptv-gateway — IPTV 融合网关

组播 RTP / RTSP → HTTP-TS 转换网关，带 Web 管理界面与 EPG（XMLTV）。
适配**山西联通 IPTV**（中兴/华为平台，单播 RTSP + 组播 RTP 双路源）。

纯 Go 静态二进制，无任何运行时依赖；同一份程序支持三种部署方式：

| 部署方式 | 适用 | 说明 |
| --- | --- | --- |
| **在线一键安装**（推荐） | 飞牛 fnOS / 任意 systemd Linux (amd64) | 一条命令，自动装二进制 + 配置 + systemd 服务 |
| 离线包安装 | 同上（无外网/离线环境） | [Releases](https://github.com/wzy80119-cell/iptv-gateway/releases) 下载 zip，解压执行 |
| Docker Compose | 任意有 Docker 的主机 | 见项目源码仓库 `docker-compose.yaml` |

## 在线一键安装

SSH 进入 NAS / 服务器，执行：

```bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/wzy80119-cell/iptv-gateway/main/install.sh | sudo bash
```

前缀 `https://gh-proxy.com/` 是给 `raw.githubusercontent.com` 加速的（国内直连普遍被 DNS
污染，实测本机直连超时）。Release 资产的下载加速已内置在脚本里，默认顺序
`gh-proxy.com → ghfast.top → GitHub 直连`，失败自动换源，无需额外配置。

能直连 GitHub 的主机可以去掉前缀，并用 `GH_PROXY=` 关闭资产加速：

```bash
curl -fsSL https://raw.githubusercontent.com/wzy80119-cell/iptv-gateway/main/install.sh | sudo bash -s -- upgrade
```

安装脚本会自动：

- 从本仓库 Releases 下载最新版 `iptv-gateway-linux-native.zip`
- 安装二进制到 `/usr/local/bin/iptv-gateway`
- 部署配置到 `/etc/iptv-gateway/`（`iptv-gateway.conf` + `m3u/` 播放列表）
- 数据目录 `/var/lib/iptv-gateway/data/`（频道库 / EPG 缓存 / 界面设置）
- 注册 systemd 服务（开机自启，崩溃自动拉起）
- 健康检查通过后打印管理界面与订阅地址

### 可选参数

```bash
# 安装指定版本
curl -fsSL .../install.sh | sudo bash -s -- --version 1.2.27

# 子命令：状态 / 升级 / 卸载（支持管道方式）
curl -fsSL .../install.sh | sudo bash -s -- status
curl -fsSL .../install.sh | sudo bash -s -- upgrade
curl -fsSL .../install.sh | sudo bash -s -- uninstall          # 保留配置与数据
curl -fsSL .../install.sh | sudo bash -s -- uninstall --purge  # 全部删除

# 环境变量
GH_PROXY=https://ghfast.top/   # 换其它 GitHub 加速前缀（默认 gh-proxy.com，设为空则直连）
GH_REPO=owner/repo             # 换发布仓库
GH_TOKEN=xxx                   # 私有仓库访问令牌
```

## 离线安装

到 [Releases](https://github.com/wzy80119-cell/iptv-gateway/releases) 下载
`iptv-gateway-linux-native.zip`（或带版本号的 `iptv-gateway-vX.Y.Z-linux-native.zip`），
上传到 NAS 后：

```bash
unzip iptv-gateway-linux-native.zip -d /tmp/
cd /tmp/iptv-gateway-v*-linux-native
sudo bash install.sh
```

## 先决条件

- **IPTV 内网网卡**：光猫 IPTV LAN 口桥接到独立网卡（脚本默认 `enp9s0`，
  装好后在 `/etc/iptv-gateway/iptv-gateway.conf` 里改 `upstream-interface`）
- 双网卡机器需关闭反向路径校验：
  ```bash
  sysctl -w net.ipv4.conf.all.rp_filter=0
  sysctl -w net.ipv4.conf.enp9s0.rp_filter=0
  ```
- 端口 `10010` 未被占用（旧 Docker 版在跑请先 `docker stop iptv-gateway`）

## 日常操作

```bash
curl -fsSL .../install.sh | sudo bash -s -- status   # 版本/频道数/订阅地址
journalctl -u iptv-gateway -f                        # 日志
systemctl restart iptv-gateway                       # 重启
```

- 管理界面：`http://<NAS-IP>:10010/app/iptv-gateway/`
- 订阅地址：`http://<NAS-IP>:10010/app/iptv-gateway/playlist.m3u`
- 配置：`/etc/iptv-gateway/iptv-gateway.conf`
- 播放列表：`/etc/iptv-gateway/m3u/`（改完在 Web 界面点「从播放列表重新导入」）

## 飞牛 fnOS FPK 版

另有按 fnOS FPK 规范打包的安装包（个人自用，不上架应用中心）：
`iptv-gateway-vX.Y.Z-fnos-x86.fpk`，在 fnOS「应用中心 → 手动安装」使用。
详见项目源码仓库 `tools/fpk/`。

## 从源码构建

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o iptv-gateway-linux-amd64 .
```

纯标准库实现，`go build` 即可，无第三方依赖。
