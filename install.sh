#!/bin/bash
# =============================================================
#  iptv-gateway 原生安装脚本（飞牛 fnOS / 通用 Linux，免 Docker）
#
#  两种安装方式：
#    A. 离线包安装（本脚本与 iptv-gateway-linux-amd64 在同一目录）：
#         sudo bash install.sh
#    B. 在线一键安装（从 GitHub Releases 自动下载，支持管道执行）：
#         curl -fsSL <install.sh 的 raw 地址> | sudo bash
#       在线模式可用环境变量：
#         --version x.y.z          安装指定版本（默认最新）
#         GH_REPO=<owner>/<repo>   发布仓库（默认脚本内置值）
#         GH_PROXY=<url>           GitHub 下载加速前缀，如 https://ghfast.top/
#         GH_TOKEN=<token>         私有仓库访问令牌
#
#  子命令：
#    install（默认） / upgrade / status / uninstall [--purge]
#    管道方式执行子命令：curl -fsSL <raw 地址> | sudo bash -s -- uninstall --purge
#
#  安装位置：
#    /usr/local/bin/iptv-gateway            二进制
#    /etc/iptv-gateway/                     配置 + m3u 播放列表（升级/卸载保留）
#    /var/lib/iptv-gateway/data/            频道库 / EPG 缓存 / 界面设置
#    /etc/systemd/system/iptv-gateway.service
# =============================================================
set -uo pipefail

# 在线安装的发布仓库
GH_REPO="${GH_REPO:-wzy80119-cell/iptv-gateway}"
ASSET_NAME="iptv-gateway-linux-native.zip"   # release 里不带版本号的资产名（latest 永链用）

SRC="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
BIN_SRC="$SRC/iptv-gateway-linux-amd64"
CONF_SRC="$SRC/config/iptv-gateway.conf"
M3U_SRC="$SRC/config/m3u"
BIN_DST=/usr/local/bin/iptv-gateway
ETC=/etc/iptv-gateway
DATA=/var/lib/iptv-gateway/data
UNIT=/etc/systemd/system/iptv-gateway.service
PORT=10010
HEALTH_URL="http://127.0.0.1:${PORT}/healthz"
PREFIX=/app/iptv-gateway
ONLINE_TMP=""

say()  { echo -e "$*"; }
die()  { echo -e "\033[31m[错误]\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[36m[信息]\033[0m $*"; }
warn() { echo -e "\033[33m[警告]\033[0m $*"; }

# ---------- 参数解析：子命令 + 可选 --version / --purge ----------
CMD="install"
VER_OPT=""
PURGE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)   VER_OPT="${2:-}"; shift 2 ;;
        --version=*) VER_OPT="${1#*=}"; shift ;;
        --purge)     PURGE=1; shift ;;
        -*)          shift ;;
        *)           CMD="$1"; shift ;;
    esac
done

[[ $EUID -eq 0 ]] || die "请用 root 运行：sudo bash $0（或 curl ... | sudo bash）"
command -v systemctl >/dev/null || die "未找到 systemctl（本脚本面向 systemd 系统）"

# ---------- 在线模式：从 GitHub Releases 下载离线包 ----------
fetch_online() {
    command -v curl >/dev/null || die "在线安装需要 curl"
    command -v unzip >/dev/null || die "在线安装需要 unzip"
    [[ "$(uname -m)" == "x86_64" ]] || die "在线包仅提供 linux/amd64（当前架构 $(uname -m)）"

    local base="${GH_PROXY}https://github.com/${GH_REPO}/releases"
    local url
    if [[ -n "$VER_OPT" ]]; then
        url="${base}/download/v${VER_OPT}/${ASSET_NAME}"
    else
        url="${base}/latest/download/${ASSET_NAME}"
    fi

    ONLINE_TMP="$(mktemp -d /tmp/iptv-install.XXXXXX)"
    local hdr=()
    [[ -n "${GH_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer ${GH_TOKEN}")
    info "在线安装：下载 $url"
    if ! curl -fL --retry 3 --connect-timeout 15 ${hdr[@]+"${hdr[@]}"} \
            -o "$ONLINE_TMP/pkg.zip" "$url"; then
        die "下载失败。可选：1) 加速前缀重试 curl ... | sudo GH_PROXY=https://ghfast.top/ bash；
2) 指定版本 --version x.y.z；3) 到 https://github.com/${GH_REPO}/releases 手动下载 zip 后离线安装"
    fi
    unzip -q "$ONLINE_TMP/pkg.zip" -d "$ONLINE_TMP/unpack"
    local dir
    dir="$(echo "$ONLINE_TMP"/unpack/iptv-gateway-*-linux-native)"
    [[ -d "$dir" ]] || die "压缩包结构异常（未找到 iptv-gateway-*-linux-native 目录）"
    SRC="$dir"
    BIN_SRC="$SRC/iptv-gateway-linux-amd64"
    CONF_SRC="$SRC/config/iptv-gateway.conf"
    M3U_SRC="$SRC/config/m3u"
    info "已获取发布包：$(basename "$dir")"
}

cleanup_online() {
    [[ -n "$ONLINE_TMP" && -d "$ONLINE_TMP" ]] && rm -rf "$ONLINE_TMP"
}
trap cleanup_online EXIT

write_unit() {
    cat > "$UNIT" <<EOF
[Unit]
Description=iptv-gateway (IPTV 内外网融合网关)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_DST} -c ${ETC}/iptv-gateway.conf
Restart=always
RestartSec=3
TimeoutStopSec=20
MemoryMax=256M
Environment=TZ=Asia/Shanghai
LimitNOFILE=65536
SyslogIdentifier=iptv-gateway

[Install]
WantedBy=multi-user.target
EOF
}

# 把默认配置落到 /etc（已存在则不动），data-dir 改写为原生路径
install_conf() {
    mkdir -p "$ETC/m3u" "$DATA"
    if [[ -f "$CONF_SRC" && ! -f "$ETC/iptv-gateway.conf" ]]; then
        sed -e "s|^data-dir *=.*|data-dir = $DATA|" "$CONF_SRC" > "$ETC/iptv-gateway.conf"
        info "已生成 $ETC/iptv-gateway.conf"
    fi
    # 播放列表：只补缺失文件，不覆盖已有（用户的列表编辑都保存在这里）
    if [[ -d "$M3U_SRC" ]]; then
        for f in "$M3U_SRC"/*.m3u; do
            [[ -e "$f" ]] || continue
            dst="$ETC/m3u/$(basename "$f")"
            [[ -f "$dst" ]] || cp "$f" "$dst"
        done
    fi
}

check_port_busy() {
    command -v ss >/dev/null || return 0
    local pid_info
    pid_info=$(ss -tlnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {print $NF}')
    [[ -n "$pid_info" ]] || return 0
    # 旧版 iptv-gateway 自己占着端口：覆盖安装/升级属正常，重启即可
    if echo "$pid_info" | grep -q "iptv-gateway"; then
        return 0
    fi
    warn "端口 $PORT 已被占用：$pid_info"
    if echo "$pid_info" | grep -q docker; then
        warn "检测到 Docker 容器占用（多半是旧版 iptv-gateway 容器仍在运行）。"
        warn "两套服务不能同时抢 IPTV 网卡与端口，请先停掉容器："
        warn "    cd /vol1/docker/iptv-gateway && docker compose down   # 或 docker stop iptv-gateway"
        die "停掉占用端口的服务后重新执行本脚本。"
    fi
    die "先释放端口 $PORT 再安装。"
}

wait_healthy() {
    for i in $(seq 1 15); do
        if curl -sf -m 2 "$HEALTH_URL" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

print_status() {
    local ver
    ver=$("$BIN_DST" -version 2>/dev/null || echo 未知)
    say ""
    say "============== iptv-gateway 状态 =============="
    say "版本      : $ver"
    say "systemd   : $(systemctl is-active iptv-gateway 2>&1) / 开机自启 $(systemctl is-enabled iptv-gateway 2>&1)"
    if curl -sf -m 3 "$HEALTH_URL" >/dev/null 2>&1; then
        say "健康检查  : $HEALTH_URL ✓"
        local lan
        for lan in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -3); do
            say "管理界面  : http://${lan}:${PORT}${PREFIX}/"
            say "订阅地址  : http://${lan}:${PORT}${PREFIX}/playlist.m3u"
        done
        local ch
        ch=$(curl -sf -m 3 "http://127.0.0.1:${PORT}${PREFIX}/status.json" 2>/dev/null | grep -o '"channels":[0-9]*' | head -1 | cut -d: -f2)
        [[ -n "${ch:-}" ]] && say "频道数    : $ch"
    else
        say "健康检查  : 未通过（服务未监听 $PORT）"
        say "看日志    : journalctl -u iptv-gateway -n 50 --no-pager"
    fi
    say "================================================"
}

resolve_package() {
    # 本地目录没有二进制（管道执行 / 只传了脚本）→ 在线下载
    if [[ ! -f "$BIN_SRC" ]]; then
        fetch_online
    fi
    [[ -f "$BIN_SRC" ]] || die "缺少 $BIN_SRC（安装包不完整）"
}

do_install() {
    resolve_package
    chmod +x "$BIN_SRC"
    info "二进制自检..."
    if ! "$BIN_SRC" -version; then
        die "二进制无法执行：架构不匹配或文件损坏（应为 linux/amd64 静态二进制）"
    fi
    check_port_busy
    info "安装二进制 -> $BIN_DST"
    install -m 0755 "$BIN_SRC" "$BIN_DST"
    info "部署配置与播放列表 -> $ETC"
    install_conf
    info "写入 systemd 服务"
    write_unit
    systemctl daemon-reload
    systemctl enable iptv-gateway >/dev/null 2>&1
    info "启动服务..."
    systemctl restart iptv-gateway
    if wait_healthy; then
        info "服务已就绪"
        print_status
    else
        warn "服务启动后 15 秒内健康检查未通过，最近日志："
        journalctl -u iptv-gateway -n 20 --no-pager || true
        die "请检查上方日志（常见原因：配置里 upstream-interface 网卡名不对、端口被占）"
    fi
}

do_upgrade() {
    resolve_package
    chmod +x "$BIN_SRC"
    info "旧版本: $("$BIN_DST" -version 2>/dev/null || echo 未安装)"
    install -m 0755 "$BIN_SRC" "$BIN_DST"
    systemctl restart iptv-gateway
    if wait_healthy; then
        info "升级完成"
        print_status
        info "升级后请重建频道库顺序：curl -s -X POST http://127.0.0.1:${PORT}${PREFIX}/api/channels/import"
    else
        journalctl -u iptv-gateway -n 20 --no-pager || true
        die "升级后健康检查失败"
    fi
}

do_uninstall() {
    systemctl disable --now iptv-gateway >/dev/null 2>&1 || true
    rm -f "$UNIT" "$BIN_DST"
    systemctl daemon-reload
    if [[ $PURGE -eq 1 ]]; then
        rm -rf "$ETC" /var/lib/iptv-gateway
        info "已删除程序、配置（$ETC）与数据（/var/lib/iptv-gateway）"
    else
        info "已卸载程序；配置 $ETC 与数据 /var/lib/iptv-gateway 已保留"
        info "彻底删除请执行：sudo bash install.sh uninstall --purge（在线方式：curl ... | sudo bash -s -- uninstall --purge）"
    fi
}

case "$CMD" in
    install)   do_install ;;
    upgrade)   do_upgrade ;;
    status)    print_status ;;
    uninstall) do_uninstall ;;
    *) die "未知子命令：$CMD（可用：install / upgrade / status / uninstall [--purge]）" ;;
esac
