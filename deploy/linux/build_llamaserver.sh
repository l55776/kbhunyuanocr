#!/usr/bin/env bash
# ============================================================================
# build_llamaserver.sh —— 编译 HunyuanOCR 用的 llama-server（Linux 通用）
#   自动识别发行版包管理器（apt-get / dnf / yum / apk），已适配：
#   Debian / Ubuntu / Rocky / Alma / CentOS / openEuler 等。
#   - 纯 CPU（默认，最简单，基座模型仅 0.5G，CPU 足够）
#   - 检测到 NVIDIA CUDA Toolkit(>=12) 时自动启用 GPU 编译（也可手动指定）
# 用法:
#   sudo bash build_llamaserver.sh            # auto：有 nvcc>=12 则 GPU，否则 CPU
#   sudo USE_CUDA=1 bash build_llamaserver.sh # 强制 GPU 编译（需已装 CUDA 12+）
#   sudo USE_CUDA=0 bash build_llamaserver.sh # 强制纯 CPU
# 可用环境变量:
#   APP_DIR        安装根目录（默认：脚本所在应用根目录；找不到时 /opt/hunyuanocr）
#   LLAMACPP_COMMIT 锁定 llama.cpp 版本（默认 main 最新）
# 产物: $APP_DIR/bin/llama-server
# ============================================================================
set -euo pipefail

USE_CUDA="${USE_CUDA:-auto}"
# 安装根目录：优先环境变量 APP_DIR；否则若本脚本上一级已是应用根（含 models/ 与 web/）就装到上一级；
# 都没有时才回落默认 /opt/hunyuanocr
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_APP="/opt/hunyuanocr"
if [ -d "$SCRIPT_DIR/../models" ] && [ -d "$SCRIPT_DIR/../web" ]; then
  DEFAULT_APP="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
APP_DIR="${APP_DIR:-$DEFAULT_APP}"
LLAMACPP_COMMIT="${LLAMACPP_COMMIT:-main}"
BIN_DIR="$APP_DIR/bin"
SRC_DIR="$APP_DIR/src/llama.cpp"
BUILD_DIR="$SRC_DIR/build"
LOG_DIR="$APP_DIR/logs"

log(){ printf '[build] %s\n' "$*"; }
die(){ printf '[build][ERROR] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "请用 root / sudo 运行（需要 apt 安装依赖）"

# ---------- 1. 基础工具链（自动识别发行版与包管理器） ----------
PM=""
for c in apt-get dnf yum apk; do
  command -v "$c" >/dev/null 2>&1 && PM="$c" && break
done
if [ -z "$PM" ]; then
  die "未找到 apt-get/dnf/yum/apk，无法自动安装依赖。请手动安装 gcc/cmake/git 后重试。"
fi
OS_DESC="未知系统"
if [ -r /etc/os-release ]; then
  OS_DESC="$(. /etc/os-release && echo "${PRETTY_NAME:-$ID $VERSION_ID}")"
fi
log "检测到系统: $OS_DESC（包管理器: $PM）"

install_build_deps(){
  case "$PM" in
    apt-get) apt-get update -y && apt-get install -y build-essential cmake git ca-certificates ;;
    dnf)     dnf install -y gcc gcc-c++ make cmake git ;;
    yum)     yum install -y gcc gcc-c++ make cmake git ;;
    apk)     apk add --no-cache build-base cmake git ;;
  esac
}

NEED_DEPS=0
command -v gcc   >/dev/null 2>&1 || NEED_DEPS=1
command -v make  >/dev/null 2>&1 || NEED_DEPS=1
command -v cmake >/dev/null 2>&1 || NEED_DEPS=1
command -v git   >/dev/null 2>&1 || NEED_DEPS=1
if [ "$NEED_DEPS" = 1 ]; then
  log "安装编译依赖（$PM）..."
  install_build_deps
fi

# cmake 过旧兜底：CentOS 7 等自带 cmake 2.x 不够用，<3.15 则尝试用 pip 装新版
CMAKE_VER="$(command -v cmake >/dev/null 2>&1 && cmake --version | sed -n 's/cmake version \([0-9]*\.[0-9]*\).*/\1/p' || echo 0.0)"
CMAKE_MAJ="${CMAKE_VER%%.*}"; CMAKE_MIN="${CMAKE_VER#*.}"; CMAKE_MIN="${CMAKE_MIN%%.*}"
if [ "$CMAKE_MAJ" -lt 3 ] || { [ "$CMAKE_MAJ" -eq 3 ] && [ "$CMAKE_MIN" -lt 15 ]; }; then
  log "cmake $CMAKE_VER 过旧(<3.15)，尝试 python3 pip 安装新版 cmake ..."
  if command -v python3 >/dev/null 2>&1; then
    python3 -m pip install --upgrade cmake 2>/dev/null || true
  else
    log "提示：本机无 python3，未能自动升级 cmake。请手动安装 cmake>=3.15 后重试。"
  fi
fi
command -v cmake >/dev/null 2>&1 || die "cmake 仍不可用，请先安装 cmake(>=3.15) 再重试"
cmake --version | head -1

# ---------- 1.5 GCC 升级（RHEL8/Anolis8 自带 gcc8 缺 C++17 filesystem，链接 libggml 会失败） ----------
TOOLCHAIN_SWITCHED=0
GCC_VER="$(gcc -dumpfullversion 2>/dev/null || gcc -dumpversion 2>/dev/null || echo 0)"
GCC_MAJ="${GCC_VER%%.*}"
if [ "${GCC_MAJ:-0}" -lt 9 ]; then
  log "检测到 gcc $GCC_VER（<9），C++17 std::filesystem 支持不全，尝试启用 gcc-toolset ..."
  if [ -r /opt/rh/gcc-toolset-12/enable ]; then
    . /opt/rh/gcc-toolset-12/enable; TOOLCHAIN_SWITCHED=1
  elif [ -r /opt/rh/gcc-toolset-11/enable ]; then
    . /opt/rh/gcc-toolset-11/enable; TOOLCHAIN_SWITCHED=1
  elif [ "$PM" = dnf ] || [ "$PM" = yum ]; then
    log "安装 gcc-toolset-12（dnf/yum）..."
    { dnf install -y gcc-toolset-12 gcc-toolset-12-gcc-c++ || yum install -y gcc-toolset-12 gcc-toolset-12-gcc-c++; } 2>/dev/null || true
    if [ -r /opt/rh/gcc-toolset-12/enable ]; then
      . /opt/rh/gcc-toolset-12/enable; TOOLCHAIN_SWITCHED=1
    fi
  fi
  GCC_VER2="$(gcc -dumpversion 2>/dev/null || echo 0)"
  if [ "$(echo "$GCC_VER2" | cut -d. -f1)" -lt 9 ]; then
    log "提示：仍在使用 gcc $GCC_VER2。若链接仍报 std::filesystem 未定义引用，请手动执行："
    log "  dnf install -y gcc-toolset-12 gcc-toolset-12-gcc-c++ && source /opt/rh/gcc-toolset-12/enable"
  else
    log "已切换编译器: $(gcc --version | head -1)"
  fi
fi
# 换了编译器后必须清掉旧 cmake 缓存，否则仍用旧 gcc 重编
if [ "$TOOLCHAIN_SWITCHED" = 1 ] && [ -d "$BUILD_DIR" ]; then
  log "清除旧的 cmake 缓存（$BUILD_DIR）..."
  rm -rf "$BUILD_DIR"
fi

# ---------- 2. 检测 GPU / CUDA ----------
CUDA_OK=0; GPU_PRESENT=0
command -v nvidia-smi >/dev/null 2>&1 && GPU_PRESENT=1
if command -v nvcc >/dev/null 2>&1; then
  CUDA_MAJOR="$(nvcc --version | sed -n 's/.*release \([0-9]*\)\..*/\1/p')"
  [ -n "$CUDA_MAJOR" ] && [ "$CUDA_MAJOR" -ge 12 ] 2>/dev/null && CUDA_OK=1
fi

USE_GPU=0
if [ "$USE_CUDA" = "1" ]; then
  [ "$CUDA_OK" = 1 ] || die "强制 GPU 编译但未找到 CUDA >=12 的 nvcc。请先按 NVIDIA 官方安装 CUDA Toolkit 12.x（https://developer.nvidia.com/cuda-downloads），或改用 USE_CUDA=auto/0。"
  USE_GPU=1
elif [ "$USE_CUDA" = "auto" ]; then
  if [ "$CUDA_OK" = 1 ]; then USE_GPU=1; fi
fi
if [ "$USE_GPU" = 1 ]; then
  log "检测到 CUDA >=12，编译 GPU(CUDA) 版"
else
  log "编译纯 CPU 版"
  if [ "$GPU_PRESENT" = 1 ]; then
    log "提示：检测到 NVIDIA 显卡，但缺少 CUDA>=12 工具链，本次先用 CPU。"
    log "       如需 GPU：安装 CUDA Toolkit 后重跑： sudo USE_CUDA=1 bash build_llamaserver.sh"
  fi
fi

# ---------- 3. 拉取 llama.cpp ----------
mkdir -p "$SRC_DIR" "$BIN_DIR" "$LOG_DIR"
if [ ! -d "$SRC_DIR/.git" ]; then
  log "克隆 llama.cpp ..."
  git clone https://github.com/ggml-org/llama.cpp.git "$SRC_DIR"
else
  git -C "$SRC_DIR" fetch origin --tags
fi
# 解析目标版本：LLAMACPP_COMMIT=main(默认) 表示跟随仓库默认分支（llama.cpp 为 master）
if [ "$LLAMACPP_COMMIT" = "main" ]; then
  RESOLVED="$(git -C "$SRC_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  RESOLVED="${RESOLVED:-master}"
  log "llama.cpp 默认分支: $RESOLVED"
else
  RESOLVED="$LLAMACPP_COMMIT"     # 也支持 tag 或 commit hash
fi
if git -C "$SRC_DIR" rev-parse --verify "refs/remotes/origin/$RESOLVED" >/dev/null 2>&1; then
  git -C "$SRC_DIR" checkout -B deploy "origin/$RESOLVED"
else
  git -C "$SRC_DIR" checkout -B deploy "$RESOLVED" 2>/dev/null || git -C "$SRC_DIR" checkout -B deploy "origin/$RESOLVED"
fi
git -C "$SRC_DIR" log -1 --oneline

# 新版 llama.cpp 把 vendor/、tools/ui、tools/tokenize、tools/tts 等作为 git 子模块，
# 不初始化会导致 cmake 报 add_subdirectory given source "..." not existing
if [ -f "$SRC_DIR/.gitmodules" ]; then
  log "初始化 git 子模块（vendor / tools 等，需联网拉取）..."
  if ! git -C "$SRC_DIR" submodule update --init --recursive; then
    log "提示：子模块拉取失败（可能网络受限）。可改用已通过验证、不依赖子模块的版本重试："
    log "  LLAMACPP_COMMIT=b10852 bash build_llamaserver.sh"
    exit 1
  fi
fi

# ---------- 4. 配置并编译 ----------
CMAKE_ARGS=(
  -B "$BUILD_DIR" -S "$SRC_DIR"
  -DCMAKE_BUILD_TYPE=Release
  -DLLAMA_BUILD_EXAMPLES=ON
  -DLLAMA_NATIVE=ON
)
if [ "$USE_GPU" = 1 ]; then
  CMAKE_ARGS+=( -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=native )
fi
log "cmake 配置：${CMAKE_ARGS[*]}"
cmake "${CMAKE_ARGS[@]}" | tee -a "$LOG_DIR/build.log"

log "编译中（-j$(nproc)），耗时较长，请等待 ..."
cmake --build "$BUILD_DIR" --config Release -j"$(nproc)" | tee -a "$LOG_DIR/build.log"

# ---------- 5. 安装产物 ----------
install -m 0755 "$BUILD_DIR/bin/llama-server" "$BIN_DIR/llama-server"
# 新版 llama-server 依赖 libllama-server-impl.so 等共享库，需一并放同目录（$ORIGIN 解析）
if ls "$BUILD_DIR"/bin/lib*.so* >/dev/null 2>&1; then
  cp -f "$BUILD_DIR"/bin/lib*.so* "$BIN_DIR"/
fi
log "完成：$BIN_DIR/llama-server"
"$BIN_DIR/llama-server" --version
