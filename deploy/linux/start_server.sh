#!/usr/bin/env bash
# ============================================================================
# start_server.sh —— 前台启动 HunyuanOCR 服务（等价于 Windows 的 start_server.bat）
#   手动调试：  sudo ./start_server.sh              # 默认 Q8 模型
#   切换 Q4：   MODEL=Q4 sudo ./start_server.sh
#   systemd：   ExecStart 直接调用本脚本即可（前台运行，日志进 journal）
# 模型开关 MODEL（默认 Q8，大小写不敏感）:
#   Q8 = models/HunyuanOCR-Q8_0.gguf        精度优先（默认）
#   Q4 = models/HunyuanOCR-Q4_K_M.gguf      生成速度约 ×2，密集小字精度略降
# 注意：视觉 mmproj 固定用 Q8_0（仅在看图/预填时调用一次，Q4 化收益可忽略，故保持无损）
# 环境变量:
#   PORT           监听端口（默认 8099）
#   MODEL          Q8|Q4（默认 Q8）
#   THREADS        CPU 生成线程数（默认 8）
#   THREADS_BATCH  图像/提示处理（prefill）线程数（默认 15）
# 实测依据（澜起 Jintide 8 物理核，llama-bench）：
#   生成：8 线程 ≈55.6 token/s，15 线程 ≈21.7（默认），16+ 线程反而暴跌到 ~17
#   预填：15 线程 pp512 ≈570 token/s（保住 ~2s 首字）
# 换机器请用环境变量覆盖：THREADS=<物理核数> THREADS_BATCH=<逻辑核数> bash start_server.sh
# 前置: 已由 install_hunyuanocr.sh 完成编译，且目录结构：
#        $APP_DIR/bin/llama-server
#        $APP_DIR/models/HunyuanOCR-Q8_0.gguf      （MODEL=Q8 时）
#        $APP_DIR/models/HunyuanOCR-Q4_K_M.gguf    （MODEL=Q4 时）
#        $APP_DIR/models/mmproj-HunyuanOCR-Q8_0.gguf（视觉投影，固定 Q8）
#        $APP_DIR/web/            (前端页面，经 --path 同源托管)
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."        # 切到应用根目录（与 start_server.bat 的 cd /d %~dp0 对应）

PORT="${PORT:-8099}"
MODEL="$(echo "${MODEL:-Q8}" | tr '[:lower:]' '[:upper:]')"
# 生成 -t 8 / 预填 -tb 15：本机实测最优（见文件头注释），避免默认 15 线程浪费 2.5 倍时间
THREADS="${THREADS:-8}"
THREADS_BATCH="${THREADS_BATCH:-15}"

case "$MODEL" in
  Q8) LLM_GGUF="models/HunyuanOCR-Q8_0.gguf"    ;;
  Q4) LLM_GGUF="models/HunyuanOCR-Q4_K_M.gguf"  ;;
  *)
    echo "[ERROR] 无效的 MODEL=$MODEL（只支持 Q8 / Q4）" >&2
    echo "        用法：MODEL=Q4 ./start_server.sh   或默认 Q8" >&2
    exit 1
    ;;
esac
MMPROJ_GGUF="models/mmproj-HunyuanOCR-Q8_0.gguf"   # 视觉投影固定 Q8_0

[ -f "$LLM_GGUF" ]   || { echo "[ERROR] 模型不存在：$LLM_GGUF（MODEL=$MODEL，请先量化/放置该文件）" >&2; exit 1; }
[ -f "$MMPROJ_GGUF" ] || { echo "[ERROR] 模型不存在：$MMPROJ_GGUF" >&2; exit 1; }
[ -x "bin/llama-server" ] || { echo "[ERROR] 缺少 bin/llama-server，请先运行 linux/build_llamaserver.sh" >&2; exit 1; }

echo "启动 HunyuanOCR llama-server :$PORT"
echo "  - MODEL:   $MODEL"
echo "  - LLM:     $LLM_GGUF"
echo "  - vision:  $MMPROJ_GGUF"
echo "  - web:     http://127.0.0.1:$PORT/  (Ctrl-C 停止)"

EXTRA=()
EXTRA+=( -t "$THREADS" )
EXTRA+=( -tb "$THREADS_BATCH" )

exec ./bin/llama-server \
  --host 0.0.0.0 --port "$PORT" \
  -m "$LLM_GGUF" \
  --mmproj "$MMPROJ_GGUF" \
  -c 8192 --parallel 1 --alias hunyuanocr \
  --path web \
  "${EXTRA[@]}"
