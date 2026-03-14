-- battery.lua - 供电电压采集（Air780EP 方案：ADC0，供电电压=ADC电压*273300/3300，最大90V）
-- 无内置电池 SOC 表时仅返回电压，batteryLevel 可选用电压估算

local ADC_CH_POWER = 0  -- ADC0
local VOLTAGE_RATIO_NUM = 273300
local VOLTAGE_RATIO_DEN = 3300
local VOLTAGE_MAX_V = 90

-- 可选：简单电压到“电量”的线性映射（用于 Traccar batteryLevel 显示，非真实 SOC）
local function voltage_to_level_mv(mv)
    if mv >= 12000 then return 100 end
    if mv <= 6000 then return 0 end
    return math.floor((mv - 6000) / 60 + 0.5)
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

-- 返回 batteryLevel (0~100 估算), batteryVoltage (V)
function get_battery()
    local mv = get_voltage_mv()
    if not mv then return nil, nil end
    local v = math.floor(mv / 10) / 100  -- 保留两位小数
    local level = voltage_to_level_mv(mv)
    return level, v
end

return {
    get_battery = get_battery,
    get_voltage_mv = get_voltage_mv,
}
