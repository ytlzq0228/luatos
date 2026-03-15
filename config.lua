-- config.lua - 统一配置文件读取（Traccar / APRS / LBS 等）
-- 仅使用根目录 /config.cfg：首次运行若不存在则从源路径复制一份，后续只对该文件读写

local log = log
local CONFIG_FILE = "/config.cfg"
-- 首次复制时尝试的源路径（按顺序，找到即复制到 /config.cfg）
local SOURCE_PATHS = {"/luadb/config.cfg", "config.cfg", "/config.cfg", "/data/config.cfg", "/luatos/config.cfg"}
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

local function _read_lines(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()
    return lines
end

local function _write_lines(path, lines)
    local f = io.open(path, "w")
    if not f then return false end
    for _, line in ipairs(lines) do
        f:write(line .. "\n")
    end
    f:close()
    return true
end

-- 从行列表解析出 key=value 表（不触发 _ensure_config，避免递归）
local function _lines_to_cfg(lines)
    local cfg = {}
    for _, line in ipairs(lines or {}) do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") then
            local k, v = line:match("^([^=]+)=(.*)$")
            if k and v then
                cfg[k:match("^%s*(.-)%s*$")] = v:match("^%s*(.-)%s*$")
            end
        end
    end
    return cfg
end

-- 当 /config.cfg 已存在时，用程序包里的 cfg 做比对，补上设备中缺失的 key（程序更新后包内 cfg 可能有新 key）
local function _merge_missing_keys()
    local bundle_lines = nil
    local bundle_path = nil
    for _, path in ipairs(SOURCE_PATHS) do
        if path == CONFIG_FILE then goto next end
        local lines = _read_lines(path)
        if lines and #lines > 0 then
            bundle_lines = lines
            bundle_path = path
            break
        end
        ::next::
    end
    if not bundle_lines then return end
    local bundle_cfg = _lines_to_cfg(bundle_lines)
    local dev_lines = _read_lines(CONFIG_FILE)
    if not dev_lines then return end
    local dev_cfg = _lines_to_cfg(dev_lines)
    local added = {}
    for k, val in pairs(bundle_cfg) do
        if dev_cfg[k] == nil then
            dev_lines[#dev_lines + 1] = k .. "=" .. val
            added[#added + 1] = k
        end
    end
    if #added > 0 then
        _write_lines(CONFIG_FILE, dev_lines)
        if log and bundle_path then
            log.info("Config", "merged from " .. bundle_path .. " missing keys: " .. table.concat(added, ", "))
        end
    end
end

-- 若 /config.cfg 不存在，从第一个存在的源路径复制一份过去；若已存在则仅补全缺失的 key
local function _ensure_config()
    local f = io.open(CONFIG_FILE, "r")
    if f then
        f:close()
        _merge_missing_keys()
        return true
    end
    for _, path in ipairs(SOURCE_PATHS) do
        if path == CONFIG_FILE then goto next end
        local lines = _read_lines(path)
        if lines and #lines > 0 then
            if _write_lines(CONFIG_FILE, lines) then
                log.info("Config", "copied from " .. path .. " to " .. CONFIG_FILE)
                return true
            end
        end
        ::next::
    end
    return false
end

-- 从 /config.cfg 读取原始 key=value 表（先确保文件存在）
local function _read_raw()
    _ensure_config()
    local f = io.open(CONFIG_FILE, "r")
    if not f then return {} end
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

-- 打印从 cfg 文件读取到的所有 key=value
local function _log_cfg(cfg)
    if not cfg or not log then return end
    local keys = {}
    for k in pairs(cfg) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        log.info("Config", k .. "=" .. tostring(cfg[k]))
    end
end

-- 读取 cfg 中原始 key 的值（不经过 load_config 的转换）
function get_raw_value(key)
    local cfg = _read_raw()
    return cfg[key]
end

-- 读取 cfg 中全部 key=value（表，供 GET ALL 等使用）
function get_all_raw()
    return _read_raw()
end

-- 设置 cfg 中 key=value，不存在则追加；仅操作 /config.cfg
function set_raw_key(key, value)
    if not _ensure_config() then return false end
    local lines = _read_lines(CONFIG_FILE)
    if not lines then return false end
    local key_trim = key and key:match("^%s*(.-)%s*$")
    if not key_trim or key_trim == "" then return false end
    local new_line = key_trim .. "=" .. tostring(value)
    local found = false
    for i, line in ipairs(lines) do
        local k = line:match("^%s*([^=]+)=")
        if k and k:match("^%s*(.-)%s*$") == key_trim then
            lines[i] = new_line
            found = true
            break
        end
    end
    if not found then
        lines[#lines + 1] = new_line
    end
    return _write_lines(CONFIG_FILE, lines)
end

-- 删除 cfg 中 key；traccar_host、traccar_port 不允许删除
function del_raw_key(key)
    if key == "traccar_host" or key == "traccar_port" then return false end
    if not _ensure_config() then return false, nil end
    local lines = _read_lines(CONFIG_FILE)
    if not lines then return false, nil end
    local key_trim = key and key:match("^%s*(.-)%s*$")
    if not key_trim or key_trim == "" then return false, nil end
    local removed_value = nil
    local new_lines = {}
    for _, line in ipairs(lines) do
        local k, v = line:match("^%s*([^=]+)=(.*)$")
        if k and k:match("^%s*(.-)%s*$") == key_trim then
            removed_value = v and v:match("^%s*(.-)%s*$") or ""
        else
            new_lines[#new_lines + 1] = line
        end
    end
    if removed_value == nil then return false, nil end
    return _write_lines(CONFIG_FILE, new_lines), removed_value
end

function load_config()
    local cfg = _read_raw()
    _log_cfg(cfg)

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
        -- FOTA：配置里没有 fota_url 时用默认地址；显式写 fota_url= 留空则不请求
        fota_url = (cfg.fota_url == nil) and "http://luatos-fota.ctsdn.com:2232/upgrade" or (cfg.fota_url or ""):gsub("^%s*(.-)%s*$", "%1"),
    }
end

return {
    load_config = load_config,
    APRS_MIN_INTERVAL = APRS_MIN_INTERVAL,
    get_raw_value = get_raw_value,
    get_all_raw = get_all_raw,
    set_raw_key = set_raw_key,
    del_raw_key = del_raw_key,
}
