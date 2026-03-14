-- main.lua - LuatOS 入口：加电直接运行，无 PowerKey/OLED
-- 主逻辑在 gnss_reporter.lua
-- PROJECT/VERSION 为 LuatOS 必须，用于项目管理与远程升级

PROJECT = "LuatOS_Location_Reporter"
VERSION = "1.0.7"
PRODUCT_KEY = "bcqHdN1S0u7dGtzgqc0zzovgea3fiU0z"
-- http://iot.openluat.com/api/site/firmware_upgrade?project_key=bcqHdN1S0u7dGtzgqc0zzovgea3fiU0z&firmware_name=LuatOS_Location_Reporter_LuatOS-SoC_Air780EP&version=2024.1.1&imei=864865088538047


sys = require("sys")
pcall(require, "sysplus")   -- http 依赖
local gnss_reporter = require("gnss_reporter")

sys.taskInit(function()
    gnss_reporter.main()
end)

sys.run()
