-- traccar_report.lua - Traccar 位置上报（生产-消费异步 + 持久化）
-- 主程序只调用 enqueue(payload)；本模块维护队列与消费者/备份任务。

local log = log
local sys = sys
local TRACCAR_CACHE_FILE = "/traccar_cache.txt"
local BACKUP_INTERVAL_MS = 30 * 1000
local RETRY_BACKOFF_BASE_SEC = 5
local SEND_OK = true
local SEND_RETRY = "retry"
local RETRYABLE_HTTP = {400, 408, 429, 500, 502, 503, 504}

local queue = {}
local consumer_params = nil  -- {host, port, device_id, timeout_s, max_backoff}
local queue_max = 200

local cmd_osmand = require("cmd_osmand")

local function load_config()
    local ok, cfg = pcall(require("config").load_config)
    if not ok or not cfg then
        return { traccar_host = "", traccar_port = 5055, traccar_max_backoff = 60 }
    end
    return {
        traccar_host = cfg.traccar_host or "",
        traccar_port = cfg.traccar_port or 5055,
        traccar_max_backoff = cfg.traccar_max_backoff or 60,
    }
end

local function build_query(device_id, payload)
    local t = {"id=" .. tostring(device_id)}
    for k, v in pairs(payload) do
        if k ~= "id" and v ~= nil and v ~= "" then
            t[#t + 1] = tostring(k) .. "=" .. tostring(v)
        end
    end
    return table.concat(t, "&")
end

local function url_encode(s)
    if not s then return "" end
    s = tostring(s):gsub("\r\n", "\n"):gsub("\r", "\n")
    return (s:gsub("%%", "%%25"):gsub("&", "%%26"):gsub("=", "%%3D"):gsub(" ", "%%20"):gsub("\n", "%%0A"))
end

-- 仅上报指令执行结果：只带 id 与 lastCmdResult
local function send_cmd_result(host, port, device_id, last_cmd_result, timeout_s)
    timeout_s = timeout_s or 10
    local qs = "id=" .. tostring(device_id) .. "&lastCmdResult=" .. url_encode(last_cmd_result)
    local url = "http://" .. host .. ":" .. tostring(port) .. "/?" .. qs
    local host_header = host .. ":" .. tostring(port)
    local headers = {
        ["Host"] = host_header,
        ["User-Agent"] = "LuatOS-GNSS-Reporter/1.0",
        ["Connection"] = "close",
    }
    local code
    local ok, err = pcall(function()
        local r = http.request("GET", url, headers, nil, {timeout = timeout_s * 1000})
        if r and r.wait then
            code = r.wait()
        else
            err = "http.request no wait"
        end
    end)
    if ok and code and (code == 200 or code == 204) then
        log.info("Traccar", "Cmd result reported: " .. tostring(last_cmd_result):sub(1, 80))
        return true
    end
    log.warn("Traccar", "Report cmd result failed: " .. tostring(err or code))
    return false
end

local function send_position(host, port, device_id, payload, timeout_s)
    timeout_s = timeout_s or 10
    local qs = build_query(device_id, payload)
    local url = "http://" .. host .. ":" .. tostring(port) .. "/?" .. qs
    -- 显式 Host/User-Agent/Connection，减轻 HAProxy 等反向代理 502（连接复用异常时用短连接）
    local host_header = host .. ":" .. tostring(port)
    local headers = {
        ["Host"] = host_header,
        ["User-Agent"] = "LuatOS-GNSS-Reporter/1.0",
        ["Connection"] = "close",
    }
    -- 打印 Traccar HTTP 请求（便于调试及确认是否能收到服务器下发的指令）
    log.info("Traccar", "[REQ] GET " .. (url:sub(1, 120) .. (url:len() > 120 and "..." or "")))
    log.info("Traccar", "[REQ] Headers: Host=" .. host_header .. " User-Agent=LuatOS-GNSS-Reporter/1.0 Connection=close")
    local code, resp_headers, body
    local ok, err = pcall(function()
        local r = http.request("GET", url, headers, nil, {timeout = timeout_s * 1000})
        if r and r.wait then
            code, resp_headers, body = r.wait()
        else
            err = "http.request no wait"
        end
    end)
    -- 兼容部分环境 r.wait() 只返回 (code, body)：此时 resp_headers 实为 body
    if body == nil and type(resp_headers) == "string" then
        body = resp_headers
        resp_headers = nil
    end
    -- 仅当响应带指令 body 时打印响应与指令
    if body and body ~= "" then
        log.info("Traccar", "[RESP] code=" .. tostring(code))
        if resp_headers and type(resp_headers) == "table" then
            for k, v in pairs(resp_headers) do
                log.info("Traccar", "[RESP] Header: " .. tostring(k) .. "=" .. tostring(v))
            end
        elseif resp_headers and resp_headers ~= "" and type(resp_headers) ~= "string" then
            log.info("Traccar", "[RESP] Headers: " .. tostring(resp_headers))
        end
        log.info("Traccar", "[RESP] body(len=" .. tostring(#body) .. "): " .. (body:sub(1, 512) .. (#body > 512 and "..." or "")))
        log.info("Traccar", "[RESP] server command (raw): " .. (body:sub(1, 256) .. (#body > 256 and "..." or "")))
        local last_result, need_reboot = cmd_osmand.execute(body)
        log.info("Traccar", "[CMD] LastCmdResult=" .. tostring(last_result) .. " RebootRequest=" .. tostring(need_reboot))
        send_cmd_result(host, port, device_id, last_result, timeout_s)
        if not ok or not code then
            return SEND_RETRY, last_result, need_reboot
        end
        if code < 0 then
            return SEND_RETRY, last_result, need_reboot
        end
        if code == 200 or code == 204 then
            return SEND_OK, last_result, need_reboot
        end
        return SEND_RETRY, last_result, need_reboot
    end
    if not ok or not code then
        log.error("Traccar", "send_position error: " .. tostring(err or code or "unknown"))
        return SEND_RETRY
    end
    if code < 0 then
        log.warn("Traccar", "http result code=" .. tostring(code) .. " (e.g. -4=conn fail -8=timeout)")
        return SEND_RETRY
    end
    if code == 200 or code == 204 then return SEND_OK end
    for _, c in ipairs(RETRYABLE_HTTP) do
        if code == c then
            log.warn("Traccar", "server code=" .. tostring(code) .. " body=" .. tostring(body and body:sub(1, 80) or ""))
            return SEND_RETRY
        end
    end
    log.error("Traccar", "send_position not retryable: " .. tostring(code) .. " " .. tostring(body))
    return false
end

local function cache_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function backup_loop()
    while true do
        sys.wait(BACKUP_INTERVAL_MS)
        local copy = {}
        for i = 1, #queue do copy[i] = queue[i] end
        pcall(function()
            local f = io.open(TRACCAR_CACHE_FILE, "w")
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
        if not consumer_params or #queue == 0 then goto continue end
        local host, port, device_id, timeout_s, max_backoff = 
            consumer_params.host, consumer_params.port, consumer_params.device_id,
            consumer_params.timeout_s or 10, consumer_params.max_backoff or 60
        local item = table.remove(queue, 1)
        if not item then goto continue end
        local next_ts = item.next_ts or 0
        if next_ts > 0 and os.time() < next_ts then
            table.insert(queue, item)
            goto continue
        end
        local payload = item.payload or {}
        local r, cmd_result, need_reboot = send_position(host, port, device_id, payload, timeout_s)
        if r == SEND_OK then
            log.info("Traccar", "Sent " .. tostring(payload.lat) .. " " .. tostring(payload.lon))
            if need_reboot then
                log.info("Traccar", "Reboot requested, rebooting...")
                pcall(function()
                    if rtos and rtos.reboot then rtos.reboot() end
                end)
            end
        elseif r == SEND_RETRY then
            item.attempts = (item.attempts or 0) + 1
            item.next_ts = os.time() + math.min(max_backoff, item.attempts * RETRY_BACKOFF_BASE_SEC)
            table.insert(queue, item)
            log.warn("Traccar", "retry later, backoff " .. tostring(item.next_ts - os.time()))
            if need_reboot then
                log.info("Traccar", "Reboot requested, rebooting...")
                pcall(function()
                    if rtos and rtos.reboot then rtos.reboot() end
                end)
            end
        end
        ::continue::
    end
end

function start_consumer(traccar_cfg, device_id)
    local host = (traccar_cfg.traccar_host or ""):gsub("^%s*(.-)%s*$", "%1")
    if host == "" then return end
    consumer_params = {
        host = host,
        port = traccar_cfg.traccar_port or 5055,
        device_id = device_id,
        timeout_s = 10,
        max_backoff = traccar_cfg.traccar_max_backoff or 60,
    }
    if cache_exists(TRACCAR_CACHE_FILE) then
        local f = io.open(TRACCAR_CACHE_FILE, "r")
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
    sys.taskInit(consumer_loop)
    sys.taskInit(backup_loop)
    log.info("Traccar", "consumer started")
end

function enqueue(payload)
    if not consumer_params or #queue >= queue_max then return end
    table.insert(queue, { payload = payload, attempts = 0, next_ts = 0 })
    if payload.lat and payload.lon then
        log.debug("Traccar", "Cached " .. tostring(payload.lat) .. " " .. tostring(payload.lon))
    end
end

return {
    load_config = load_config,
    start_consumer = start_consumer,
    enqueue = enqueue,
}
