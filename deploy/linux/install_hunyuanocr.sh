#!/usr/bin/env bash
# ============================================================================
# install_hunyuanocr.sh —— Debian 12 一键部署（原生二进制 + systemd）
#
# 目录约定（把本仓库 deploy/ 上传到服务器后应长这样）：
#   /opt/hunyuanocr/
#     ├── models/HunyuanOCR-Q8_0.gguf        (0.54 GB)
#     ├── models/HunyuanOCR-Q4_K_M.gguf      (可选，MODEL=Q4 时)
#     ├── models/mmproj-HunyuanOCR-Q8_0.gguf (0.68 GB)
#     ├── web/index.html                     (前端页面)
#     └── linux/                             (本目录脚本)
#
# 用法（在服务器上，从 deploy/linux/ 目录执行）：
#   cd /opt/hunyuanocr/linux
#   sudo bash install_hunyuanocr.sh          # 编译(CPU/GPU 自动)+装 systemd+开机自启
#   sudo SKIP_BUILD=1 bash install_hunyuanocr.sh   # 若已手动放好 bin/llama-server 可跳过编译
#   sudo MODEL=Q4 bash install_hunyuanocr.sh # 以 Q4_K_M 模型部署（需先量化/放置 Q4 文件）
#   sudo PORT=9000 APP_DIR=/srv/hunyuanocr bash install_hunyuanocr.sh  # 自定义端口/路径
# 环境变量:
#   PORT      服务端口（默认 8099，会写入 systemd unit）
#   MODEL     Q8|Q4（默认 Q8）：切换 LLM 主模型（mmproj 视觉投影固定 Q8_0）
#   APP_DIR   安装根目录（默认：脚本所在应用根目录；找不到时 /opt/hunyuanocr）
#   SKIP_BUILD=1 跳过编译
#   USE_CUDA  auto/0/1 传给 build_llamaserver.sh
#   SVC_USER  服务运行账号（默认 hunyuanocr；APP_DIR 在 /root 下自动用 root）
# ============================================================================
set -euo pipefail

PORT="${PORT:-8099}"
MODEL="$(echo "${MODEL:-Q8}" | tr '[:lower:]' '[:upper:]')"
SKIP_BUILD="${SKIP_BUILD:-0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 安装根目录：优先环境变量 APP_DIR；否则若本脚本上一级已是应用根（含 models/ 与 web/）就装到上一级；
# 都没有时才回落默认 /opt/hunyuanocr
DEFAULT_APP="/opt/hunyuanocr"
if [ -d "$HERE/../models" ] && [ -d "$HERE/../web" ]; then
  DEFAULT_APP="$(cd "$HERE/.." && pwd)"
fi
APP_DIR="${APP_DIR:-$DEFAULT_APP}"

log(){ printf '[install] %s\n' "$*"; }
die(){ printf '[install][ERROR] %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "请用 root / sudo 运行"

# ---------- 0. 模型开关 ----------
case "$MODEL" in
  Q8) LLM_REL="models/HunyuanOCR-Q8_0.gguf"    ;;
  Q4) LLM_REL="models/HunyuanOCR-Q4_K_M.gguf"  ;;
  *) die "无效的 MODEL=$MODEL（只支持 Q8 / Q4）" ;;
esac
MMPROJ_REL="models/mmproj-HunyuanOCR-Q8_0.gguf"   # 视觉投影固定 Q8_0
log "MODEL=$MODEL → LLM=$LLM_REL"

# ---------- 1. 校验关键文件 ----------
for f in "$LLM_REL" "$MMPROJ_REL" web/index.html; do
  [ -e "$APP_DIR/$f" ] || [ -e "$HERE/../$f" ] || die "缺少 $f，请先把模型与前端页面放到 $APP_DIR（见脚本头部目录约定）"
done

# 允许直接在仓库 deploy/ 目录下执行（此时自动拷贝 models/web 到 APP_DIR）
if [ ! -e "$APP_DIR/$LLM_REL" ] && [ -e "$HERE/../$LLM_REL" ]; then
  log "从 $HERE/../ 拷贝 models/ web/ 到 $APP_DIR ..."
  mkdir -p "$APP_DIR"
  cp -rn "$HERE/../models/." "$APP_DIR/models/"
  cp -rn "$HERE/../web/."   "$APP_DIR/web/"
fi

mkdir -p "$APP_DIR"/{bin,logs}

# 把 linux/ 下的启动脚本同步到应用目录（ExecStart 指向 $APP_DIR/linux/start_server.sh）
if [ "$HERE" != "$APP_DIR/linux" ]; then
  log "同步 linux/ 启动脚本到 $APP_DIR/linux ..."
  mkdir -p "$APP_DIR/linux"
  cp -f "$HERE/start_server.sh" "$HERE/build_llamaserver.sh" "$HERE/hunyuanocr.service" "$APP_DIR/linux/"
  chmod +x "$APP_DIR/linux/start_server.sh" "$APP_DIR/linux/build_llamaserver.sh"
fi

# ---------- 2. 编译 / 校验 llama-server ----------
if [ "$SKIP_BUILD" != "1" ] && [ ! -x "$APP_DIR/bin/llama-server" ]; then
  log "开始编译 llama-server（首次约 10~30 分钟）..."
  USE_CUDA="${USE_CUDA:-auto}" APP_DIR="$APP_DIR" bash "$APP_DIR/linux/build_llamaserver.sh"
else
  [ -x "$APP_DIR/bin/llama-server" ] || die "SKIP_BUILD=1 或已有二进制，但 $APP_DIR/bin/llama-server 不存在"
  log "使用现有二进制：$APP_DIR/bin/llama-server"
fi

# ---------- 3. 服务运行账号 ----------
# 应用装在 /root 家目录下时，非特权账号无法进入 /root，自动改用 root 运行
SVC_USER="${SVC_USER:-hunyuanocr}"
case "$APP_DIR" in
  /root*) SVC_USER=root ;;
esac
if [ "$SVC_USER" = root ]; then
  log "应用位于 $APP_DIR（/root 下），systemd 服务将以 root 运行"
else
  if ! id hunyuanocr >/dev/null 2>&1; then
    useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin hunyuanocr
    log "已创建系统账号 hunyuanocr"
  fi
  chown -R root:hunyuanocr "$APP_DIR"
  chmod -R g+rX "$APP_DIR"
  chmod g+w "$APP_DIR/logs"
fi

# ---------- 4. 写入 systemd unit ----------
UNIT=/etc/systemd/system/hunyuanocr.service
sed -e "s|@APP@|$APP_DIR|g" \
    -e "s|@PORT@|$PORT|" \
    -e "s|@MODEL@|$MODEL|" \
    -e "s|^User=.*|User=$SVC_USER|" \
    -e "s|^Group=.*|Group=$SVC_USER|" \
    "$APP_DIR/linux/hunyuanocr.service" > "$UNIT"
log "已生成 $UNIT (port=$PORT, model=$MODEL)"

# ---------- 5. 启动并设为开机自启 ----------
systemctl daemon-reload
systemctl enable --now hunyuanocr.service

echo
echo "===== 部署完成 ====="
echo "  - 服务状态: systemctl status hunyuanocr --no-pager -l"
echo "  - 实时日志: journalctl -u hunyuanocr -f"
echo "  - 当前模型: $MODEL ($LLM_REL)"
echo "  - 切换模型: sudo bash install_hunyuanocr.sh   # Q8 默认"
echo "              sudo MODEL=Q4 bash install_hunyuanocr.sh   # 切到 Q4_K_M"
echo "  - 健康检查: curl -s http://127.0.0.1:$PORT/v1/models"
echo "  - 前端页面: http://<服务器IP>:$PORT/  （同源调用 API，无需 CORS）"
echo "  - 停止/重启: systemctl stop|restart hunyuanocr"
echo "===================="
