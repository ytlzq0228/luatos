-- gnss_reporter.lua - LuatOS 定位上报主循环（Air780EP + 外置 GPS）
-- 功能：外置 GNSS(UART2+GPIO22)；无 GNSS 时可选 LBS；Traccar/APRS 异步上报。
-- 不加 OLED、不加 PowerKey，加电直接运行。
-- 硬件：串口1 TTL | ADC0 供电电压 | NET LED 27 | Reload 30 | 高电平入 41 | NPN 24 | 看门狗 28 | 震动 39 | GPS 串口2+电源 22
--
-- 依赖：config, battery, cell_info, traccar_report, aprs_report；可选 lbsLoc2, air153C_wtd

local sys = sys
local log = log
local uart = uart
local gpio = gpio
local adc = adc
local mobile = mobile
local json = json
local os = os
local string = string
local math = math
local table = table

-- 硬件引脚
local PIN_GPS_POWER = 22   -- GPS 供电，高电平打开
local PIN_NET_LED = 27     -- 网络 LED，高亮低灭
local PIN_RELOAD = 30      -- Reload 按键，输入上拉，按下接 GND → 退出刷机模式
local PIN_NPN = 24         -- NPN 输出，高电平
local PIN_WDT = 28         -- 硬件看门狗 air153C_wtd，建议 150 秒喂一次
local PIN_VIBRATION = 39   -- 震动传感器，输入上拉，低电平触发
local PIN_HIGH_IN = 41    -- 高电平输入，输入上拉，低电平触发
local UART_GPS_ID = 2      -- GPS 使用串口 2
local GPS_BAUD = 115200   -- ATGM336H 等北斗/GPS 模块常用 115200，部分模块为 9600
local WDT_FEED_INTERVAL_MS = 150 * 1000  -- 150 秒喂狗
local VERSION = "1.0.0-luatos"

local config = require("config")
local battery = require("battery")
local cell_info = require("cell_info")
local traccar_report = require("traccar_report")
local aprs_report = require("aprs_report")
-- FOTA：合宙 IoT 平台，上电联网后执行一次
local libfota_ok, libfota = pcall(require, "libfota")
if not libfota_ok then libfota = nil end
-- 外置看门狗 Air153C，GPIO28，需显式 require 并每 150 秒喂狗，否则设备会重启
local wtd_ok, air153C_wtd = pcall(require, "air153C_wtd")
if not wtd_ok then air153C_wtd = nil end

local gps_data = {
    lat = nil, lon = nil, speed = 0, track = nil, alt = nil,
    sats = 0, hdop = nil, fix = "0", accuracy = nil, _source = nil,
}
local gps_buf = ""
-- 由后台任务每 30 秒刷新，主流程只读
local extra_cache = {}
local EXTRA_CACHE_INTERVAL_SEC = 30

local function load_config()
    local ok, cfg = pcall(config.load_config)
    if not ok or not cfg then
        return {
            traccar_host = "", traccar_port = 5055, moving_interval = 10, still_interval = 300,
            still_speed_threshold = 5, flash_gpio = 30, network_check_timeout = 60, wdt_period = 60,
            lbs_server = "", lbs_interval = 60, aprs_callsign = "", aprs_interval = 60,
        }
    end
    return cfg
end

local function dm_to_deg(dm, hemi)
    if not dm or dm == "" then return nil end
    local v = tonumber(dm)
    if not v then return nil end
    local d = math.floor(v / 100)
    local m = v - d * 100
    local deg = d + m / 60.0
    if hemi == "S" or hemi == "W" then deg = -deg end
    return deg
end

local function parse_gga(line)
    local f = {}
    for part in (line .. ","):gmatch("(.-),") do table.insert(f, part) end
    if #f < 10 then return nil end
    local fix = (f[7] or "0"):gsub("^%s*(.-)%s*$", "%1")
    local sats = (f[8] or "0"):gsub("^%s*(.-)%s*$", "%1")
    local hdop = (f[9] or ""):gsub("^%s*(.-)%s*$", "%1")
    local alt = (f[10] or ""):gsub("^%s*(.-)%s*$", "%1")
    return fix, sats, hdop, alt
end

local function parse_rmc(line)
    local f = {}
    for part in (line .. ","):gmatch("(.-),") do table.insert(f, part) end
    if #f < 10 then return nil end
    local status = (f[3] or "V"):gsub("^%s*(.-)%s*$", "%1")
    local lat = dm_to_deg(f[4], f[5])
    local lon = dm_to_deg(f[6], f[7])
    local spd_kn = (f[8] or "0"):gsub("^%s*(.-)%s*$", "%1")
    local course = (f[9] or ""):gsub("^%s*(.-)%s*$", "%1")
    local date = (f[10] or ""):gsub("^%s*(.-)%s*$", "%1")
    local time_utc = (f[2] or ""):gsub("^%s*(.-)%s*$", "%1")
    return status, lat, lon, spd_kn, course, date, time_utc
end

local function gnss_read_once()
    if not uart or not uart.rxSize then return end
    local n = uart.rxSize(UART_GPS_ID)
    if n and n > 0 then
        local data = uart.read(UART_GPS_ID, math.min(512, n))
        if data and #data > 0 then
            gps_buf = gps_buf .. data
        end
    end
    if #gps_buf > 4096 then gps_buf = gps_buf:sub(-4096) end
    for line in (gps_buf .. "\n"):gmatch("(.-)\r?\n") do
        if line:match("^%$..") and #line >= 6 then
            local msg = line:sub(4, 6)
            if msg == "GGA" then
                local fix, sats, hdop, alt = parse_gga(line)
                if fix then
                    gps_data.fix = fix
                    gps_data.sats = tonumber(sats) or 0
                    gps_data.hdop = hdop
                    gps_data.accuracy = (hdop and hdop ~= "" and tonumber(hdop)) and (tonumber(hdop) * 2.5) or nil
                    gps_data.alt = (alt and alt ~= "" and tonumber(alt)) or nil
                end
            elseif msg == "RMC" then
                local status, lat, lon, spd_kn, course = parse_rmc(line)
                if status == "A" and lat and lon then
                    gps_data.lat = lat
                    gps_data.lon = lon
                    gps_data.speed = (tonumber(spd_kn) or 0) * 1.852
                    gps_data.track = (course and course ~= "" and tonumber(course)) or nil
                end
            end
        end
    end
    -- 保留未完成的一行
    local last = gps_buf:match("\r?\n([^\r\n]*)$")
    gps_buf = last or ""
end

local function get_device_id()
    if mobile and mobile.imei then
        local imei = mobile.imei()
        if imei and imei ~= "" then return tostring(imei) end
    end
    return "Air780EP"
end

-- LBS：未配置 lbs_server 时使用 LuatOS 内置 lbsLoc2（合宙单基站定位）；否则可扩展自定义 HTTP
-- 文档: https://wiki.luatos.com/api/libs/lbsLoc2.html
local function get_lbs_location(cfg)
    local custom_server = (cfg.lbs_server or ""):match("%S")
    if custom_server then
        -- 自定义 LBS 服务器需按接口实现 HTTP 请求，此处留空
        return nil, nil, nil
    end
    -- 使用 lbsLoc2：必须在协程中调用（本函数已在 main 的 sys.taskInit 内）
    local ok, lbsLoc2 = pcall(require, "lbsLoc2")
    if not ok or not lbsLoc2 or not lbsLoc2.request then
        log.warn("GNSS", "lbsLoc2 not available")
        return nil, nil, nil
    end
    if not mobile or not mobile.reqCellInfo then
        log.warn("GNSS", "mobile.reqCellInfo not available for LBS")
        return nil, nil, nil
    end
    local timeout_ms = math.max(5000, math.min(60000, (cfg.lbs_timeout or 30) * 1000))
    -- 部分模组不发布 CELL_INFO_UPDATE，先 reqCellInfo 后短时等待再请求；lbsLoc2 内部会优先用 mobile.scell()
    mobile.reqCellInfo(15)
    if sys.waitUntil and sys.waitUntil("CELL_INFO_UPDATE", 3000) ~= "CELL_INFO_UPDATE" then
        sys.wait(2000)  -- 无事件时再等 2 秒让模组更新基站信息，避免 16 秒阻塞
    end
    local lat, lng = lbsLoc2.request(timeout_ms, nil, nil, false)
    if lat and lng then
        local acc = 250  -- 单基站定位精度约 1.5km
        return tonumber(lat), tonumber(lng), acc
    end
    return nil, nil, nil
end

local function get_utc_timestamp()
    return os.time()
end

-- 后台任务：每 30 秒刷新 rssi/cell 到 extra_cache，主流程只读缓存不阻塞
local function _extra_cache_loop()
    local function do_refresh()
        pcall(function()
            if mobile and mobile.csq then
                local csq = mobile.csq()
                if csq then extra_cache.rssi = csq end
            end
        end)
        pcall(function()
            if cell_info and cell_info.get_cell_info then
                extra_cache.cell = cell_info.get_cell_info()
            end
        end)
    end
    sys.wait(2000)  -- 启动后 2 秒做首次刷新
    do_refresh()
    while true do
        sys.wait(EXTRA_CACHE_INTERVAL_SEC * 1000)
        do_refresh()
    end
end

local function start_extra_cache_task()
    sys.taskInit(_extra_cache_loop)
    log.info("GNSS", "extra_cache task started, interval=" .. EXTRA_CACHE_INTERVAL_SEC .. "s")
end

local function build_traccar_payload(device_id, lat, lon)
    local payload = {
        id = device_id,
        lat = string.format("%.7f", lat),
        lon = string.format("%.7f", lon),
        timestamp = get_utc_timestamp(),
    }
    if gps_data.speed then payload.speed = string.format("%.2f", gps_data.speed / 1.852) end
    if gps_data.track then payload.bearing = string.format("%.1f", gps_data.track) end
    if gps_data.alt then payload.altitude = string.format("%.1f", gps_data.alt) end
    if gps_data.sats then payload.sat = gps_data.sats end
    if gps_data.accuracy then payload.accuracy = string.format("%.1f", gps_data.accuracy) end
    if gps_data._source then payload.source = gps_data._source end
    local l, v = battery.get_battery()
    if l then payload.batteryLevel = string.format("%.1f", l) end
    if v then payload.batteryVoltage = v end
    if extra_cache.rssi then payload.rssi = extra_cache.rssi end
    if extra_cache.cell then payload.cell = extra_cache.cell end
    payload.version = _G.VERSION or ""
    return payload
end

-- 无定位时上报的状态 payload：仅含设备 id、时间戳、电量、信号、基站等（无 lat/lon）
local function build_traccar_status_payload(device_id)
    local payload = {
        id = device_id,
        timestamp = get_utc_timestamp(),
    }
    local l, v = battery.get_battery()
    if l then payload.batteryLevel = string.format("%.1f", l) end
    if v then payload.batteryVoltage = v end
    if extra_cache.rssi then payload.rssi = extra_cache.rssi end
    if extra_cache.cell then payload.cell = extra_cache.cell end
    payload.version = _G.VERSION or ""
    return payload
end

local function gpio_setup()
    if gpio then
        pcall(function() gpio.setup(PIN_NET_LED, 0, gpio.PULLUP) end)   -- 输出，默认低
        pcall(function() gpio.setup(PIN_RELOAD, 1, gpio.PULLUP) end)    -- 输入上拉
        pcall(function() gpio.setup(PIN_NPN, 0, gpio.PULLUP) end)       -- 输出
        pcall(function() gpio.setup(PIN_VIBRATION, 1, gpio.PULLUP) end)
        pcall(function() gpio.setup(PIN_HIGH_IN, 1, gpio.PULLUP) end)
        pcall(function() gpio.setup(PIN_GPS_POWER, 0, gpio.PULLUP) end)
        gpio.set(PIN_GPS_POWER, 1)  -- 打开 GPS 供电
    end
end

local function is_flash_mode()
    if not gpio or not gpio.get then return false end
    local ok, v = pcall(gpio.get, PIN_RELOAD)
    if ok and v == 0 then return true end  -- 按下为低
    return false
end

local function wdt_feed()
    if air153C_wtd and air153C_wtd.feed_dog then
        pcall(air153C_wtd.feed_dog, PIN_WDT)
    end
end

local function wdt_init()
    if air153C_wtd and air153C_wtd.init then
        pcall(air153C_wtd.init, PIN_WDT)
        log.info("GNSS", "WDT init GPIO28, feed 150s")
    else
        log.warn("GNSS", "air153C_wtd not found, WDT not in use (device may reboot ~150s)")
    end
end

function main()
    log.info("GNSS", "starting...")
    log.info("GNSS", "Version: " .. VERSION)
    gpio_setup()
    uart.setup(UART_GPS_ID, GPS_BAUD, 8, 1, uart.NONE)
    local cfg = load_config()
    if (cfg.flash_gpio or -1) >= 0 and is_flash_mode() then
        log.info("GNSS", "Reload pin asserted, exit for flash mode.")
        return
    end
    local device_id = get_device_id()
    log.info("GNSS", "device_id: " .. device_id)
    log.info("GNSS", "wait network...")
    local ok_net = sys.waitUntil("IP_READY", (cfg.network_check_timeout or 60) * 1000)
    if not ok_net then
        log.error("GNSS", "network not ready, exit.")
        return
    end
    log.info("GNSS", "network ready")
    gpio.set(PIN_NET_LED, 1)
    -- 联网后执行一次 FOTA（地址来自 config：未配置则默认，显式留空则不请求）
    local fota_base = (cfg.fota_url or ""):gsub("^%s*(.-)%s*$", "%1")
    if libfota and libfota.request and fota_base ~= "" then
        log.info("GNSS", "FOTA url: " .. fota_base)
        local function fota_cb(result)
            -- 0=成功 1=连接失败 2=url错误 3=服务器断开 4=接收错误 5=VERSION需xxx.yyy.zzz或缺少PRODUCT_KEY
            log.info("GNSS", "FOTA result: " .. tostring(result))
            if result == 0 then
                log.info("GNSS", "FOTA success, rebooting...")
                rtos.reboot()
            end
        end
        local ver = _G.VERSION or "1.0.1"
        local imei = (mobile and mobile.imei and mobile.imei()) or ""
        local base = fota_base:gsub("%?.*$", "")
        local url = base .. "?version=" .. ver .. "&imei=" .. (imei ~= "" and imei or "unknown")
        libfota.request(fota_cb, url)
    end
    if socket and socket.sntp then
        socket.sntp()
        sys.waitUntil("NTP_UPDATE", 10000)
    end
    if cfg.wdt_period and cfg.wdt_period > 0 then
        wdt_init()
    end
    -- 配置只加载一次，Traccar/APRS 使用同一 cfg，避免重复读文件
    if (cfg.traccar_host or ""):match("%S") then
        traccar_report.start_consumer(cfg, device_id)
        start_extra_cache_task()
    end
    if (cfg.aprs_callsign or ""):match("%S") then
        aprs_report.start_consumer(cfg)
    end
    if cfg.test_report_mode == 1 and cfg.test_lat and cfg.test_lon then
        log.info("GNSS", "TEST MODE: lat=" .. tostring(cfg.test_lat) .. " lon=" .. tostring(cfg.test_lon))
    end
    local moving_interval = cfg.moving_interval or 10
    local still_interval = cfg.still_interval or 300
    local still_speed_threshold = cfg.still_speed_threshold or 5
    local last_report_ts = 0
    local last_still_report_ts = 0
    local last_nofix_report_ts = 0  -- 无定位时按 still_interval 上报状态（电量/信号等）
    local last_lbs_ts = 0
    local last_aprs_ts = 0
    local last_wdt_ts = 0
    while true do
        sys.wait(1000)
        if cfg.wdt_period and cfg.wdt_period > 0 and os.time() - last_wdt_ts >= 150 then
            wdt_feed()
            last_wdt_ts = os.time()
        end
        if (cfg.flash_gpio or -1) >= 0 and is_flash_mode() then
            log.info("GNSS", "Reload asserted, exit.")
            break
        end
        gnss_read_once()
        local lat, lon = gps_data.lat, gps_data.lon
        local no_gnss = (lat == nil or lon == nil or gps_data.fix == "0")
        -- 上报测试模式：使用配置的固定坐标模拟定位，用于验证 Traccar/APRS
        if cfg.test_report_mode == 1 and cfg.test_lat and cfg.test_lon then
            lat, lon = cfg.test_lat, cfg.test_lon
            gps_data.lat, gps_data.lon = lat, lon
            gps_data.alt = cfg.test_alt
            gps_data.speed = cfg.test_speed or 0
            gps_data.track = cfg.test_course
            gps_data.accuracy = cfg.test_accuracy
            gps_data.fix = "1"
            gps_data.sats = 8
            gps_data._source = "TEST"
        end
        -- 无 GNSS 时：若配置了 lbs_interval 则尝试 LBS（不填 lbs_server 则用内置 lbsLoc2）
        if no_gnss and (cfg.lbs_interval or 0) >= 10 then
            if last_lbs_ts == 0 or (os.time() - last_lbs_ts) >= (cfg.lbs_interval or 60) then
                last_lbs_ts = os.time()
                local lbs_lat, lbs_lon, lbs_acc = get_lbs_location(cfg)
                if lbs_lat and lbs_lon then
                    gps_data.lat, gps_data.lon = lbs_lat, lbs_lon
                    gps_data.speed = 0
                    gps_data.accuracy = lbs_acc
                    gps_data._source = "LBS"
                    lat, lon = lbs_lat, lbs_lon
                end
            end
        end
        if lat and lon and gps_data.fix ~= "0" then
            gps_data._source = "GNSS"
        end
        if not lat or not lon then
            -- 无定位时仍按 still_interval 上报除定位以外的信息（电量、信号、基站等，从缓存读）
            if (os.time() - last_nofix_report_ts) >= still_interval then
                local status_payload = build_traccar_status_payload(device_id)
                traccar_report.enqueue(status_payload)
                last_nofix_report_ts = os.time()
                log.info("GNSS", "no fix, status report enqueued (still_interval)")
            end
            goto continue
        end
        if (cfg.aprs_callsign or ""):match("%S") then
            local interval = cfg.aprs_interval or 60
            if (os.time() - last_aprs_ts) >= interval then
                aprs_report.enqueue(gps_data)
                last_aprs_ts = os.time()
            end
        end
        local speed_kmh = gps_data.speed or 0
        if os.time() - last_report_ts < moving_interval then goto continue end
        last_report_ts = os.time()
        if speed_kmh <= still_speed_threshold and (os.time() - last_still_report_ts) < still_interval then
            goto continue
        end
        last_still_report_ts = os.time()
        local payload = build_traccar_payload(device_id, lat, lon)
        traccar_report.enqueue(payload)
        ::continue::
    end
    gpio.set(PIN_NET_LED, 0)
    gpio.set(PIN_GPS_POWER, 0)
    log.info("GNSS", "exit.")
end

return {
    main = main,
    VERSION = VERSION,
}
