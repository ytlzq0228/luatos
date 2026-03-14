# LuatOS 移植说明（Air780EP + 外置 GPS）

本目录为 **Quectel_Location_Reporter** 在 **LuatOS** 平台上的移植版本，运行于 **Air780EP + 独立 GPS 模块** 方案。原项目（QuecPython）代码未做改动。

## 硬件对应

| 功能           | 硬件     | 说明 |
|----------------|----------|------|
| TTL 串口       | 串口1    | 调试/日志 |
| 供电电压采集   | ADC0     | 供电电压 = ADC电压 × 273300/3300，最大 90V |
| NET LED        | GPIO27   | 输出，高电平亮、低电平灭 |
| Reload 按键    | GPIO30   | 输入上拉，按下接 GND → 程序退出（刷机模式） |
| 高电平输入     | GPIO41   | 输入上拉，低电平触发 |
| NPN 输出       | GPIO24   | 输出，高电平 |
| 硬件看门狗     | GPIO28   | air153C_wtd，建议 150 秒喂一次 |
| 震动传感器     | GPIO39   | 输入上拉，低电平触发 |
| GPS            | 串口2 + GPIO22 | GPIO22 高电平打开 GPS 供电，串口2 接收 NMEA |
| 外置 SIM       | SIM0     | 蜂窝网络 |
| USB            | 下载程序 | Boot 键开机前按下进入 USB 下载模式 |

## 未移植功能

- **OLED**：不移植。
- **PowerKey**：不移植；加电直接运行，无需按键开机/关机逻辑。

## 项目结构

```
luatos/
├── main.lua           # 入口，加电运行
├── config.lua         # 配置读取与写回（与 config.cfg 格式兼容；支持 get/set/del 原始 key）
├── config.cfg.example # 配置示例
├── gnss_reporter.lua  # 主循环：外置 GNSS、LBS、Traccar/APRS
├── traccar_report.lua # Traccar 异步上报 + 持久化 + 服务器指令接收与结果上报
├── cmd_osmand.lua     # Osmand 协议指令解析与执行（SET/GET/DEL/REBOOT）
├── aprs_report.lua    # APRS 异步上报 + 持久化
├── battery.lua        # 供电电压（ADC0，273300/3300）
├── cell_info.lua      # 基站/信号信息
├── air153C_wtd.lua    # 外置看门狗（可选）
├── libnet.lua         # 网络阻塞 API 封装
├── fota_update.lua    # OTA 占位
└── README.md
```

## 配置说明

将 `config.cfg.example` 复制为 `config.cfg`，按需修改后部署到设备。

**唯一配置路径**：程序只使用根目录 **`/config.cfg`**（与 `/traccar_cache.txt`、`/aprs_cache.txt` 同分区，可读写）。  
- **首次运行**：若 `/config.cfg` 不存在，会自动从第一个找到的源文件（`/luadb/config.cfg`、`config.cfg` 等）复制一份到 `/config.cfg`，之后所有读写只针对 `/config.cfg`。  
- **程序加载时**会打印从 cfg 中读取到的全部 key=value，便于核对。

- **Traccar**：`traccar_host`、`traccar_port`（留空 `traccar_host` 则不上报 Traccar）
- **APRS**：`aprs_callsign`、`aprs_passcode`、`aprs_host`、`aprs_port`、`aprs_interval`（callsign 留空则不上报 APRS）
- **上报策略**：`moving_interval`、`still_interval`、`still_speed_threshold`
- **刷机**：`flash_gpio=30` 表示 Reload 键（GPIO30）按下时退出程序
- **看门狗**：`wdt_period` 对应硬件看门狗喂狗策略（代码内 150 秒喂一次）
- **上报测试模式**：`test_report_mode=1` 时使用固定坐标上报，不依赖真实 GNSS，用于验证 Traccar/APRS。需同时配置 `test_lat`、`test_lon`，可选 `test_alt`、`test_speed`、`test_course`、`test_accuracy`。测试完成后请改为 `test_report_mode=0`。

## 远程指令（Osmand 协议）

Traccar 可在设备上报位置时通过 **HTTP 响应 body** 下发排队中的指令，设备解析后执行并上报执行结果。

### 流程

1. 设备发送位置请求（GET，带 `id`、`lat`、`lon` 等）。
2. 若服务器有排队指令，响应 body 中为**指令原文**（纯文本）。
3. 设备打印请求/响应与指令原文，交给 **cmd_osmand** 模块解析执行。
4. 执行后**立即**发一次仅带 `id` 与 `lastCmdResult` 的请求，将结果上报服务器。
5. 若指令要求重启（SET/DEL 成功或 REBOOT），上报结果后设备执行 **rtos.reboot()**；否则继续正常上报循环。

### 支持的指令

| 指令 | 说明 | 成功返回 | 是否触发重启 |
|------|------|----------|--------------|
| **SET xxx=yyy** | 以 `SET ` 开头，修改或新增 cfg 中键值；支持多组：`SET k1=v1 k2=v2`（空格分隔，value 不含空格） | `SET k1=v1 k2=v2 OK` | 是 |
| **GET xxx** | 查询 cfg 中 key=xxx 的值 | `GET xxx=yyy OK` | 否 |
| **GET ALL** | 上报 cfg 中全部 key=value（按 key 排序，空格分隔） | `GET ALL k1=v1 k2=v2 ... OK` | 否 |
| **DEL xxx** | 删除 config.cfg 中 key=xxx 所在行 | `DEL xxx=yyy OK`（yyy 为被删掉的值） | 是 |
| **REBOOT** | 重启设备 | `REBOOT OK` | 是 |

- **DEL** 不允许删除 `traccar_host`、`traccar_port`，否则返回 `DEL xxx= FORBIDDEN`，且不重启。
- 多行指令仅执行**第一行**有效指令。
- 执行结果通过请求参数 **lastCmdResult**（URL 编码）上报，服务器需能解析该参数以显示或记录。

### 配置文件与 SET/DEL

程序仅使用根目录 **`/config.cfg`**（与缓存同分区，可读写）。若该文件不存在（例如首次烧录），会在首次读配置时从 `/luadb/config.cfg` 或 `config.cfg` 等源路径**复制一份**到 `/config.cfg`。远程指令 SET/DEL 只改写 `/config.cfg`。

### 日志标识

- `[REQ]`：每次 Traccar 位置请求（GET URL 与 Headers）。
- `[RESP]`：仅当**响应 body 带指令**时打印（code、Header、body 及 `server command (raw)`）；无指令时不再打响应日志。
- `[CMD] LastCmdResult=... RebootRequest=...`：指令执行结果与是否请求重启。

## 运行方式

1. 将本目录下所有 `.lua` 与 `config.cfg` 部署到设备（Luatools 或 OTA）。**Air780EP 上请将 `config.cfg` 放在与 `main.lua` 同一目录**（常见为 `/luadb/`），否则会使用内置默认配置。
2. 设置开机自启执行 `main.lua`（具体方式以合宙/设备说明为准）。
3. 上电后等待网络就绪（NET LED 亮），外置 GPS 供电由 GPIO22 自动打开，串口2 接收 NMEA 后解析并上报 Traccar/APRS。
4. 配置仅使用根目录 **`/config.cfg`**；首次运行若不存在会从 `/luadb/config.cfg` 等自动复制。远程 SET/DEL 只改写该文件。

## Traccar 出现 502 时（HAProxy 等反向代理）

设备端已发送：`Host`、`User-Agent`、`Connection: close`。若仍偶发 502，多为**服务端/代理**问题，可依次检查：

- **HAProxy**：适当调大 `timeout connect`、`timeout server`（如 10s 以上）；必要时将 `http-server-close` 改为 `http-keep-alive` 或反之，观察 502 是否消失。
- **Traccar 后端**：确认进程常驻、数据库连接正常、磁盘未满；查看 Traccar 与 HAProxy 日志中 502 对应时刻的报错。
- **网络**：HAProxy 到 Traccar 的端口、防火墙、本机回环访问是否正常。

设备会对 502 做退避重试，服务恢复后会自动继续上报。

## 依赖与参考

- **运行环境**：LuatOS（Air780EP），需 uart、gpio、adc、mobile、socket、http、sys、json 等库；远程 REBOOT 依赖 **rtos.reboot()**。
- **API 参考**：[LuatOS 文档](https://wiki.luatos.com/api/index.html)。

## 与 QuecPython 版的差异

- 语言为 **Lua**，原项目为 Python。
- GNSS 为 **外置模块**（串口2 + GPIO22），非模组内置 GNSS。
- 无 OLED、无 PowerKey；上电即运行。
- 刷机控制使用 **Reload 键 GPIO30**（按下接 GND 退出）。
- 供电电压使用 **ADC0** 及公式 **电压 = ADC×273300/3300**，最大 90V。
- LBS 若使用自定义服务器（如移远 LBS），需在 `gnss_reporter.lua` 的 `get_lbs_location()` 中自行实现 HTTP 请求；未配置时仅使用 GNSS。
- **远程指令**：支持 Traccar 通过 HTTP 响应 body 下发 Osmand 协议指令（SET/GET/DEL/REBOOT），设备执行后上报 lastCmdResult 并按需重启。
