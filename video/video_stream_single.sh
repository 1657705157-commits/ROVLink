#!/bin/sh
#
# ============================================================
#  单路图传
#  一个摄像头 -> MediaMTX -> 局域网浏览器
# ============================================================
#
# 原理：ffmpeg 从摄像头读取已编码的 H264，原样（-c:v copy）推到本地 RTSP，
#       MediaMTX 转成 WebRTC / HLS 供浏览器观看。全程不转码，CPU 几乎零占用。
#
# 用法:
#   ./video_stream_single.sh start      启动
#   ./video_stream_single.sh stop       停止
#   ./video_stream_single.sh restart    重启
#   ./video_stream_single.sh status     状态
#
# 浏览器访问:
#   http://<IP>:8889/live/cam/            WebRTC（延迟 <0.5s，推荐）
#   http://<IP>:8888/live/cam/index.m3u8  HLS（延迟 3-5s，兼容性好）
#   rtsp://<IP>:8554/live/cam             给 VLC / ffplay
#
# 可选环境变量:
#   CAM_DEV=/dev/video0   CAM_SIZE=1920x1080   CAM_FPS=30
#
# 示例:
#   CAM_DEV=/dev/video2 CAM_SIZE=1280x720 CAM_FPS=60 ./video_stream_single.sh restart
#

CAM_DEV=${CAM_DEV:-/dev/video0}
CAM_SIZE=${CAM_SIZE:-1920x1080}
CAM_FPS=${CAM_FPS:-30}
STREAM=live/cam

MTX_BIN=/wz/mediamtx
CONF=/tmp/mediamtx-single.yml
PIDFILE=/var/run/video-single.pid
LOGFILE=/var/log/video-single.log

RTSP_PORT=8554
WEBRTC_PORT=8889
HLS_PORT=8888

gen_config() {
    cat > "$CONF" <<EOF
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
  $STREAM:
    runOnInit: ffmpeg -hide_banner -loglevel warning -f v4l2 -input_format h264 -video_size $CAM_SIZE -framerate $CAM_FPS -i $CAM_DEV -an -c:v copy -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:$RTSP_PORT/$STREAM
    runOnInitRestart: yes
EOF
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
    if [ -f /var/run/video-dual.pid ]; then
        OTHER=$(cat /var/run/video-dual.pid)
        if kill -0 "$OTHER" 2>/dev/null; then
            echo "检测到「双路图传」正在运行，先停止它 ..."
            kill "$OTHER" 2>/dev/null
            rm -f /var/run/video-dual.pid
            killall ffmpeg 2>/dev/null
            sleep 1
        fi
    fi
}

start() {
    if is_running; then
        echo "单路图传已在运行 (PID $(cat "$PIDFILE"))"
        return 0
    fi

    if [ ! -c "$CAM_DEV" ]; then
        echo "错误：摄像头 $CAM_DEV 不存在"
        echo "      可用 ls /dev/video* 查看，或用 v4l2-ctl --list-devices 确认编号"
        return 1
    fi

    if [ ! -x "$MTX_BIN" ]; then
        echo "错误：找不到 $MTX_BIN"
        return 1
    fi

    stop_other

    # 原厂 rovcleaner 会霸占摄像头，先停掉（与厂家 S95wz-camera 的做法一致）
    if ps 2>/dev/null | grep -q "[r]ovcleaner"; then
        echo "检测到 rovcleaner 占用摄像头，正在停止 ..."
        killall rovcleaner 2>/dev/null
        sleep 1
    fi

    gen_config

    echo "启动单路图传 ($CAM_DEV  $CAM_SIZE@${CAM_FPS}fps) ..."
    "$MTX_BIN" "$CONF" >>"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 3

    if is_running; then
        IP=$(get_ip)
        [ -z "$IP" ] && IP="<香橙派IP>"
        echo ""
        echo "已启动 (PID $(cat "$PIDFILE"))"
        echo ""
        echo "  浏览器打开："
        echo "    WebRTC :  http://${IP}:${WEBRTC_PORT}/${STREAM}/"
        echo "    HLS    :  http://${IP}:${HLS_PORT}/${STREAM}/index.m3u8"
        echo "    RTSP   :  rtsp://${IP}:${RTSP_PORT}/${STREAM}"
        echo ""
        echo "  日志: $LOGFILE"
        return 0
    fi

    echo "启动失败，最后 20 行日志："
    tail -n 20 "$LOGFILE" 2>/dev/null
    rm -f "$PIDFILE"
    return 1
}

stop() {
    echo "停止单路图传 ..."
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
        echo "单路图传：运行中 (PID $(cat "$PIDFILE"))"
        echo ""
        echo "  ffmpeg："
        ps 2>/dev/null | grep ffmpeg | grep -v grep | head -3
        echo ""
        echo "  端口："
        netstat -tlnp 2>/dev/null | grep -E ":${WEBRTC_PORT}|:${HLS_PORT}|:${RTSP_PORT}"
        return 0
    fi
    echo "单路图传：未运行"
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
        echo "  CAM_DEV=/dev/video2 CAM_SIZE=1280x720 CAM_FPS=60 $0 restart"
        exit 1
        ;;
esac
