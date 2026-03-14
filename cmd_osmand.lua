-- cmd_osmand.lua - Osmand 协议指令解析与执行
-- 指令来源：Traccar HTTP 响应 body；执行结果返回 LastCmdResult 与 RebootRequest

local log = log
local config = require("config")

-- 去除首尾空白
local function trim(s)
    if not s or type(s) ~= "string" then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

-- 解析单条指令，返回 { cmd, key, value } 或 { cmd = "SET", pairs = { {key, value}, ... } } 或 nil
-- SET xxx=yyy 或 SET k1=v1 k2=v2 k3=v3（多组用空格分隔，value 不含空格）
-- GET xxx
-- DEL xxx
-- REBOOT
local function parse(cmd_str)
    if not cmd_str or type(cmd_str) ~= "string" then return nil end
    cmd_str = trim(cmd_str)
    if cmd_str == "" then return nil end

    if cmd_str:upper() == "REBOOT" then
        return { cmd = "REBOOT", key = nil, value = nil }
    end

    local set_prefix = cmd_str:match("^[Ss][Ee][Tt]%s+(.+)$")
    if set_prefix then
        set_prefix = trim(set_prefix)
        local pairs_list = {}
        for k, v in set_prefix:gmatch("([^=]+)=([^%s]*)") do
            k, v = trim(k), trim(v)
            if k and k ~= "" then
                pairs_list[#pairs_list + 1] = { key = k, value = v }
            end
        end
        if #pairs_list > 0 then
            return { cmd = "SET", pairs = pairs_list }
        end
        -- 兼容单组未匹配到：按整段 key=value 再试一次（value 可含空格）
        local k, v = set_prefix:match("^([^=]+)=(.*)$")
        if k then
            return { cmd = "SET", pairs = { { key = trim(k), value = trim(v) } } }
        end
        return nil
    end

    local get_prefix = cmd_str:match("^[Gg][Ee][Tt]%s+(.+)$")
    if get_prefix then
        local k = trim(get_prefix)
        if k ~= "" then
            return { cmd = "GET", key = k, value = nil }
        end
        return nil
    end

    local del_prefix = cmd_str:match("^[Dd][Ee][Ll]%s+(.+)$")
    if del_prefix then
        local k = trim(del_prefix)
        if k ~= "" then
            return { cmd = "DEL", key = k, value = nil }
        end
        return nil
    end

    return nil
end

-- 执行单条指令，返回 (LastCmdResult, RebootRequest)
-- RebootRequest: SET/DEL 成功为 true，否则 false；GET 恒为 false；REBOOT 为 true
local function execute_one(parsed)
    if not parsed then
        return "UNKNOWN CMD", false
    end

    local cmd = parsed.cmd
    local key, value = parsed.key, parsed.value
    local pairs_list = parsed.pairs

    if cmd == "REBOOT" then
        return "REBOOT OK", true
    end

    if cmd == "SET" then
        if not pairs_list or #pairs_list == 0 then
            return "SET = ERR", false
        end
        local ok_all = true
        local parts = {}
        for _, p in ipairs(pairs_list) do
            local k, v = p.key, p.value
            if not k or k == "" then ok_all = false break end
            local ok = config.set_raw_key(k, v or "")
            if ok then
                parts[#parts + 1] = k .. "=" .. tostring(v or "")
            else
                ok_all = false
                parts[#parts + 1] = k .. "= ERR"
                break
            end
        end
        local result = "SET " .. table.concat(parts, " ") .. (ok_all and " OK" or "")
        return result, ok_all
    end

    if cmd == "GET" then
        if key and key:upper() == "ALL" then
            local cfg = config.get_all_raw()
            local parts = {}
            local keys = {}
            for k in pairs(cfg) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do
                parts[#parts + 1] = k .. "=" .. tostring(cfg[k] or "")
            end
            return "GET ALL " .. table.concat(parts, " ") .. " OK", false
        end
        local v = config.get_raw_value(key)
        if v ~= nil then
            return "GET " .. key .. "=" .. tostring(v) .. " OK", false
        end
        return "GET " .. key .. "= ERR", false
    end

    if cmd == "DEL" then
        if key == "traccar_host" or key == "traccar_port" then
            return "DEL " .. key .. "= FORBIDDEN", false
        end
        local ok, removed = config.del_raw_key(key)
        if ok then
            return "DEL " .. key .. "=" .. tostring(removed or "") .. " OK", true
        end
        return "DEL " .. key .. "= ERR", false
    end

    return "UNKNOWN CMD", false
end

-- 对外接口：执行指令原文（可多行，只执行第一行有效指令）
-- 返回 LastCmdResult (string), RebootRequest (boolean)
function execute(cmd_str)
    if not cmd_str or type(cmd_str) ~= "string" or trim(cmd_str) == "" then
        return "EMPTY", false
    end
    local first_line = cmd_str:match("^([^\r\n]+)") or trim(cmd_str)
    first_line = trim(first_line)
    if first_line == "" then
        return "EMPTY", false
    end
    local parsed = parse(first_line)
    local result, reboot = execute_one(parsed)
    if not parsed then
        result = "UNKNOWN: " .. (first_line:sub(1, 64))
    end
    return result, reboot
end

return {
    parse = parse,
    execute = execute,
}
