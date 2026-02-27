#!/usr/bin/env bash
set -euo pipefail

# ===============================
# Universal Web-to-API 启动脚本 (macOS/Linux)
# ===============================

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

echo
echo "========================================"
echo "  Universal Web-to-API 启动脚本"
echo "========================================"
echo

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source ".env"
  set +a
  echo "[INFO] .env 已加载"
else
  echo "[WARN] 未找到 .env，使用默认配置"
fi

APP_HOST="${APP_HOST:-127.0.0.1}"
APP_PORT="${APP_PORT:-8199}"
BROWSER_PORT="${BROWSER_PORT:-9222}"
HEADLESS="${HEADLESS:-true}"
PROXY_ENABLED="${PROXY_ENABLED:-false}"
PROXY_ADDRESS="${PROXY_ADDRESS:-}"
PROXY_BYPASS="${PROXY_BYPASS:-localhost,127.0.0.1}"
HEADLESS_LOWER="$(printf '%s' "${HEADLESS}" | tr '[:upper:]' '[:lower:]')"
PROXY_ENABLED_LOWER="$(printf '%s' "${PROXY_ENABLED}" | tr '[:upper:]' '[:lower:]')"

echo
echo "  当前配置:"
echo "    APP_HOST     : ${APP_HOST}"
echo "    APP_PORT     : ${APP_PORT}"
echo "    BROWSER_PORT : ${BROWSER_PORT}"
echo "    HEADLESS     : ${HEADLESS}"
if [[ "${PROXY_ENABLED_LOWER}" == "true" ]]; then
  echo "    PROXY        : ${PROXY_ADDRESS}"
else
  echo "    PROXY        : 已禁用"
fi
echo

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] 未找到 python3，请先安装 Python 3.8+"
  exit 1
fi

PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PY_MAJOR="${PY_VER%%.*}"
PY_MINOR="${PY_VER##*.}"
if [[ "${PY_MAJOR}" -lt 3 ]] || [[ "${PY_MAJOR}" -eq 3 && "${PY_MINOR}" -lt 8 ]]; then
  echo "[ERROR] Python 版本过低: ${PY_VER}，需要 3.8+"
  exit 1
fi
echo "[OK] Python ${PY_VER}"

if [[ ! -d "venv" ]]; then
  echo "[INFO] 创建虚拟环境..."
  python3 -m venv venv
fi

VENV_PY="venv/bin/python"
if [[ ! -x "${VENV_PY}" ]]; then
  echo "[ERROR] 虚拟环境损坏，缺少 ${VENV_PY}"
  exit 1
fi

ensure_venv_pip() {
  if "${VENV_PY}" -m pip --version >/dev/null 2>&1; then
    return 0
  fi

  echo "[WARN] 虚拟环境中缺少 pip，尝试自动修复..."

  # 方案 1：使用 ensurepip 修复（多数 Linux 可用）
  if "${VENV_PY}" -m ensurepip --upgrade >/dev/null 2>&1; then
    "${VENV_PY}" -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
  fi

  if "${VENV_PY}" -m pip --version >/dev/null 2>&1; then
    echo "[OK] pip 修复成功 (ensurepip)"
    return 0
  fi

  # 方案 2：升级虚拟环境依赖（Python 3.9+）
  if python3 -m venv --upgrade-deps venv >/dev/null 2>&1; then
    if "${VENV_PY}" -m pip --version >/dev/null 2>&1; then
      echo "[OK] pip 修复成功 (venv --upgrade-deps)"
      return 0
    fi
  fi

  echo "[ERROR] 无法在虚拟环境中启用 pip。"
  echo "        请先安装系统 pip/venv 组件后重试。"
  if command -v apt-get >/dev/null 2>&1; then
    echo "        Debian/Ubuntu: apt-get update && apt-get install -y python3-pip python3-venv"
  elif command -v dnf >/dev/null 2>&1; then
    echo "        RHEL/Fedora:   dnf install -y python3-pip python3-virtualenv"
  elif command -v yum >/dev/null 2>&1; then
    echo "        CentOS:        yum install -y python3-pip python3-virtualenv"
  elif command -v apk >/dev/null 2>&1; then
    echo "        Alpine:        apk add --no-cache py3-pip py3-virtualenv"
  fi
  return 1
}

if ! ensure_venv_pip; then
  exit 1
fi

echo "[STEP] 检查依赖"
REQ_HASH_FILE="venv/.req_hash"
CURRENT_HASH="$(${VENV_PY} - <<'PY'
import hashlib
from pathlib import Path
print(hashlib.md5(Path("requirements.txt").read_bytes()).hexdigest())
PY
)"
NEED_INSTALL=0

if [[ ! -f "requirements.txt" ]]; then
  echo "[ERROR] 缺少 requirements.txt"
  exit 1
fi

if [[ ! -f "${REQ_HASH_FILE}" ]]; then
  NEED_INSTALL=1
else
  OLD_HASH="$(cat "${REQ_HASH_FILE}")"
  if [[ "${OLD_HASH}" != "${CURRENT_HASH}" ]]; then
    NEED_INSTALL=1
  fi
fi

if [[ "${NEED_INSTALL}" -eq 0 && -f "check_deps.py" ]]; then
  if ! "${VENV_PY}" check_deps.py >/dev/null 2>&1; then
    NEED_INSTALL=1
  fi
fi

if [[ "${NEED_INSTALL}" -eq 1 ]]; then
  echo "[INFO] 安装 Python 依赖..."
  "${VENV_PY}" -m pip install -r requirements.txt
  echo "${CURRENT_HASH}" > "${REQ_HASH_FILE}"
  echo "[OK] 依赖安装完成"
else
  echo "[OK] 依赖已是最新"
fi

if [[ -f "patch_drissionpage.py" ]]; then
  echo "[STEP] 应用 DrissionPage 补丁"
  "${VENV_PY}" patch_drissionpage.py || echo "[WARN] 补丁应用失败，继续启动"
fi

PROFILE_DIR="${PROJECT_DIR}/chrome_profile"
mkdir -p "${PROFILE_DIR}"
if [[ -f "clean_profile.py" ]]; then
  "${VENV_PY}" clean_profile.py "${PROFILE_DIR}" || true
fi

check_debug_port() {
  "${VENV_PY}" - "$BROWSER_PORT" <<'PY'
import socket
import sys
port = int(sys.argv[1])
s = socket.socket()
s.settimeout(0.6)
try:
    s.connect(("127.0.0.1", port))
    print("1")
except Exception:
    print("0")
finally:
    s.close()
PY
}

find_browser() {
  local chosen=""
  if [[ -n "${BROWSER_PATH:-}" && -x "${BROWSER_PATH}" ]]; then
    chosen="${BROWSER_PATH}"
  fi

  if [[ -z "${chosen}" && "$(uname -s)" == "Darwin" ]]; then
    local mac_candidates=(
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
      "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
      "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi"
      "/Applications/Opera.app/Contents/MacOS/Opera"
    )
    for p in "${mac_candidates[@]}"; do
      if [[ -x "${p}" ]]; then
        chosen="${p}"
        break
      fi
    done
  fi

  if [[ -z "${chosen}" ]]; then
    local linux_candidates=(google-chrome chromium chromium-browser microsoft-edge brave-browser vivaldi opera)
    for c in "${linux_candidates[@]}"; do
      if command -v "${c}" >/dev/null 2>&1; then
        chosen="$(command -v "${c}")"
        break
      fi
    done
  fi

  echo "${chosen}"
}

if [[ "$(check_debug_port)" == "0" ]]; then
  BROWSER_EXE="$(find_browser)"
  if [[ -z "${BROWSER_EXE}" ]]; then
    echo "[ERROR] 未找到 Chromium 浏览器。请安装 Chrome/Edge/Brave/Vivaldi/Opera，或在 .env 设置 BROWSER_PATH"
    exit 1
  fi

  BROWSER_ARGS=(
    "--remote-debugging-port=${BROWSER_PORT}"
    "--user-data-dir=${PROFILE_DIR}"
    "--no-first-run"
    "--no-default-browser-check"
    "--disable-backgrounding-occluded-windows"
    "--disable-background-timer-throttling"
    "--disable-renderer-backgrounding"
  )

  if [[ "${HEADLESS_LOWER}" == "true" ]]; then
    BROWSER_ARGS+=(
      "--headless=new"
      "--no-sandbox"
      "--disable-gpu"
    )
  fi

  if [[ "${PROXY_ENABLED_LOWER}" == "true" && -n "${PROXY_ADDRESS}" ]]; then
    BROWSER_ARGS+=("--proxy-server=${PROXY_ADDRESS}")
    if [[ -n "${PROXY_BYPASS}" ]]; then
      BROWSER_ARGS+=("--proxy-bypass-list=${PROXY_BYPASS}")
    fi
  fi

  echo "[INFO] 启动浏览器: ${BROWSER_EXE}"
  "${BROWSER_EXE}" "${BROWSER_ARGS[@]}" about:blank >/dev/null 2>&1 &
  sleep 2
fi

echo
echo "========================================"
echo "  服务启动中..."
echo "========================================"
echo "  API 地址:    http://${APP_HOST}:${APP_PORT}"
echo "  控制面板:    http://${APP_HOST}:${APP_PORT}/"
echo "  API 文档:    http://${APP_HOST}:${APP_PORT}/docs"
echo "========================================"
echo

while true; do
  set +e
  "${VENV_PY}" main.py
  EXIT_CODE=$?
  set -e

  if [[ "${EXIT_CODE}" -eq 0 ]]; then
    echo "[INFO] 服务已停止"
    exit 0
  fi

  if [[ "${EXIT_CODE}" -eq 3 ]]; then
    echo "[INFO] 检测到配置更新，重启服务..."
    sleep 2
    continue
  fi

  echo "[ERROR] 服务异常退出 (退出码: ${EXIT_CODE})，3 秒后重启..."
  sleep 3
done
