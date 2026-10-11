#!/bin/bash
# =============================================================
#  iptv-gateway 原生安装脚本（免 Docker）
#
#  自动适配两类系统：
#    - systemd Linux（飞牛 fnOS / Debian / Ubuntu / 通用 x86 服务器）
#    - OpenWrt / iStoreOS（procd，无 systemd）
#  按 uname -m 选资产：x86_64 -> linux-native.zip，armv7 -> linux-armv7.tar.gz
#
#  两种安装方式：
#    A. 离线包安装（本脚本与 iptv-gateway-linux-* 在同一目录）：
#         sudo bash install.sh
#    B. 在线一键安装（从 GitHub Releases 自动下载，支持管道执行）：
#         curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/<仓库>/main/install.sh | sudo bash
#       在线模式可用环境变量：
#         --version x.y.z          安装指定版本（默认最新）
#         GH_REPO=<owner>/<repo>   发布仓库（默认脚本内置值）
#         GH_PROXY=<url>           GitHub 下载加速前缀，默认 https://gh-proxy.com/
#                                  （设为空串 GH_PROXY= 则走 GitHub 直连）
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
#    systemd: /etc/systemd/system/iptv-gateway.service
#    procd  : /etc/init.d/iptv-gateway（+ /etc/rc.d 自启链接）
# =============================================================
set -uo pipefail

# 在线安装的发布仓库
GH_REPO="${GH_REPO:-wzy80119-cell/iptv-gateway}"
# 国内直连 github.com / raw.githubusercontent.com 基本被 DNS 污染，默认走加速前缀；
# 用 ${VAR-} 而非 ${VAR:-}，好让 GH_PROXY= 能显式关掉前缀走直连。
GH_PROXY="${GH_PROXY-https://gh-proxy.com/}"

SRC="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
BIN_SRC=""
CONF_SRC="$SRC/config/iptv-gateway.conf"
M3U_SRC="$SRC/config/m3u"
BIN_DST=/usr/local/bin/iptv-gateway
ETC=/etc/iptv-gateway
DATA=/var/lib/iptv-gateway/data
UNIT=/etc/systemd/system/iptv-gateway.service
INITD=/etc/init.d/iptv-gateway
PORT=10010
HEALTH_URL="http://127.0.0.1:${PORT}/healthz"
PREFIX=/app/iptv-gateway
ONLINE_TMP=""
ARCH_TAG=""
PKG_FMT=""
ASSET_NAME=""
INIT=""

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

# ---------- 环境探测：架构（决定下哪个包）+ init 系统（决定写哪种服务）----------
detect_env() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64)
            ARCH_TAG=amd64; PKG_FMT=zip
            ASSET_NAME="iptv-gateway-linux-native.zip" ;;
        armv7l|armv7hl|armhf)
            ARCH_TAG=armv7; PKG_FMT=tar.gz
            ASSET_NAME="iptv-gateway-linux-armv7.tar.gz" ;;
        armv6l)
            die "ARMv6 未提供对应二进制（armv7 包需要 vfpv3 指令集），请用 x86_64 或 armv7 机型" ;;
        *)  die "不支持的架构 $m（当前提供 linux/amd64 与 linux/armv7）" ;;
    esac

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        INIT=systemd
    elif [[ -x /sbin/procd ]] || [[ -f /etc/rc.common ]]; then
        INIT=procd
    else
        die "未识别的 init 系统：需要 systemd，或 OpenWrt/iStoreOS 的 procd（/etc/rc.common）"
    fi
    info "目标环境：架构 linux/$ARCH_TAG，init $INIT"
}

# 本地离线包里的二进制名（amd64 与 armv7 包只差后缀）
find_local_bin() {
    local f
    for f in "$SRC"/iptv-gateway-linux-*; do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}

# ---------- 在线模式：从 GitHub Releases 下载对应架构的发布包 ----------
fetch_online() {
    command -v curl >/dev/null || die "在线安装需要 curl"

    local sub
    if [[ -n "$VER_OPT" ]]; then
        sub="download/v${VER_OPT}/${ASSET_NAME}"
    else
        sub="latest/download/${ASSET_NAME}"
    fi
    # 候选源：默认加速前缀 -> 备用加速前缀 -> GitHub 直连，逐个尝试
    # （GH_PROXY= 显式为空表示只要直连，不再绕加速）
    local -a prefixes=()
    if [[ -n "$GH_PROXY" ]]; then
        prefixes+=("$GH_PROXY")
        local alt="https://ghfast.top/"
        [[ "$GH_PROXY" == "$alt" ]] || prefixes+=("$alt")
        prefixes+=("")
    else
        prefixes+=("")
    fi

    ONLINE_TMP="$(mktemp -d /tmp/iptv-install.XXXXXX)"
    local hdr=()
    [[ -n "${GH_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer ${GH_TOKEN}")
    local p url got=0
    for p in "${prefixes[@]}"; do
        url="${p}https://github.com/${GH_REPO}/releases/${sub}"
        info "在线安装：下载 $url"
        if curl -fL --retry 2 --connect-timeout 15 -o "$ONLINE_TMP/pkg" "$url"; then
            got=1; break
        fi
        warn "下载失败，换下一个源重试"
    done
    if [[ $got -ne 1 ]]; then
        die "下载失败。可选：1) 换加速前缀 curl ... | sudo GH_PROXY=https://ghfast.top/ bash（GH_PROXY= 为直连）；
2) 指定版本 --version x.y.z；3) 到 https://github.com/${GH_REPO}/releases 手动下载 ${ASSET_NAME} 后离线安装"
    fi

    mkdir -p "$ONLINE_TMP/unpack"
    if [[ "$PKG_FMT" == "zip" ]]; then
        command -v unzip >/dev/null || die "解压 zip 需要 unzip（或改用 tar.gz 包）"
        unzip -q "$ONLINE_TMP/pkg" -d "$ONLINE_TMP/unpack"
    else
        command -v tar >/dev/null || die "解压 tar.gz 需要 tar"
        tar xzf "$ONLINE_TMP/pkg" -C "$ONLINE_TMP/unpack"
    fi
    local dir
    dir="$(find "$ONLINE_TMP/unpack" -maxdepth 1 -type d -name 'iptv-gateway-*' | head -1)"
    [[ -n "$dir" ]] || die "压缩包结构异常（未找到 iptv-gateway-* 顶层目录）"
    SRC="$dir"
    info "已获取发布包：$(basename "$dir")"
}

cleanup_online() {
    [[ -n "$ONLINE_TMP" && -d "$ONLINE_TMP" ]] && rm -rf "$ONLINE_TMP"
}
trap cleanup_online EXIT

# ---------- 服务定义 ----------
write_systemd_unit() {
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

write_procd_initd() {
    # OpenWrt/iStoreOS：procd 拉起，stdout/stderr 转 syslog（logread 可看）
    cat > "$INITD" <<EOF
#!/bin/sh /etc/rc.common
# iptv-gateway —— 由 install.sh 生成，勿手工编辑（重装/升级会覆盖）
START=99
STOP=10
USE_PROCD=1

PROG=${BIN_DST}
CONF=${ETC}/iptv-gateway.conf

start_service() {
    procd_open_instance iptv-gateway
    procd_set_param command "\$PROG" -c "\$CONF"
    procd_set_param respawn 3600 5 5
    procd_set_param limits nofile="65536 65536"
    procd_set_param env TZ=Asia/Shanghai
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    chmod 0755 "$INITD"
}

write_service() {
    case "$INIT" in
        systemd) info "写入 systemd 服务"; write_systemd_unit ;;
        procd)   info "写入 procd 服务脚本"; write_procd_initd ;;
    esac
}

svc_enable_start() {
    case "$INIT" in
        systemd) systemctl daemon-reload
                 systemctl enable iptv-gateway >/dev/null 2>&1
                 systemctl restart iptv-gateway ;;
        procd)   "$INITD" enable >/dev/null 2>&1 || true
                 "$INITD" restart ;;
    esac
}

svc_restart() {
    case "$INIT" in
        systemd) systemctl restart iptv-gateway ;;
        procd)   "$INITD" restart ;;
    esac
}

svc_disable_now() {
    case "$INIT" in
        systemd) systemctl disable --now iptv-gateway >/dev/null 2>&1 || true ;;
        procd)   "$INITD" stop >/dev/null 2>&1 || true
                 "$INITD" disable >/dev/null 2>&1 || true ;;
    esac
}

svc_active() {
    case "$INIT" in
        systemd) systemctl is-active iptv-gateway 2>&1 ;;
        procd)   pgrep -x iptv-gateway >/dev/null 2>&1 && echo running || echo stopped ;;
    esac
}

svc_enabled() {
    case "$INIT" in
        systemd) systemctl is-enabled iptv-gateway 2>&1 ;;
        procd)   [[ -e /etc/rc.d/S99iptv-gateway ]] && echo enabled || echo disabled ;;
    esac
}

# 看日志的命令（失败时提示用）
log_hint() {
    case "$INIT" in
        systemd) echo "journalctl -u iptv-gateway -n 50 --no-pager" ;;
        procd)   echo "logread -e iptv-gateway | tail -50" ;;
    esac
}

tail_log() {
    case "$INIT" in
        systemd) journalctl -u iptv-gateway -n 20 --no-pager 2>/dev/null || true ;;
        procd)   logread -e iptv-gateway 2>/dev/null | tail -20 || true ;;
    esac
}

# busybox 上 install(1) 不一定有，退化成 cp + chmod
place_bin() {
    local src="$1" dst="$2"
    if command -v install >/dev/null 2>&1; then
        install -m 0755 "$src" "$dst"
    else
        mkdir -p "$(dirname "$dst")"
        cp -f "$src" "$dst" && chmod 0755 "$dst"
    fi
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
    local holder=""
    if command -v ss >/dev/null 2>&1; then
        holder=$(ss -tlnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {print $NF}')
    elif command -v netstat >/dev/null 2>&1; then
        # busybox netstat 的进程列是 "pid/name"
        holder=$(netstat -tlnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {print $NF, $(NF-1)}')
    else
        return 0
    fi
    [[ -n "$holder" ]] || return 0
    # 旧版 iptv-gateway 自己占着端口：覆盖安装/升级属正常，重启即可
    if echo "$holder" | grep -q "iptv-gateway"; then
        return 0
    fi
    warn "端口 $PORT 已被占用：$holder"
    if echo "$holder" | grep -q docker; then
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
    say "服务      : $(svc_active) / 开机自启 $(svc_enabled)（init: ${INIT:-未探测}）"
    if curl -sf -m 3 "$HEALTH_URL" >/dev/null 2>&1; then
        say "健康检查  : $HEALTH_URL ✓"
        local lan
        for lan in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -3); do
            say "管理界面  : http://${lan}:${PORT}${PREFIX}/"
            say "订阅地址  : http://${lan}:${PORT}${PREFIX}/playlist.m3u"
        done
        local pl ch
        pl=$(curl -sf -m 8 "http://127.0.0.1:${PORT}${PREFIX}/playlist.m3u" 2>/dev/null | grep -c '#EXTINF')
        [[ -n "${pl:-}" && "$pl" != "0" ]] && say "频道数    : $pl"
        ch=$(free -m 2>/dev/null | awk '/^Mem/ {print $7}')
        [[ -n "${ch:-}" ]] && say "可用内存  : ${ch} MB"
    else
        say "健康检查  : 未通过（服务未监听 $PORT）"
        say "看日志    : $(log_hint)"
    fi
    say "================================================"
}

resolve_package() {
    # 本地目录没有二进制（管道执行 / 只传了脚本）→ 在线下载
    BIN_SRC="$(find_local_bin || true)"
    [[ -n "$BIN_SRC" ]] || fetch_online
    BIN_SRC="${BIN_SRC:-$(find_local_bin || true)}"
    [[ -n "$BIN_SRC" && -f "$BIN_SRC" ]] || die "缺少 iptv-gateway-linux-* 二进制（安装包不完整）"
}

do_install() {
    resolve_package
    chmod +x "$BIN_SRC"
    info "二进制自检..."
    if ! "$BIN_SRC" -version; then
        die "二进制无法执行：架构不匹配或文件损坏（应为 linux/$ARCH_TAG 静态二进制）"
    fi
    check_port_busy
    info "安装二进制 -> $BIN_DST"
    place_bin "$BIN_SRC" "$BIN_DST"
    info "部署配置与播放列表 -> $ETC"
    install_conf
    write_service
    info "启动服务..."
    svc_enable_start
    if wait_healthy; then
        info "服务已就绪"
        print_status
    else
        warn "服务启动后 15 秒内健康检查未通过，最近日志："
        tail_log
        die "请检查上方日志（常见原因：配置里 upstream-interface 网卡名不对、端口被占）"
    fi
}

do_upgrade() {
    resolve_package
    chmod +x "$BIN_SRC"
    info "旧版本: $("$BIN_DST" -version 2>/dev/null || echo 未安装)"
    place_bin "$BIN_SRC" "$BIN_DST"
    write_service
    svc_restart
    if wait_healthy; then
        info "升级完成"
        print_status
        info "升级后请重建频道库顺序：curl -s -X POST http://127.0.0.1:${PORT}${PREFIX}/api/channels/import"
    else
        tail_log
        die "升级后健康检查失败"
    fi
}

do_uninstall() {
    svc_disable_now
    rm -f "$UNIT" "$INITD" "$BIN_DST"
    if [[ "$INIT" == "procd" ]]; then
        rm -f /etc/rc.d/S99iptv-gateway /etc/rc.d/K10iptv-gateway
    else
        systemctl daemon-reload
    fi
    if [[ $PURGE -eq 1 ]]; then
        rm -rf "$ETC" /var/lib/iptv-gateway
        info "已删除程序、配置（$ETC）与数据（/var/lib/iptv-gateway）"
    else
        info "已卸载程序；配置 $ETC 与数据 /var/lib/iptv-gateway 已保留"
        info "彻底删除请执行：sudo bash install.sh uninstall --purge（在线方式：curl ... | sudo bash -s -- uninstall --purge）"
    fi
}

case "$CMD" in
    install|upgrade|status|uninstall)
        detect_env
        case "$CMD" in
            install)   do_install ;;
            upgrade)   do_upgrade ;;
            status)    print_status ;;
            uninstall) do_uninstall ;;
        esac ;;
    *) die "未知子命令：$CMD（可用：install / upgrade / status / uninstall [--purge]）" ;;
esac
