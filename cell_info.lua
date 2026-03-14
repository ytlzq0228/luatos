-- cell_info.lua - 获取蜂窝网络小区信息（Traccar 附加字段兼容）
-- 返回格式：mcc,mnc,lac,cellId,signalStrength
-- LuatOS 从 2023.06.20 起需先 mobile.reqCellInfo(timeout)，再等待 CELL_INFO_UPDATE 后 getCellInfo()
-- 文档: https://wiki.luatos.com/api/mobile.html

local sys = sys

-- 从 getCellInfo 返回的 table/array 中取第一个小区或单条记录
local function parse_cell_info(info)
    local mcc, mnc, lac, cell_id, rssi = "", "", "", "", ""
    if not info or type(info) ~= "table" then return mcc, mnc, lac, cell_id, rssi end
    -- 可能是数组（多小区）或单条表
    local cell = info
    if info[1] then cell = info[1] end
    if cell.mcc then mcc = tostring(cell.mcc) end
    if cell.mnc then mnc = tostring(cell.mnc) end
    if cell.lac then lac = tostring(cell.lac) end
    if cell.cid or cell.ci then cell_id = tostring(cell.cid or cell.ci) end
    if cell.rssi then rssi = tostring(cell.rssi) end
    return mcc, mnc, lac, cell_id, rssi
end

local function get_cell_info()
    local mcc, mnc, lac, cell_id, rssi = "", "", "", "", ""
    if not mobile then return "0,0,0,0,0" end
    pcall(function()
        local csq = mobile.csq and mobile.csq()
        if csq and type(csq) == "number" and csq >= 0 then rssi = tostring(csq) end
    end)
    -- 文档要求：先 reqCellInfo(timeout)，再等待 CELL_INFO_UPDATE 再 getCellInfo
    pcall(function()
        if not mobile.reqCellInfo or not mobile.getCellInfo then return end
        -- 发起查询，超时 15 秒（文档：最少 5，最高 60）
        mobile.reqCellInfo(15)
        -- 等待基站数据就绪事件，最多等 16 秒
        if sys and sys.waitUntil then
            sys.waitUntil("CELL_INFO_UPDATE", 16000)
        elseif sys and sys.wait then
            sys.wait(2000)
        end
        local info = mobile.getCellInfo()
        if info and type(info) == "table" then
            local m, n, l, c, r = parse_cell_info(info)
            if m ~= "" then mcc = m end
            if n ~= "" then mnc = n end
            if l ~= "" then lac = l end
            if c ~= "" then cell_id = c end
            if r ~= "" and rssi == "" then rssi = r end
        end
    end)
    -- 无数据时填 0，不留空，避免 Traccar 解析异常
    local a = (mcc == "" or not mcc) and "0" or mcc
    local b = (mnc == "" or not mnc) and "0" or mnc
    local c = (lac == "" or not lac) and "0" or lac
    local d = (cell_id == "" or not cell_id) and "0" or cell_id
    local e = (rssi == "" or not rssi) and "0" or rssi
    return a .. "," .. b .. "," .. c .. "," .. d .. "," .. e
end

return {
    get_cell_info = get_cell_info,
}
