-- config.lua - 统一配置文件读取（Traccar / APRS / LBS 等）
-- 从 config.cfg 读取 key=value，与 QuecPython 版格式兼容

-- Air780EP 常见：脚本在 /luadb/，先尝试该路径及相对路径
local CONFIG_PATHS = {"/luadb/config.cfg", "config.cfg", "/config.cfg", "/luatos/config.cfg"}
local APRS_MIN_INTERVAL = 30

local function _int_val(v, default)
    if v == nil or v == "" then return default end
    local n = tonumber(v)
    if n then return math.floor(n) end
    return default
end

local function _float_val(v, default)
    if v == nil or v == "" then return default end
    local n = tonumber(v)
    if n then return n end
    return default
end

local function _read_raw()
    for _, path in ipairs(CONFIG_PATHS) do
        local f = io.open(path, "r")
        if f then
            local cfg = {}
            for line in f:lines() do
                line = line:match("^%s*(.-)%s*$")
                if line ~= "" and not line:match("^#") then
                    local k, v = line:match("^([^=]+)=(.*)$")
                    if k and v then
                        cfg[k:match("^%s*(.-)%s*$")] = v:match("^%s*(.-)%s*$")
                    end
                end
            end
            f:close()
            return cfg
        end
    end
    return {}
end

local function load_config()
    local cfg = _read_raw()
    local raw_aprs = _int_val(cfg.aprs_interval, 60)
    local aprs_interval = math.max(APRS_MIN_INTERVAL, raw_aprs)

    return {
        -- Traccar
        traccar_host = (cfg.traccar_host or "traccar.example.com"):gsub("^%s*(.-)%s*$", "%1"),
        traccar_port = _int_val(cfg.traccar_port, 5055),
        traccar_http_timeout = _int_val(cfg.http_timeout, 10),
        traccar_max_backoff = _int_val(cfg.max_backoff, 60),
        moving_interval = _int_val(cfg.moving_interval, 10),
        still_interval = _int_val(cfg.still_interval, 300),
        still_speed_threshold = _int_val(cfg.still_speed_threshold, 5),
        flash_gpio = _int_val(cfg.flash_gpio, -1),
        network_check_timeout = _int_val(cfg.network_check_timeout, 60),
        wdt_period = _int_val(cfg.wdt_period, 60),
        -- LBS
        lbs_server = (cfg.lbs_server or ""):gsub("^%s*(.-)%s*$", "%1"),
        lbs_port = _int_val(cfg.lbs_port, 80),
        lbs_token = (cfg.lbs_token or ""):gsub("^%s*(.-)%s*$", "%1"),
        lbs_timeout = math.max(1, math.min(300, _int_val(cfg.lbs_timeout, 30))),
        lbs_profile_idx = math.max(1, math.min(3, _int_val(cfg.lbs_profile_idx, 1))),
        lbs_interval = math.max(10, _int_val(cfg.lbs_interval, 60)),
        -- APRS
        aprs_callsign = (cfg.aprs_callsign or ""):gsub("^%s*(.-)%s*$", "%1"),
        aprs_ssid = (cfg.aprs_ssid or ""):gsub("^%s*(.-)%s*$", "%1"),
        aprs_passcode = cfg.aprs_passcode or "",
        aprs_host = cfg.aprs_host or "rotate.aprs.net",
        aprs_port = _int_val(cfg.aprs_port, 14580),
        aprs_interval = aprs_interval,
        aprs_message = (cfg.aprs_message or ""):gsub("^%s*(.-)%s*$", "%1"),
        aprs_icon = (cfg.aprs_icon or ">"):sub(1, 1),
        -- 上报测试模式：1=使用固定坐标上报，用于验证 Traccar/APRS 无需真实 GNSS
        test_report_mode = _int_val(cfg.test_report_mode, 0),
        test_lat = _float_val(cfg.test_lat, nil),
        test_lon = _float_val(cfg.test_lon, nil),
        test_alt = _float_val(cfg.test_alt, 41.6),
        test_speed = _float_val(cfg.test_speed, 0),
        test_course = _float_val(cfg.test_course, 156),
        test_accuracy = _float_val(cfg.test_accuracy, 12),
    }
end

return {
    load_config = load_config,
    APRS_MIN_INTERVAL = APRS_MIN_INTERVAL,
}
