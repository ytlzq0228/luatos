-- aprs_report.lua - APRS 位置上报（生产-消费异步 + 持久化）
-- 主程序只调用 enqueue(gps_data)；本模块维护队列与消费者/备份任务。

local log = log
local sys = sys
local socket = socket
local sysplus = sysplus
local libnet_ok, libnet = pcall(require, "libnet")
if not libnet_ok then libnet = nil end
local APRS_CACHE_FILE = "/aprs_cache.txt"
local APRS_BACKUP_INTERVAL_MS = 30 * 1000
local APRS_RETRY_BACKOFF_BASE_SEC = 5
local APRS_MAX_BACKOFF = 60
local queue_max = 100

local queue = {}
local aprs_cfg = nil

local function load_config()
    local ok, cfg = pcall(require("config").load_config)
    if not ok or not cfg then
        return { aprs_callsign = "", aprs_ssid = "", aprs_passcode = "", aprs_host = "rotate.aprs.net",
                 aprs_port = 14580, aprs_interval = 60, aprs_message = "", aprs_icon = ">" }
    end
    return {
        aprs_callsign = cfg.aprs_callsign or "",
        aprs_ssid = cfg.aprs_ssid or "",
        aprs_passcode = cfg.aprs_passcode or "",
        aprs_host = cfg.aprs_host or "rotate.aprs.net",
        aprs_port = cfg.aprs_port or 14580,
        aprs_interval = cfg.aprs_interval or 60,
        aprs_message = cfg.aprs_message or "",
        aprs_icon = (cfg.aprs_icon or ">"):sub(1, 1),
    }
end

local function deg_to_aprs_lat(deg)
    if deg == nil then return "0000.00N" end
    local d = math.floor(math.abs(deg))
    local m = (math.abs(deg) - d) * 60
    local s = string.format("%02d%05.2f", d, m)
    return s .. (deg >= 0 and "N" or "S")
end

local function deg_to_aprs_lon(deg)
    if deg == nil then return "00000.00E" end
    local d = math.floor(math.abs(deg))
    local m = (math.abs(deg) - d) * 60
    local s = string.format("%03d%05.2f", d, m)
    return s .. (deg >= 0 and "E" or "W")
end

local function time_aprs()
    local t = os.date("*t")
    if t then
        return string.format("%02d%02d%02d", t.hour or 0, t.min or 0, t.sec or 0)
    end
    return "000000"
end

local function build_aprs_frame(gps_data, cfg)
    local lat, lon = gps_data.lat, gps_data.lon
    if lat == nil or lon == nil then return nil end
    local lat_aprs = deg_to_aprs_lat(lat)
    local lon_aprs = deg_to_aprs_lon(lon)
    local icon = cfg.aprs_icon or ">"
    local course = math.floor((tonumber(gps_data.track) or 0) + 0.5) % 360
    local course_str = string.format("%03d", course)
    local speed_kmh = tonumber(gps_data.speed) or 0
    local speed_kn = speed_kmh / 1.852
    local speed_str = string.format("%03d", math.min(999, math.floor(speed_kn + 0.5)))
    local alt_m = tonumber(gps_data.alt) or 0
    local alt_ft = math.floor(alt_m * 3.28084 + 0.5)
    local alt_str = tostring(math.max(0, math.min(999999, alt_ft)))
    local tail = " APRS by LuatOS at local time " .. time_aprs()
    if (cfg.aprs_message or ""):match("%S") then
        tail = tail .. " " .. (cfg.aprs_message or ""):gsub("^%s*(.-)%s*$", "%1")
    end
    local body = "!" .. lat_aprs .. "/" .. lon_aprs .. icon .. course_str .. "/" .. speed_str .. "/A=" .. alt_str .. tail
    return body
end

-- LuatOS：优先用 libnet 同步连接（需 sysplus.taskInitEx 创建的任务）；否则回退到 socket 异步
local APRS_TASK_NAME = "APRS"

local function send_aprs(cfg, frame_body)
    local callsign = (cfg.aprs_callsign or ""):gsub("^%s*(.-)%s*$", "%1"):upper()
    if callsign == "" or not frame_body then return false end
    local ssid = (cfg.aprs_ssid or ""):gsub("^%s*(.-)%s*$", "%1"):upper()
    local source = (ssid ~= "" and ssid) or callsign
    local host = cfg.aprs_host or "rotate.aprs.net"
    local port = tonumber(cfg.aprs_port) or 14580
    local passcode = tostring(cfg.aprs_passcode or ""):gsub("^%s*(.-)%s*$", "%1")
    local login_line = "user " .. callsign .. " pass " .. passcode .. " vers LuatOS-APRS 1.0\r\n"
    local packet_line = source .. ">APRS,TCPIP*:" .. frame_body .. "\r\n"
    local ok, err = pcall(function()
        if not socket or not socket.create then error("socket.create nil") end
        local ctrl

        -- 优先 libnet 同步连接（必须在由 sysplus.taskInitEx(APRS_TASK_NAME, ...) 创建的任务中调用）
        if libnet and libnet.connect and sysplus then
            ctrl = socket.create(nil, APRS_TASK_NAME)
            if not ctrl then error("socket.create failed") end
            socket.config(ctrl)
            if not libnet.connect(APRS_TASK_NAME, 8000, ctrl, host, port) then
                socket.close(ctrl)
                error("APRS connect timeout")
            end
            sys.wait(200)
            libnet.tx(APRS_TASK_NAME, 3000, ctrl, login_line)
            sys.wait(150)
            libnet.tx(APRS_TASK_NAME, 3000, ctrl, packet_line)
            sys.wait(400)
            socket.close(ctrl)
            return
        end

        -- 回退：socket 异步；EC718P 等固件回调 (ctrl, event_id, data)，连接成功时 b=33554449 或 33554452
        local CONNECT_EVENT_1 = 33554449
        local CONNECT_EVENT_2 = 33554452
        local state = { ready = false }
        local cb = function(a, b, c)
            if type(b) == "number" and (b == CONNECT_EVENT_1 or b == CONNECT_EVENT_2) then
                state.ready = true
            end
            if tostring(a) == "CONNECT" or tostring(b) == "CONNECT" or (c == true) or (b == true) then
                state.ready = true
            end
        end
        ctrl = socket.create(nil, cb)
        if not ctrl then error("socket.create failed") end
        socket.config(ctrl)
        socket.connect(ctrl, host, port)
        for _ = 1, 80 do
            sys.wait(100)
            if state.ready then break end
        end
        if not state.ready then
            socket.close(ctrl)
            error("APRS connect timeout")
        end
        sys.wait(200)
        socket.tx(ctrl, login_line)
        sys.wait(300)
        socket.tx(ctrl, packet_line)
        sys.wait(500)
        socket.close(ctrl)
    end)
    if not ok then
        log.warn("APRS", "send failed: " .. tostring(err))
    end
    return ok and not err
end

local function cache_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function backup_loop()
    while true do
        sys.wait(APRS_BACKUP_INTERVAL_MS)
        local copy = {}
        for i = 1, #queue do copy[i] = queue[i] end
        pcall(function()
            local f = io.open(APRS_CACHE_FILE, "w")
            if f then
                for _, item in ipairs(copy) do
                    f:write(json.encode(item) .. "\n")
                end
                f:close()
            end
        end)
    end
end

local function consumer_loop()
    while true do
        sys.wait(1000)
        if not aprs_cfg or #queue == 0 then goto continue end
        local item = table.remove(queue, 1)
        if not item then goto continue end
        local next_ts = item.next_ts or 0
        if next_ts > 0 and os.time() < next_ts then
            table.insert(queue, item)
            goto continue
        end
        local gps_data = item.gps_data or {}
        if gps_data.lat == nil or gps_data.lon == nil then goto continue end
        local frame_body = build_aprs_frame(gps_data, aprs_cfg)
        if not frame_body then goto continue end
        local ok = send_aprs(aprs_cfg, frame_body)
        if ok then
            log.info("APRS", "Sent " .. tostring(gps_data.lat) .. " " .. tostring(gps_data.lon))
        else
            item.attempts = (item.attempts or 0) + 1
            item.next_ts = os.time() + math.min(APRS_MAX_BACKOFF, item.attempts * APRS_RETRY_BACKOFF_BASE_SEC)
            table.insert(queue, item)
            log.warn("APRS", "retry later")
        end
        ::continue::
    end
end

function start_consumer(cfg)
    local callsign = (cfg.aprs_callsign or ""):gsub("^%s*(.-)%s*$", "%1")
    if callsign == "" then return end
    aprs_cfg = cfg
    if cache_exists(APRS_CACHE_FILE) then
        local f = io.open(APRS_CACHE_FILE, "r")
        if f then
            for line in f:lines() do
                line = line:gsub("^%s*(.-)%s*$", "%1")
                if line ~= "" then
                    local ok, item = pcall(json.decode, line)
                    if ok and item and #queue < queue_max then
                        table.insert(queue, item)
                    end
                end
            end
            f:close()
        end
    end
    -- libnet 同步连接必须在 sysplus.taskInitEx 创建的任务中运行
    if sysplus and sysplus.taskInitEx then
        sysplus.taskInitEx(APRS_TASK_NAME, consumer_loop)
    else
        sys.taskInit(consumer_loop)
    end
    sys.taskInit(backup_loop)
    log.info("APRS", "consumer started")
end

function enqueue(gps_data)
    if not aprs_cfg or gps_data.lat == nil or gps_data.lon == nil or #queue >= queue_max then return end
    table.insert(queue, { gps_data = gps_data, attempts = 0, next_ts = 0 })
end

return {
    load_config = load_config,
    start_consumer = start_consumer,
    enqueue = enqueue,
}
