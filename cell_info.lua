-- cell_info.lua - 获取蜂窝网络小区信息（Traccar 附加字段兼容）
-- 返回格式：mcc,mnc,lac,cellId,signalStrength
-- Air780EP 等平台需先调用 mobile.reqCellInfo() 再调用 getCellInfo()

local sys = sys

local function get_cell_info()
    local mcc, mnc, lac, cell_id, rssi = "", "", "", "", ""
    if not mobile then return "0,0,0,0,0" end
    pcall(function()
        local csq = mobile.csq and mobile.csq()
        if csq and type(csq) == "number" and csq >= 0 then rssi = tostring(csq) end
    end)
    -- LuatOS Air780EP：必须先 reqCellInfo 再 getCellInfo
    pcall(function()
        if mobile.reqCellInfo then
            mobile.reqCellInfo()
            if sys and sys.wait then sys.wait(300) end
        end
        if mobile.getCellInfo then
            local info = mobile.getCellInfo()
            if info and type(info) == "table" then
                if info.mcc then mcc = tostring(info.mcc) end
                if info.mnc then mnc = tostring(info.mnc) end
                if info.lac then lac = tostring(info.lac) end
                if info.cid or info.ci then cell_id = tostring(info.cid or info.ci) end
                if info.rssi and rssi == "" then rssi = tostring(info.rssi) end
            end
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
