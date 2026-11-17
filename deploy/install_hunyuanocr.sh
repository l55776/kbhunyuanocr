#!/usr/bin/env bash
# ============================================================================
# install_hunyuanocr.sh —— Debian 12 一键部署（原生二进制 + systemd）
#
# 目录约定（把本仓库 deploy/ 上传到服务器后应长这样）：
#   /opt/hunyuanocr/
#     ├── models/HunyuanOCR-Q8_0.gguf        (0.54 GB)
#     ├── models/mmproj-HunyuanOCR-Q8_0.gguf (0.68 GB)
#     ├── web/index.html                     (前端页面)
#     └── linux/                             (本目录脚本)
#
# 用法（在服务器上，从 deploy/linux/ 目录执行）：
#   cd /opt/hunyuanocr/linux
#   sudo bash install_hunyuanocr.sh          # 编译(CPU/GPU 自动)+装 systemd+开机自启
#   sudo SKIP_BUILD=1 bash install_hunyuanocr.sh   # 若已手动放好 bin/llama-server 可跳过编译
#   sudo PORT=9000 APP_DIR=/srv/hunyuanocr bash install_hunyuanocr.sh  # 自定义端口/路径
# 环境变量:
#   PORT      服务端口（默认 8099，会写入 systemd unit）
#   APP_DIR   安装根目录（默认 /opt/hunyuanocr）
#   SKIP_BUILD=1 跳过编译
#   USE_CUDA  auto/0/1 传给 build_llamaserver.sh
# ============================================================================
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/hunyuanocr}"
PORT="${PORT:-8099}"
SKIP_BUILD="${SKIP_BUILD:-0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log(){ printf '[install] %s\n' "$*"; }
die(){ printf '[install][ERROR] %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "请用 root / sudo 运行"

# ---------- 0. 校验关键文件 ----------
for f in models/HunyuanOCR-Q8_0.gguf models/mmproj-HunyuanOCR-Q8_0.gguf web/index.html; do
  [ -e "$APP_DIR/$f" ] || [ -e "$HERE/../$f" ] || die "缺少 $f，请先把模型与前端页面放到 $APP_DIR（见脚本头部目录约定）"
done

# 允许直接在仓库 deploy/ 目录下执行（此时自动拷贝 models/web 到 APP_DIR）
if [ ! -e "$APP_DIR/models/HunyuanOCR-Q8_0.gguf" ] && [ -e "$HERE/../models/HunyuanOCR-Q8_0.gguf" ]; then
  log "从 $HERE/../ 拷贝 models/ web/ 到 $APP_DIR ..."
  mkdir -p "$APP_DIR"
  cp -rn "$HERE/../models/." "$APP_DIR/models/"
  cp -rn "$HERE/../web/."   "$APP_DIR/web/"
fi

mkdir -p "$APP_DIR"/{bin,logs}

# ---------- 1. 编译 / 校验 llama-server ----------
if [ "$SKIP_BUILD" != "1" ] && [ ! -x "$APP_DIR/bin/llama-server" ]; then
  log "开始编译 llama-server（首次约 10~30 分钟）..."
  USE_CUDA="${USE_CUDA:-auto}" APP_DIR="$APP_DIR" bash "$HERE/build_llamaserver.sh"
else
  [ -x "$APP_DIR/bin/llama-server" ] || die "SKIP_BUILD=1 或已有二进制，但 $APP_DIR/bin/llama-server 不存在"
  log "使用现有二进制：$APP_DIR/bin/llama-server"
fi

# ---------- 2. 服务运行账号 ----------
if ! id hunyuanocr >/dev/null 2>&1; then
  useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin hunyuanocr
  log "已创建系统账号 hunyuanocr"
fi
chown -R root:hunyuanocr "$APP_DIR"
chmod -R g+rX "$APP_DIR"
chmod g+w "$APP_DIR/logs"

# ---------- 3. 写入 systemd unit ----------
UNIT=/etc/systemd/system/hunyuanocr.service
sed -e "s|@APP@|$APP_DIR|g" \
    -e "s|--port 8099|--port $PORT|" \
    "$HERE/hunyuanocr.service" > "$UNIT"
log "已生成 $UNIT (port=$PORT)"

# ---------- 4. 启动并设为开机自启 ----------
systemctl daemon-reload
systemctl enable --now hunyuanocr.service

echo
echo "===== 部署完成 ====="
echo "  - 服务状态: systemctl status hunyuanocr --no-pager -l"
echo "  - 实时日志: journalctl -u hunyuanocr -f"
echo "  - 健康检查: curl -s http://127.0.0.1:$PORT/v1/models"
echo "  - 前端页面: http://<服务器IP>:$PORT/  （同源调用 API，无需 CORS）"
echo "  - 停止/重启: systemctl stop|restart hunyuanocr"
echo "===================="
