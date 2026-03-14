# LuatOS 自建 FOTA 服务器

- **需要升级**：`GET /upgrade?version=x.y.z` 返回 **200**，body 为 .ota/.bin 完整内容  
- **不需要升级**：返回 **304**

## 运行

```bash
cd "FOTA Server"
pip install -r requirements.txt
python main.py
# 或: uvicorn main:app --host 0.0.0.0 --port 2232
```

## 版本对应关系

- **设备请求**使用程序版本 **x.y.z**（如 `1.0.2`）
- **打包生成的 bin 文件名**使用 **大版本.x.z**（如 `2024.1.2`）
- 服务端将设备版本转换为 `(大版本, x, z)` 再与文件名中的版本比较。大版本默认 **2024**，可通过环境变量 `FOTA_BIG_VERSION` 修改。

## 固件文件

把 LuatOS 的 **.ota**（或 .bin）文件放到 `firmware/` 目录，文件名需含前缀与版本，如 `LuatOS_Location_Reporter_2024.1.1_LuatOS-SoC_Air780EP.bin`。  
服务器会取版本号最大的文件作为当前最新固件。

可选环境变量：

- `FOTA_BIG_VERSION`：大版本号（默认 2024），用于设备 x.y.z 与打包 大版本.x.z 的换算
- `FOTA_LATEST_VERSION`：强制指定当前最新版本号（如 `2024.1.2`）
- `FOTA_LATEST_FILE`：强制指定固件文件路径（相对项目目录或绝对路径）

## 设备端

设备请求：`GET http://luatos-fota.ctsdn.com:2232/upgrade?version=1.0.1`  
若设备版本小于服务器最新版本，则返回 200 + 固件内容；否则返回 304。
