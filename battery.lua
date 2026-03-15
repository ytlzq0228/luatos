-- battery.lua - 供电电压采集（Air780EP 方案：ADC0，供电电压=ADC电压*273300/3300，最大90V）
-- 根据 battery_type 选用对应 SOC 曲线，在两区间电压间线性插值得到 SOC

local ADC_CH_POWER = 0  -- ADC0
local VOLTAGE_RATIO_NUM = 273300
local VOLTAGE_RATIO_DEN = 3300
local VOLTAGE_MAX_V = 90

-- SOC 曲线：{ {mv, soc}, ... } 按电压升序，soc 0~100；在两区间内线性插值
local SOC_CURVES = {
    -- 1、聚合物锂电池芯 1S 3.7V (Li_1S_3V7)
    Li_1S_3V7 = {
        { 2800, 0 }, { 3000, 0 }, { 3200, 2 }, { 3300, 5 }, { 3400, 8 }, { 3500, 15 },
        { 3600, 30 }, { 3700, 50 }, { 3800, 70 }, { 3900, 80 }, { 4000, 90 }, { 4100, 95 }, { 4200, 100 },
    },
    -- 2、3串聚合物锂电池芯 12V (Li_3S_12V)
    Li_3S_12V = {
        { 8400, 0 }, { 9000, 0 }, { 9600, 2 }, { 9900, 5 }, { 10200, 8 }, { 10500, 15 },
        { 10800, 30 }, { 11100, 50 }, { 11400, 70 }, { 11700, 80 }, { 12000, 90 }, { 12300, 95 }, { 12600, 100 },
    },
    -- 3、13串动力18650 48V (Li_13S_48V)
    Li_13S_48V = {
        { 36400, 0 }, { 39000, 0 }, { 41600, 2 }, { 42900, 5 }, { 44200, 8 }, { 45500, 15 },
        { 46800, 30 }, { 48100, 50 }, { 49400, 70 }, { 50700, 80 }, { 52000, 90 }, { 53300, 95 }, { 54600, 100 },
    },
    -- 4、4串12V铅酸 48V (SLA_4S_48V)
    SLA_4S_48V = {
        { 40000, 0 }, { 46400, 0 }, { 47600, 25 }, { 48800, 50 }, { 50000, 75 }, { 51200, 100 }, { 52000, 100 },
    },
    -- 5、5串12V铅酸 60V (SLA_5S_60V)
    SLA_5S_60V = {
        { 50000, 0 }, { 58000, 0 }, { 59500, 25 }, { 61000, 50 }, { 62500, 75 }, { 64000, 100 }, { 65000, 100 },
    },
}

local DEFAULT_BATTERY_TYPE = "Li_1S_3V7"

-- 根据电压 mv 和曲线点表，在相邻两点间线性插值得到 SOC (0~100)
local function voltage_to_soc(mv, curve)
    if not curve or #curve == 0 then return nil end
    if mv <= curve[1][1] then return math.max(0, curve[1][2]) end
    if mv >= curve[#curve][1] then return math.min(100, curve[#curve][2]) end
    for i = 1, #curve - 1 do
        local v0, s0 = curve[i][1], curve[i][2]
        local v1, s1 = curve[i + 1][1], curve[i + 1][2]
        if mv >= v0 and mv <= v1 then
            local ratio = (v1 > v0) and ((mv - v0) / (v1 - v0)) or 0
            return s0 + (s1 - s0) * ratio
        end
    end
    return curve[#curve][2]
end

-- 根据配置 battery_type 取曲线并计算 SOC；无配置或未知类型时用 Li_1S_3V7
local function get_soc_curve_type()
    local config = require("config")
    local t = (config.get_raw_value and config.get_raw_value("battery_type")) or DEFAULT_BATTERY_TYPE
    t = (t and tostring(t):match("^%s*(.-)%s*$")) or DEFAULT_BATTERY_TYPE
    return (SOC_CURVES[t] and t) or DEFAULT_BATTERY_TYPE
end

local function get_voltage_mv()
    if not adc or not adc.open then return nil end
    if not adc.open(ADC_CH_POWER) then return nil end
    local adc_mv = adc.get(ADC_CH_POWER)  -- LuatOS: mV
    adc.close(ADC_CH_POWER)
    if not adc_mv or type(adc_mv) ~= "number" then return nil end
    -- 供电电压(mV) = ADC读数(mV) * 273300 / 3300，最大90V
    local supply_mv = math.floor(adc_mv * VOLTAGE_RATIO_NUM / VOLTAGE_RATIO_DEN)
    if supply_mv > VOLTAGE_MAX_V * 1000 then supply_mv = VOLTAGE_MAX_V * 1000 end
    return supply_mv
end

-- 返回 batteryLevel (0~100，按所选电池曲线插值 SOC), batteryVoltage (V)
function get_battery()
    local mv = get_voltage_mv()
    if not mv then return nil, nil end
    local v = math.floor(mv / 10) / 100  -- 保留两位小数
    local curve_type = get_soc_curve_type()
    local curve = SOC_CURVES[curve_type]
    local level = voltage_to_soc(mv, curve)
    if level ~= nil then level = math.floor(level * 10 + 0.5) / 10 end  -- 保留一位小数
    return level, v
end

return {
    get_battery = get_battery,
    get_voltage_mv = get_voltage_mv,
}
