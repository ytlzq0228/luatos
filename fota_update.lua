-- fota_update.lua - LuatOS 远程升级（可选）
-- 合宙 LuatOS 常用 OTA 方式：通过云平台或 http.update 等，此处仅占位；
-- 若固件支持可在此调用对应 OTA 接口并重启。

local function run_fota_with_progress(log_cb)
    log_cb = log_cb or log.info
    log_cb("FOTA", "LuatOS OTA: please use Luatools or cloud OTA.")
end

return {
    run_fota_with_progress = run_fota_with_progress,
}
