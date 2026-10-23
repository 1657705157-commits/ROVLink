#!/bin/sh
#
# ============================================================
#  双路图传
#  两个摄像头 -> MediaMTX -> 局域网浏览器
# ============================================================
#
# 原理：每个摄像头各起一个 ffmpeg，原样（-c:v copy）推到本地 RTSP，
#       MediaMTX 转成 WebRTC / HLS 供浏览器观看。全程不转码。
#
# ⚠️ 硬件前提：两个摄像头必须接在**不同的 USB 控制器**上。
#    若都在同一个 USB 2.0 控制器下，第二路会报
#      ioctl(VIDIOC_STREAMON): No space left on device
#    那是 USB 等时带宽不足（与供电、磁盘无关），只能换 USB 口解决。
#    检查方法： ls -l /sys/class/video4linux/video*/device
#              路径里出现 /usb1/ 和 /usb2/ 才说明分属不同控制器
#
# 用法:
#   ./video_stream_dual.sh start|stop|restart|status
#
# 浏览器访问:
#   摄像头1  http://<IP>:8889/live/cam1/
#   摄像头2  http://<IP>:8889/live/cam2/
#
# 可选环境变量（每路独立）:
#   CAM1_DEV=/dev/video0  CAM1_SIZE=1920x1080  CAM1_FPS=30
#   CAM2_DEV=/dev/video2  CAM2_SIZE=1920x1080  CAM2_FPS=60
#

CAM1_DEV=${CAM1_DEV:-/dev/video0}
CAM1_SIZE=${CAM1_SIZE:-1920x1080}
CAM1_FPS=${CAM1_FPS:-30}

CAM2_DEV=${CAM2_DEV:-/dev/video2}
CAM2_SIZE=${CAM2_SIZE:-1920x1080}
CAM2_FPS=${CAM2_FPS:-60}

STREAM1=live/cam1
STREAM2=live/cam2

MTX_BIN=/wz/mediamtx
CONF=/tmp/mediamtx-dual.yml
PIDFILE=/var/run/video-dual.pid
LOGFILE=/var/log/video-dual.log

RTSP_PORT=8554
WEBRTC_PORT=8889
HLS_PORT=8888

gen_config() {
    {
        cat <<EOF
logLevel: info

rtsp: yes
rtspAddress: :$RTSP_PORT
rtspTransports: [tcp]

webrtc: yes
webrtcAddress: :$WEBRTC_PORT
webrtcAllowOrigins: ['*']

hls: yes
hlsAddress: :$HLS_PORT
hlsAlwaysRemux: yes

paths:
EOF

        if [ -c "$CAM1_DEV" ]; then
            cat <<EOF
  $STREAM1:
    runOnInit: ffmpeg -hide_banner -loglevel warning -f v4l2 -input_format h264 -video_size $CAM1_SIZE -framerate $CAM1_FPS -i $CAM1_DEV -an -c:v copy -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:$RTSP_PORT/$STREAM1
    runOnInitRestart: yes
EOF
        fi

        if [ -c "$CAM2_DEV" ]; then
            cat <<EOF
  $STREAM2:
    runOnInit: ffmpeg -hide_banner -loglevel warning -f v4l2 -input_format h264 -video_size $CAM2_SIZE -framerate $CAM2_FPS -i $CAM2_DEV -an -c:v copy -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:$RTSP_PORT/$STREAM2
    runOnInitRestart: yes
EOF
        fi
    } > "$CONF"
}

get_ip() {
    ip -4 -o addr show scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 \
        | grep -Ev '^(169\.254\.|127\.)' \
        | head -1
}

is_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

stop_other() {
    # 单路和双路共用同一套端口，确保不会互相抢
    if [ -f /var/run/video-single.pid ]; then
        OTHER=$(cat /var/run/video-single.pid)
        if kill -0 "$OTHER" 2>/dev/null; then
            echo "检测到「单路图传」正在运行，先停止它 ..."
            kill "$OTHER" 2>/dev/null
            rm -f /var/run/video-single.pid
            killall ffmpeg 2>/dev/null
            sleep 1
        fi
    fi
}

# 检查两个摄像头是否落在同一个 USB 控制器上
check_usb_topology() {
    [ -c "$CAM1_DEV" ] || return 0
    [ -c "$CAM2_DEV" ] || return 0
    P1=$(readlink -f "/sys/class/video4linux/$(basename "$CAM1_DEV")/device" 2>/dev/null)
    P2=$(readlink -f "/sys/class/video4linux/$(basename "$CAM2_DEV")/device" 2>/dev/null)
    [ -z "$P1" ] || [ -z "$P2" ] && return 0

    BUS1=$(echo "$P1" | sed -n 's#.*/\(usb[0-9]*\)/.*#\1#p')
    BUS2=$(echo "$P2" | sed -n 's#.*/\(usb[0-9]*\)/.*#\1#p')

    echo "  $CAM1_DEV -> $BUS1"
    echo "  $CAM2_DEV -> $BUS2"

    if [ -n "$BUS1" ] && [ "$BUS1" = "$BUS2" ]; then
        echo ""
        echo "  ⚠️  两个摄像头在同一个 USB 控制器（$BUS1）上"
        echo "     USB 2.0 带宽很可能带不动两路 1080p，第二路会失败。"
        echo "     解决：把其中一个摄像头换到板子上另一个 USB 口。"
        echo ""
    fi
}

start() {
    if is_running; then
        echo "双路图传已在运行 (PID $(cat "$PIDFILE"))"
        return 0
    fi

    if [ ! -c "$CAM1_DEV" ] && [ ! -c "$CAM2_DEV" ]; then
        echo "错误：两个摄像头都不存在（$CAM1_DEV / $CAM2_DEV）"
        echo "      可用 v4l2-ctl --list-devices 查看当前编号"
        return 1
    fi

    if [ ! -x "$MTX_BIN" ]; then
        echo "错误：找不到 $MTX_BIN"
        return 1
    fi

    stop_other

    if ps 2>/dev/null | grep -q "[r]ovcleaner"; then
        echo "检测到 rovcleaner 占用摄像头，正在停止 ..."
        killall rovcleaner 2>/dev/null
        sleep 1
    fi

    echo "双路拓扑检查："
    check_usb_topology

    gen_config

    echo "启动双路图传 ..."
    [ -c "$CAM1_DEV" ] && echo "  摄像头1: $CAM1_DEV  $CAM1_SIZE@${CAM1_FPS}fps"
    [ -c "$CAM2_DEV" ] && echo "  摄像头2: $CAM2_DEV  $CAM2_SIZE@${CAM2_FPS}fps"

    "$MTX_BIN" "$CONF" >>"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 5

    if is_running; then
        IP=$(get_ip)
        [ -z "$IP" ] && IP="<香橙派IP>"
        echo ""
        echo "已启动 (PID $(cat "$PIDFILE"))"
        echo ""
        echo "  浏览器打开："
        [ -c "$CAM1_DEV" ] && echo "    摄像头1 :  http://${IP}:${WEBRTC_PORT}/${STREAM1}/"
        [ -c "$CAM2_DEV" ] && echo "    摄像头2 :  http://${IP}:${WEBRTC_PORT}/${STREAM2}/"
        echo ""

        # 检查实际起来了几路
        EXPECT=0
        [ -c "$CAM1_DEV" ] && EXPECT=$((EXPECT + 1))
        [ -c "$CAM2_DEV" ] && EXPECT=$((EXPECT + 1))
        ACTUAL=$(ps 2>/dev/null | grep ffmpeg | grep -v grep | wc -l)

        if [ "$ACTUAL" -lt "$EXPECT" ]; then
            echo "  ⚠️  期望 $EXPECT 路，实际只有 $ACTUAL 路在推流"
            echo "     常见原因：USB 带宽不足（两个摄像头在同一控制器）"
            echo "     详情: tail -20 $LOGFILE"
            echo ""
        else
            echo "  ✅ $ACTUAL 路全部正常推流"
            echo ""
        fi

        echo "  日志: $LOGFILE"
        return 0
    fi

    echo "启动失败，最后 20 行日志："
    tail -n 20 "$LOGFILE" 2>/dev/null
    rm -f "$PIDFILE"
    return 1
}

stop() {
    echo "停止双路图传 ..."
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        rm -f "$PIDFILE"
    fi
    killall mediamtx 2>/dev/null
    killall ffmpeg 2>/dev/null
    echo "已停止"
}

status() {
    if is_running; then
        echo "双路图传：运行中 (PID $(cat "$PIDFILE"))"
        echo ""
        echo "  ffmpeg 进程："
        ps 2>/dev/null | grep ffmpeg | grep -v grep | head -5
        echo ""
        echo "  端口："
        netstat -tlnp 2>/dev/null | grep -E ":${WEBRTC_PORT}|:${HLS_PORT}|:${RTSP_PORT}"
        return 0
    fi
    echo "双路图传：未运行"
    return 1
}

case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    *)
        echo "用法: $0 {start|stop|restart|status}"
        echo ""
        echo "环境变量示例:"
        echo "  CAM1_DEV=/dev/video0 CAM1_FPS=30 CAM2_DEV=/dev/video2 CAM2_FPS=60 $0 restart"
        exit 1
        ;;
esac
