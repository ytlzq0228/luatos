-- main.lua - LuatOS 入口：加电直接运行，无 PowerKey/OLED
-- 主逻辑在 gnss_reporter.lua
-- PROJECT/VERSION 为 LuatOS 必须，用于项目管理与远程升级

PROJECT = "Quectel_Location_Reporter"
VERSION = "1.0.0"

sys = require("sys")
pcall(require, "sysplus")   -- http 依赖
local gnss_reporter = require("gnss_reporter")

sys.taskInit(function()
    gnss_reporter.main()
end)

sys.run()
