#!/bin/sh
#
# 双路视频透传：/dev/video0 + /dev/video2 -> MediaMTX -> 局域网浏览器
#
# 原理：ffmpeg 从摄像头读取已编码的 H264 数据，原样（-c:v copy）推到本地 RTSP，
#       MediaMTX 再转成 WebRTC / HLS 给浏览器。全程不转码，CPU 占用极低。
#
# 用法:
#   ./video_stream.sh start|stop|restart|status
#
# 浏览器访问（<IP> 换成香橙派的局域网地址）:
#   摄像头1  http://<IP>:8889/live/cam1/     WebRTC（延迟 <0.5s）
#   摄像头2  http://<IP>:8889/live/cam2/
#   HLS 备用 http://<IP>:8888/live/cam1/index.m3u8
#
# 可选环境变量（每路独立）:
#   CAM1_DEV=/dev/video0  CAM1_SIZE=1920x1080  CAM1_FPS=60
#   CAM2_DEV=/dev/video2  CAM2_SIZE=1920x1080  CAM2_FPS=30
#

CAM1_DEV=${CAM1_DEV:-/dev/video0}
CAM1_SIZE=${CAM1_SIZE:-1920x1080}
CAM1_FPS=${CAM1_FPS:-60}

CAM2_DEV=${CAM2_DEV:-/dev/video2}
CAM2_SIZE=${CAM2_SIZE:-1920x1080}
CAM2_FPS=${CAM2_FPS:-30}

STREAM1=live/cam1
STREAM2=live/cam2

MTX_BIN=/wz/mediamtx
CONF=/tmp/mediamtx-video.yml
PIDFILE=/var/run/video-stream.pid
LOGFILE=/var/log/video-stream.log

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
    # 排除 link-local (169.254.x.x) 和回环，取真实局域网地址
    ip -4 -o addr show scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 \
        | grep -Ev '^(169\.254\.|127\.)' \
        | head -1
}

is_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

start() {
    if is_running; then
        echo "已在运行 (PID $(cat "$PIDFILE"))"
        return 0
    fi

    if [ ! -c "$CAM1_DEV" ] && [ ! -c "$CAM2_DEV" ]; then
        echo "错误：两个摄像头都不存在（$CAM1_DEV / $CAM2_DEV）"
        echo "      可用 ls /dev/video* 查看"
        return 1
    fi

    if [ ! -x "$MTX_BIN" ]; then
        echo "错误：找不到可执行文件 $MTX_BIN"
        return 1
    fi

    # 原厂 rovcleaner 会霸占摄像头设备，先停掉（与厂家 S95wz-camera 的做法一致）
    if ps 2>/dev/null | grep -q "[r]ovcleaner"; then
        echo "检测到原厂 rovcleaner 占用摄像头，正在停止 ..."
        killall rovcleaner 2>/dev/null
        sleep 1
    fi

    gen_config

    echo "启动视频透传 ..."
    [ -c "$CAM1_DEV" ] && echo "  摄像头1: $CAM1_DEV  $CAM1_SIZE@${CAM1_FPS}fps"
    [ -c "$CAM2_DEV" ] && echo "  摄像头2: $CAM2_DEV  $CAM2_SIZE@${CAM2_FPS}fps"

    "$MTX_BIN" "$CONF" >>"$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 3

    if is_running; then
        IP=$(get_ip)
        [ -z "$IP" ] && IP="<香橙派IP>"
        echo ""
        echo "已启动 (PID $(cat "$PIDFILE"))"
        echo ""
        echo "  浏览器打开以下地址即可观看："
        [ -c "$CAM1_DEV" ] && echo "    摄像头1 WebRTC :  http://${IP}:${WEBRTC_PORT}/${STREAM1}/"
        [ -c "$CAM2_DEV" ] && echo "    摄像头2 WebRTC :  http://${IP}:${WEBRTC_PORT}/${STREAM2}/"
        echo ""
        echo "  HLS 备用:"
        [ -c "$CAM1_DEV" ] && echo "    http://${IP}:${HLS_PORT}/${STREAM1}/index.m3u8"
        [ -c "$CAM2_DEV" ] && echo "    http://${IP}:${HLS_PORT}/${STREAM2}/index.m3u8"
        echo ""
        echo "  RTSP:"
        [ -c "$CAM1_DEV" ] && echo "    rtsp://${IP}:${RTSP_PORT}/${STREAM1}"
        [ -c "$CAM2_DEV" ] && echo "    rtsp://${IP}:${RTSP_PORT}/${STREAM2}"
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
    echo "停止视频透传 ..."
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
        echo "运行中 (PID $(cat "$PIDFILE"))"
        echo ""
        echo "  ffmpeg 进程："
        ps 2>/dev/null | grep ffmpeg | grep -v grep | head -5
        echo ""
        echo "  监听端口："
        netstat -tlnp 2>/dev/null | grep -E ":${WEBRTC_PORT}|:${HLS_PORT}|:${RTSP_PORT}"
        return 0
    fi
    echo "未运行"
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
        echo "示例（降分辨率省带宽）:"
        echo "  CAM1_SIZE=1280x720 CAM2_SIZE=1280x720 CAM2_FPS=30 $0 restart"
        exit 1
        ;;
esac
