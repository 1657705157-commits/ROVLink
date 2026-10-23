#!/bin/sh
#
# ============================================================
#  一键部署：图传 + MAVLink UDP 中继
#  在目标开发板上执行（需 root）
# ============================================================
#
# 用法:
#   chmod +x install.sh
#   ./install.sh              # 安装并启动
#   ./install.sh --no-start   # 只安装，不启动
#

set -e

DEPLOY_DIR=$(cd "$(dirname "$0")" && pwd)
WZ_DIR=/wz
INITD=/etc/init.d
START_SERVICES=1

[ "$1" = "--no-start" ] && START_SERVICES=0

info()  { printf '\033[32m[OK]\033[0m %s\n' "$1"; }
warn()  { printf '\033[33m[!!]\033[0m %s\n' "$1"; }
error() { printf '\033[31m[ER]\033[0m %s\n' "$1"; }

echo "============================================================"
echo "  图传 + MAVLink 中继部署"
echo "  源目录: $DEPLOY_DIR"
echo "============================================================"
echo

# ---------- 1. 检查依赖 ----------
echo "[1/5] 检查依赖 ..."

MISSING=""

if command -v ffmpeg >/dev/null 2>&1; then
    info "ffmpeg: $(ffmpeg -version 2>/dev/null | head -1)"
else
    error "ffmpeg 未安装"
    MISSING="$MISSING ffmpeg"
fi

if command -v socat >/dev/null 2>&1; then
    info "socat:  $(socat -V 2>&1 | head -1)"
else
    error "socat 未安装"
    MISSING="$MISSING socat"
fi

if command -v v4l2-ctl >/dev/null 2>&1; then
    info "v4l2-ctl: 已安装"
else
    warn "v4l2-ctl 未安装（可选，用于查询摄像头格式）"
fi

if [ -n "$MISSING" ]; then
    echo
    error "缺少依赖:$MISSING"
    echo "  请先安装，例如（Debian/Ubuntu）:"
    echo "    apt install ffmpeg socat v4l2-utils"
    echo "  或（Buildroot）: 在内核/固件配置里勾选对应包"
    exit 1
fi

echo

# ---------- 2. 准备目录 ----------
echo "[2/5] 准备目录 ..."
mkdir -p "$WZ_DIR"
info "$WZ_DIR 就绪"
echo

# ---------- 3. 复制脚本 ----------
echo "[3/5] 复制文件 ..."

if [ -f "$DEPLOY_DIR/video/video_stream_single.sh" ]; then
    cp "$DEPLOY_DIR/video/video_stream_single.sh" "$WZ_DIR/"
    chmod 755 "$WZ_DIR/video_stream_single.sh"
    info "video_stream_single.sh -> $WZ_DIR/"
fi

if [ -f "$DEPLOY_DIR/video/video_stream_dual.sh" ]; then
    cp "$DEPLOY_DIR/video/video_stream_dual.sh" "$WZ_DIR/"
    chmod 755 "$WZ_DIR/video_stream_dual.sh"
    info "video_stream_dual.sh -> $WZ_DIR/"
fi

if [ -f "$DEPLOY_DIR/video/S96wz-video" ]; then
    cp "$DEPLOY_DIR/video/S96wz-video" "$INITD/"
    chmod 755 "$INITD/S96wz-video"
    info "S96wz-video -> $INITD/"
fi

if [ -f "$DEPLOY_DIR/mavlink/S100_mavlink-bridge" ]; then
    cp "$DEPLOY_DIR/mavlink/S100_mavlink-bridge" "$INITD/"
    chmod 755 "$INITD/S100_mavlink-bridge"
    info "S100_mavlink-bridge -> $INITD/"
fi

echo

# ---------- 4. 检查 MediaMTX ----------
echo "[4/5] 检查 MediaMTX ..."

if [ -x "$WZ_DIR/mediamtx" ]; then
    info "$WZ_DIR/mediamtx 已就绪"
else
    warn "$WZ_DIR/mediamtx 不存在或不可执行"
    echo
    echo "  MediaMTX 是 63 MB 的独立二进制，需单独获取："
    echo "    从原板拷贝:  scp root@<原板IP>:$WZ_DIR/mediamtx $WZ_DIR/"
    echo "    或官网下载:  https://github.com/bluenviron/mediamtx/releases"
    echo
    echo "  放好后执行:  chmod +x $WZ_DIR/mediamtx"
    echo
    if [ "$START_SERVICES" = "1" ]; then
        warn "跳过图传启动（缺少 mediamtx）"
        START_SERVICES_VIDEO=0
    fi
fi

# 摄像头检查
echo
echo "  检测到的摄像头设备："
if ls /dev/video* >/dev/null 2>&1; then
    ls -l /dev/video* 2>/dev/null | sed 's/^/    /'
else
    warn "  未检测到 /dev/video*，请确认摄像头已连接"
fi

echo

# ---------- 5. 启动 ----------
echo "[5/5] 服务配置 ..."

if [ "$START_SERVICES" = "0" ]; then
    info "跳过启动（--no-start）"
else
    # MAVLink 中继
    if [ -f "$INITD/S100_mavlink-bridge" ]; then
        echo "  启动 MAVLink 中继 ..."
        "$INITD/S100_mavlink-bridge" restart || warn "MAVLink 中继启动失败（检查串口配置）"
    fi

    # 图传
    if [ "${START_SERVICES_VIDEO:-1}" = "1" ] && [ -x "$WZ_DIR/mediamtx" ]; then
        echo "  启动单路图传 ..."
        "$INITD/S96wz-video" restart || warn "图传启动失败（检查摄像头）"
    fi

    # 禁用工厂服务（如果存在）
    for S in S95wz-camera S51_rov_app; do
        if [ -f "$INITD/$S" ] && [ -x "$INITD/$S" ]; then
            chmod 644 "$INITD/$S"
            info "已禁用工厂服务 $S（防止抢摄像头/串口）"
        fi
    done
fi

echo
echo "============================================================"
echo "  部署完成"
echo "============================================================"
echo
echo "  查看状态："
echo "    $INITD/S100_mavlink-bridge status"
echo "    $INITD/S96wz-video status"
echo
echo "  浏览器访问（<IP> = 本机 IP）："
echo "    http://<IP>:8889/live/cam/     WebRTC（推荐）"
echo "    http://<IP>:8888/live/cam/index.m3u8   HLS"
echo
echo "  MAVLink 客户端连接："
echo "    udpout:<IP>:15001"
echo
echo "  详细说明见 README.md"
echo
