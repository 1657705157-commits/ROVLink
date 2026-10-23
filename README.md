# 一键部署水下 ROV：单路/多路图传与遥测网络链路

从香橙派 RK3588（Buildroot）备份的可移植部署包，用于**迁移到其他 ARM64 开发板**。

- **图传**：摄像头 → ffmpeg（不转码）→ MediaMTX → WebRTC / HLS / RTSP
- **遥测链路**：飞控串口 → socat → UDP 端口，供局域网内任意设备通过 MAVLink 访问

---

## 目录结构

```
deploy/
├── README.md                          # 本文件
├── install.sh                         # 一键安装（复制文件 + 设权限 + 启动）
├── video/
│   ├── video_stream_single.sh         # 单路图传（推荐）
│   ├── video_stream_dual.sh           # 双路图传
│   ├── video_stream.sh                # 旧版（保留参考）
│   └── S96wz-video                    # init.d 自启脚本（单路）
└── mavlink/
    └── S100_mavlink-bridge            # init.d 自启脚本（UDP 中继）
```

---

## 一、依赖

### 必需软件

| 软件 | 用途 | 检查命令 |
|---|---|---|
| `ffmpeg` | 读摄像头推 RTSP | `ffmpeg -version` |
| `v4l2-ctl` | 查询摄像头格式（可选） | `v4l2-ctl --list-devices` |
| `socat` | 串口 ↔ UDP 中继 | `socat -V` |
| `stty` / `netstat` | 串口配置、端口检查 | 系统自带 |

### MediaMTX 二进制（不包含在包里）

**63 MB 的 arm64 二进制，需单独获取**：

```bash
# 从原香橙派拷贝（推荐，版本已验证）
scp root@<原香橙派IP>:/wz/mediamtx /wz/mediamtx

# 或从官网下载（v1.20.1 arm64）
# https://github.com/bluenviron/mediamtx/releases
```

放到 `/wz/mediamtx` 并加执行权限：

```bash
chmod +x /wz/mediamtx
```

---

## 二、部署步骤

### 方式 A：一键脚本

```bash
# 在目标开发板上
scp -r deploy/ root@<目标板IP>:/root/deploy/
ssh root@<目标板IP>

cd /root/deploy
chmod +x install.sh
./install.sh
```

### 方式 B：手动

```bash
# 1. 创建目录
mkdir -p /wz

# 2. 图传脚本
cp deploy/video/video_stream_single.sh /wz/
cp deploy/video/video_stream_dual.sh   /wz/
chmod +x /wz/video_stream_single.sh /wz/video_stream_dual.sh

# 3. MediaMTX（需自行放进 /wz/）
chmod +x /wz/mediamtx

# 4. 开机自启
cp deploy/video/S96wz-video       /etc/init.d/
cp deploy/mavlink/S100_mavlink-bridge /etc/init.d/
chmod 755 /etc/init.d/S96wz-video /etc/init.d/S100_mavlink-bridge

# 5. 启动
/etc/init.d/S100_mavlink-bridge start
/etc/init.d/S96wz-video start
```

---

## 三、图传说明

### 单路（`video_stream_single.sh`）

```bash
/wz/video_stream_single.sh start|stop|restart|status

# 自定义参数
CAM_DEV=/dev/video2 CAM_SIZE=1280x720 CAM_FPS=60 /wz/video_stream_single.sh restart
```

**访问地址**（`<IP>` = 开发板 IP）：

| 协议 | 地址 | 延迟 | 说明 |
|---|---|---|---|
| **WebRTC** | `http://<IP>:8889/live/cam/` | <0.5s | 推荐，浏览器直接看 |
| HLS | `http://<IP>:8888/live/cam/index.m3u8` | 3-5s | 兼容性最好 |
| RTSP | `rtsp://<IP>:8554/live/cam` | 低 | VLC / ffplay |

**原理**：摄像头输出已是 H.264，用 `-c:v copy` 直接转封装，**不做转码**，
CPU 占用接近零。

### 双路（`video_stream_dual.sh`）

```bash
CAM1_DEV=/dev/video0 CAM1_SIZE=1920x1080 CAM1_FPS=30 \
CAM2_DEV=/dev/video2 CAM2_SIZE=1920x1080 CAM2_FPS=60 \
/wz/video_stream_dual.sh start
```

访问：`http://<IP>:8889/live/cam1/` 和 `http://<IP>:8889/live/cam2/`

> ⚠️ **两个摄像头必须接在不同的 USB 控制器上**。
> 同在 USB 2.0 控制器下会报 `ioctl(VIDIOC_STREAMON): No space left on device`
> —— 那是等时带宽不足，换 USB 口才能解决。
>
> 检查：`ls -l /sys/class/video4linux/video*/device`
> 路径里出现 `/usb1/` 和 `/usb2/` 才说明分属不同控制器。

### 端口占用

两套脚本**共用同一组端口**，不能同时运行（脚本内部会自动互斥）：

```
8554  RTSP
8888  HLS
8889  WebRTC
```

---

## 四、MAVLink UDP 中继

### 原理

```
飞控 TELEM 口 --串口--> 开发板 /dev/ttyS0 --socat--> UDP:15001
                                                        ↓
                                          局域网任意设备 MAVLink 客户端
```

### 配置

编辑 `/etc/init.d/S100_mavlink-bridge` 顶部：

```sh
SERIAL_PORT="/dev/ttyS0"     # 飞控连到开发板的串口
BAUD_RATE="57600"            # 必须与飞控 SERIALx_BAUD 一致
UDP_PORT="15001"
BIND_IP="0.0.0.0"           # 允许局域网访问
```

### 使用

```bash
/etc/init.d/S100_mavlink-bridge start|stop|restart|status|test
```

### 客户端连接

```python
from pymavlink import mavutil
master = mavutil.mavlink_connection("udpout:<开发板IP>:15001", source_system=255)
```

或用 QGC：**Application Settings → Comm Links → Add**
`UDP`，端口 `15001`，目标地址 `<开发板IP>`

### ⚠️ 单客户端限制

`socat` 的 `UDP-LISTEN` 同一时刻**只服务一个客户端**（虽然配了 `fork`，
但 `nonblock=1` 会让连接提前断开）。

**多个程序要同时访问飞控时**，二选一：

1. **改用 mavlink-router**（推荐，支持多客户端分流）
2. **中间加一个 MAVLink 分发器**（如 `mavproxy` 或 `mavlink-router`）

---

## 五、开机自启

Buildroot 的 init.d 按文件名排序执行：

```
/etc/init.d/S96wz-video          755   ← 图传（网络就绪后启动）
/etc/init.d/S100_mavlink-bridge  755   ← MAVLink 中继
```

**禁用工厂自带的服务**（会抢占摄像头/串口）：

```bash
chmod 644 /etc/init.d/S95wz-camera    # 工厂摄像头服务
chmod 644 /etc/init.d/S51_rov_app     # 工厂 ROV 应用
```

**检查自启状态**：

```bash
ls -l /etc/init.d/S* | grep -E "wz|mavlink|rov"
```

---

## 六、验证清单

```bash
# 1. 摄像头识别
ls /dev/video*
v4l2-ctl --list-devices

# 2. 图传状态
/wz/video_stream_single.sh status

# 3. 端口监听
netstat -lntp | grep -E "8554|8888|8889"

# 4. 浏览器访问
#    http://<IP>:8889/live/cam/

# 5. MAVLink 中继
/etc/init.d/S100_mavlink-bridge status
netstat -lun | grep 15001

# 6. 从外部测试 MAVLink
python3 onboard_computer/test_fc_link.py    # 默认 udpout:<IP>:15001
```

---

## 七、迁移到新开发板的注意事项

| 项目 | 需要确认 |
|---|---|
| **CPU 架构** | MediaMTX 二进制必须匹配（x86_64 板子需换二进制） |
| **摄像头设备号** | `/dev/video0` 可能变成 `/dev/video2`，用 `v4l2-ctl --list-devices` 确认 |
| **摄像头格式** | 必须支持 **H.264 硬编码输出**，否则 `-c:v copy` 会失败 |
| **串口设备** | `/dev/ttyS0` 可能是 `/dev/ttyAML0`（Amlogic）、`/dev/ttyTHS0`（Jetson）等 |
| **波特率** | 与飞控 `SERIALx_BAUD` 参数一致 |
| **init.d** | 非 Buildroot 系统（Debian/Ubuntu）用 systemd，需改写 service |
| **USB 带宽** | 双路 1080p60 需要不同 USB 控制器 |

### 摄像头不支持的 H.264 时

改脚本里的 ffmpeg 参数，去掉 `-c:v copy`：

```sh
# 原（零拷贝，要求摄像头硬编码）
-c:v copy

# 改（软件编码，CPU 占用高）
-c:v libx264 -preset ultrafast -tune zerolatency -b:v 4M
```

---

## 八、故障排查

| 现象 | 原因 | 解决 |
|---|---|---|
| `摄像头 /dev/video0 不存在` | 设备号变了 | `v4l2-ctl --list-devices` 确认 |
| `找不到 /wz/mediamtx` | 二进制未放 | 从原板拷贝或官网下载 |
| 浏览器打开 404 | 路径不对 | 注意末尾斜杠 `.../live/cam/` |
| `No space left on device` | USB 带宽不足 | 换到另一个 USB 控制器 |
| MAVLink 收不到心跳 | 串口/波特率不对 | `S100_mavlink-bridge test` 看原始数据 |
| 多程序争抢飞控 | socat 单客户端 | 改用 mavlink-router |
| 图传启动后无画面 | `rovcleaner` 占用摄像头 | `killall rovcleaner` |
