# HunyuanOCR Linux 部署说明（Debian/Ubuntu 与 RHEL 系(Anolis/Alma/CentOS 8) · 原生 + systemd）

> 本项目不是 Node/Python/Java Web 工程。运行核心是 llama.cpp 的 `llama-server`（C++ 原生程序，OpenAI 兼容 HTTP API），前端是纯静态页面，由 `llama-server --path` 同源托管。模型为 GGUF 格式，跨平台通用，无需转换。
> **有 NVIDIA GPU（需 CUDA≥12）自动走 GPU，否则 CPU**；基座模型仅 0.5G，纯 CPU 完全可用。

## 一、最小上传清单（不需要拷整个仓库！）

只需从仓库拷 3 块到服务器：

| 源路径 | 内容 | 说明 |
|---|---|---|
| `deploy/models/` | `HunyuanOCR-Q8_0.gguf` + `mmproj-HunyuanOCR-Q8_0.gguf`（~1.2GB） | 服务运行时必需 |
| `deploy/web/` | `index.html` 等前端 | llama-server `--path` 托管 |
| `deploy/linux/` | 本目录脚本 | 安装/启动/systemd |

**不要拷**：`deploy/bin/`（Windows 的 exe/dll）、根目录的 `train/`、`train_verl/`、`inference/`、`tools/`、`docs/`、`benchmarks/`、`llama_cpp/`、各种 `.py`/`.json`/`.txt` 测试文件。Python 生产环境可不装。

## 二、服务器目录布局

```
/opt/hunyuanocr/
├── models/     ← deploy/models/*
├── web/        ← deploy/web/*
└── linux/      ← deploy/linux/*
```

上传示例（本机执行，替换 `user@服务器IP`；若目录已存在需先清空/合并）：
```bash
scp -r deploy/models user@服务器IP:/opt/hunyuanocr/
scp -r deploy/web    user@服务器IP:/opt/hunyuanocr/
scp -r deploy/linux  user@服务器IP:/opt/hunyuanocr/
```

## 三、安装（首次在服务器上）

```bash
sudo bash /opt/hunyuanocr/linux/install_hunyuanocr.sh
```

脚本自动完成：装编译依赖 → 检测 GPU（有 `nvcc`≥12 则 CUDA 编译，否则 CPU）→ 编译 llama.cpp → 创建 `hunyuanocr` 账号 → 注册并启动 systemd 服务（开机自启）。

常用参数：
```bash
sudo PORT=9000 bash install_hunyuanocr.sh             # 改端口
sudo SKIP_BUILD=1 bash install_hunyuanocr.sh          # 已有 bin/llama-server，跳过编译
sudo USE_CUDA=1  bash build_llamaserver.sh            # 强制 GPU 编译（需先装 CUDA Toolkit 12+）
```

## 四、验证

```bash
curl -s http://127.0.0.1:8099/v1/models              # 返回模型 id 即就绪
# 浏览器打开 http://<服务器IP>:8099/ 使用前端页面
```

## 五、运维（务必使用 systemd 托管，不要在 SSH 前台跑）

> 关掉 xshell/SSH 终端服务就断，是因为在前台直接运行了 `start_server.sh`：终端关闭会给前台进程发 SIGHUP 信号把它杀掉。
> 托管到 systemd 后**关终端、断网、重启服务器都不影响**，且开机自启、崩溃自动拉起，并支持 `MODEL=Q4/Q8` 模型开关。
> 若你之前是前台手动启动、关掉终端服务就断，重跑一次安装即可切回托管（自动拉起并开机自启）：
> `cd /opt/hunyuanocr/linux && sudo SKIP_BUILD=1 bash install_hunyuanocr.sh`（目录换成你的实际部署路径）。

```bash
systemctl status hunyuanocr --no-pager -l    # 状态
journalctl -u hunyuanocr -f                  # 实时日志
systemctl stop|start|restart hunyuanocr      # 启停
systemctl disable --now hunyuanocr           # 取消开机自启
```

## 六、FAQ

- **为什么关掉 xshell 服务就断？怎么让它一直跑？**
  关终端服务就断 = 你在 SSH 里**前台**运行了 `start_server.sh`，终端断开会给前台进程发 SIGHUP 将其杀掉。正确做法是交给 systemd 托管（关终端/断网/重启都不影响，崩溃自动拉起，且天然支持 `MODEL=Q4/Q8` 开关切模型）：
  ```bash
  cd /opt/hunyuanocr/linux                 # 换成你的实际部署目录（如 /root/hunyuanocr/linux）
  sudo SKIP_BUILD=1 bash install_hunyuanocr.sh   # 已有编译好的 bin/llama-server 时跳过编译
  ```
  脚本会自动探测应用根目录，注册并启动 `hunyuanocr.service`。之后无需再挂终端，全部走 systemd：
  ```bash
  systemctl status hunyuanocr --no-pager -l      # 状态（active (running) 即正常）
  journalctl -u hunyuanocr -f                    # 实时日志
  systemctl restart hunyuanocr                   # 重启
  curl -s http://127.0.0.1:8099/v1/models        # 健康检查
  # 切换模型（Q4 文件需已放入 models/，切换后自动重启生效）：
  sudo MODEL=Q4 SKIP_BUILD=1 bash install_hunyuanocr.sh
  sudo SKIP_BUILD=1 bash install_hunyuanocr.sh   # 切回 Q8
  ```
  只想临时在后台跑、不装系统服务（注意：服务器重启不会自启，也没有崩溃自愈）：
  ```bash
  cd /root/hunyuanocr && mkdir -p logs
  nohup bash linux/start_server.sh > logs/server.out 2>&1 &   # 关终端不断
  pkill -f llama-server                                        # 停止
  ```
- **Anolis/Rocky/CentOS 8 编译报 `std::filesystem::... 未定义的引用`？** 自带 GCC 8 不支持完整 C++17 filesystem。执行 `dnf install -y gcc-toolset-12 gcc-toolset-12-gcc-c++`，再 `source /opt/rh/gcc-toolset-12/enable && rm -rf /opt/hunyuanocr/src/llama.cpp/build` 后重跑（`build_llamaserver.sh` 已内置自动升级逻辑）。
- **以后加了 NVIDIA 显卡想切 GPU？** 按 NVIDIA 官方装 CUDA Toolkit≥12，再 `sudo USE_CUDA=1 bash /opt/hunyuanocr/linux/build_llamaserver.sh && sudo systemctl restart hunyuanocr`。模型与前端无需改动。
- **接口说明**：`POST /v1/chat/completions`（OpenAI 兼容）；传图一次 `stream:false` 即返回完整 JSON；前端 `index.html` 已内置该逻辑。
- **安装脚本未在真实 Linux 上跑过？** 本机为 Windows 开发环境，脚本经 LF 换行与语法核对；如首跑失败，请贴 `journalctl -u hunyuanocr -n 50` 日志反馈。
