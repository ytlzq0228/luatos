"""
LuatOS 自建 FOTA 服务器
- 需要升级: GET /upgrade?version=x.y.z 返回 200，body 为 .ota/.bin 完整内容
- 不需要升级: 返回 304
"""
import logging
import os
import re
from pathlib import Path

from fastapi import FastAPI, Query
from fastapi.responses import FileResponse, PlainTextResponse, Response

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

app = FastAPI(title="LuatOS FOTA", description="自建 FOTA 升级服务")

BASE_DIR = Path(__file__).resolve().parent
FIRMWARE_DIR = BASE_DIR / "firmware"
LATEST_VERSION_ENV = os.environ.get("FOTA_LATEST_VERSION")
# 打包版本中的“大版本”号，与设备 x.y.z 中的 x、z 组成 大版本.x.z 与文件名一致。默认 2024，可用 FOTA_BIG_VERSION 覆盖。
BIG_VERSION = int(os.environ.get("FOTA_BIG_VERSION", "2024"))

# 文件名前缀，后面紧跟的即为版本号，如 LuatOS_Location_Reporter_2024.1.1_LuatOS-SoC_Air780EP.bin → 2024.1.1
VERSION_PREFIX = "LuatOS_Location_Reporter_"


def parse_version(v: str) -> tuple:
    """将版本字符串转为整数元组便于比较，支持任意段数如 2024.1.1 或 1.0.2。"""
    if not v or not isinstance(v, str):
        return (0,)
    try:
        parts = [int(x) for x in v.strip().split(".") if x.isdigit()]
        return tuple(parts) if parts else (0,)
    except (ValueError, AttributeError):
        return (0,)


def extract_version_from_stem(stem: str) -> str | None:
    """从文件名 stem 中按前缀解析版本号。前缀后到下一个 _ 之间为版本，如 2024.1.1。"""
    if not stem.startswith(VERSION_PREFIX):
        return None
    rest = stem[len(VERSION_PREFIX):]
    idx = rest.find("_")
    ver = rest[:idx] if idx >= 0 else rest
    if not ver or not re.match(r"^[\d.]+$", ver):
        return None
    return ver


def get_latest_firmware_path() -> Path | None:
    """在 firmware 目录下选取版本号最大的 .ota/.bin 文件；空目录或无法解析出合法版本时返回 None。"""
    single = os.environ.get("FOTA_LATEST_FILE")
    if single:
        p = BASE_DIR / single if not Path(single).is_absolute() else Path(single)
        if p.is_file():
            return p
    if not FIRMWARE_DIR.is_dir():
        return None
    files = list(FIRMWARE_DIR.glob("*.ota")) + list(FIRMWARE_DIR.glob("*.bin"))
    candidates = []
    for f in files:
        if not f.is_file():
            continue
        ver_str = extract_version_from_stem(f.stem)
        if ver_str:
            candidates.append((f, ver_str))
    if not candidates:
        return None
    best = max(candidates, key=lambda x: parse_version(x[1]))
    return best[0]


def get_latest_version() -> str | None:
    """当前服务器最新版本号。环境变量优先；否则从 firmware 中版本最大的文件解析；无则 None。"""
    if LATEST_VERSION_ENV:
        return LATEST_VERSION_ENV.strip()
    path = get_latest_firmware_path()
    if not path:
        return None
    return extract_version_from_stem(path.stem)


def device_version_to_build_tuple(device_ver: str) -> tuple:
    """
    设备上报版本为 x.y.z（如 1.0.2），打包文件版本为大版本.x.z（如 2024.1.2）。
    将设备版本转为与打包版本可比较的元组：(BIG_VERSION, x, z)。
    """
    parts = parse_version(device_ver)
    if len(parts) >= 3:
        return (BIG_VERSION, parts[0], parts[2])
    if len(parts) == 2:
        return (BIG_VERSION, parts[0], 0)
    if len(parts) == 1:
        return (BIG_VERSION, parts[0], 0)
    return (BIG_VERSION, 0, 0)


@app.get("/")
async def root():
    return {"service": "LuatOS FOTA", "usage": "GET /upgrade?version=x.y.z"}


@app.get("/upgrade")
async def upgrade(
    version: str = Query(..., description="设备当前版本，如 1.0.1 (x.y.z)"),
    imei: str = Query("", description="设备 IMEI，可选"),
):
    logger.info("upgrade request: device_version=%s (x.y.z) imei=%s", version, imei or "(none)")
    latest_ver = get_latest_version()
    firmware_path = get_latest_firmware_path()
    if not latest_ver or not firmware_path or not firmware_path.is_file():
        logger.warning("no firmware: latest_ver=%s path=%s", latest_ver, firmware_path)
        return PlainTextResponse("no firmware configured", status_code=503)
    # 设备版本 1.0.2 → (2024, 1, 2)；打包文件版本 2024.1.2 → (2024, 1, 2)，用同一规则比较
    device_tuple = device_version_to_build_tuple(version)
    server_tuple = parse_version(latest_ver)
    logger.info("server latest_version=%s file=%s size=%s bytes", latest_ver, firmware_path.name, firmware_path.stat().st_size)
    logger.info("version compare: device %s -> build tuple %s, server file tuple %s", version, device_tuple, server_tuple)
    if device_tuple >= server_tuple:
        logger.info("already latest: device %s (build %s) >= server %s -> 304", version, device_tuple, latest_ver)
        return Response(status_code=304)  # 304 不允许有 body，否则会触发 Content-Length 错误
    logger.info("upgrade: device %s (build %s) < server %s -> 200, sending %s (%s bytes)", version, device_tuple, latest_ver, firmware_path.name, firmware_path.stat().st_size)
    return FileResponse(
        path=firmware_path,
        media_type="application/octet-stream",
        filename=firmware_path.name,
    )


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.on_event("startup")
async def startup_log():
    """启动时打印固件目录与当前最新版本，便于排查。"""
    logger.info("FOTA server starting, firmware_dir=%s", FIRMWARE_DIR)
    logger.info("device version mapping: x.y.z -> build %s.x.z (set FOTA_BIG_VERSION to override)", BIG_VERSION)
    if LATEST_VERSION_ENV:
        logger.info("FOTA_LATEST_VERSION=%s (env)", LATEST_VERSION_ENV)
    if not FIRMWARE_DIR.is_dir():
        logger.warning("firmware dir not found or not a directory")
    else:
        files = list(FIRMWARE_DIR.glob("*.ota")) + list(FIRMWARE_DIR.glob("*.bin"))
        logger.info("firmware files count: %s", len(files))
        for f in sorted(files, key=lambda x: x.name):
            ver = extract_version_from_stem(f.stem)
            logger.info("  %s -> version=%s size=%s", f.name, ver or "(no version)", f.stat().st_size if f.is_file() else "?")
        path = get_latest_firmware_path()
        ver = get_latest_version()
        logger.info("selected latest: path=%s version=%s", path.name if path else None, ver)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=10223)
