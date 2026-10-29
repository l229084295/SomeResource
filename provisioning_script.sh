#!/usr/bin/env bash
#
# Vast.ai 模板 PROVISIONING_SCRIPT
#
# 用法：把本文件放到 GitHub / Gist，然后模板的环境变量里填：
#   PROVISIONING_SCRIPT=https://raw.githubusercontent.com/<你>/<仓库>/main/provision.sh
#
# 设计要点：
#   1. 所有大件（conda、环境、源码、pip 缓存）都落在 /workspace，
#      实例重启不重装；实例销毁则重来（脚本幂等，重跑安全）。
#   2. 全程静默安装，不需要任何交互输入。
#   3. 可用环境变量覆盖默认值（见下方配置区）。
#
# 本脚本以 root 运行，不要加 sudo。

set -Eeo pipefail   # 故意不用 -u：conda 的 activate 脚本会引用未定义变量

# ---------------------------------------------------------------- 配置区
FACEFUSION_VERSION="${FACEFUSION_VERSION:-3.3.2}"
WORKSPACE="${WORKSPACE_DIR:-/workspace}"
CONDA_ROOT="${CONDA_ROOT:-$WORKSPACE/miniconda3}"
ENV_ROOT="${ENV_ROOT:-$WORKSPACE/conda-envs}"
ENV_NAME="${ENV_NAME:-facefusion}"
PROJECT_DIR="${PROJECT_DIR:-$WORKSPACE/facefusion}"
CACHE_DIR="${CACHE_DIR:-$WORKSPACE/cache}"
LOG_DIR="${LOG_DIR:-$WORKSPACE/logs}"
MARKER="$WORKSPACE/.facefusion.provisioned"

# CUDA/cuDNN：conda-forge 版本，可按宿主机驱动调整
CUDA_RUNTIME_VER="${CUDA_RUNTIME_VER:-12.6.3}"
CUDNN_VER="${CUDNN_VER:-9.3.0.75}"
INSTALL_CUDA_RUNTIME="${INSTALL_CUDA_RUNTIME:-1}"

# 是否在安装完成后把 Web UI 常驻跑起来（1=是）
START_SERVICE="${START_FACEFUSION:-0}"
PORT="${FACEFUSION_PORT:-7860}"
# 3.3.2 的 run 子命令没有 --host/--port，只能靠 Gradio 的环境变量控制监听地址
SERVICE_ARGS="${SERVICE_ARGS:-}"

# 已有源码时是否强制切到 FACEFUSION_VERSION
UPDATE_SOURCE="${UPDATE_FACEFUSION:-0}"

# ---------------------------------------------------------------- 日志
log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

trap 'code=$?; printf "\033[1;31m[%s] ERROR\033[0m 第 %s 行失败（退出码 %s）\n" \
      "$(date +%H:%M:%S)" "$LINENO" "$code" >&2; exit "$code"' ERR

# ---------------------------------------------------------------- 步骤
prepare_dirs() {
  [[ "$(id -u)" == "0" ]] || die "请以 root 运行（Vast 的 provisioning 默认就是 root）"
  [[ -d "$WORKSPACE" ]] || die "$WORKSPACE 不存在——这个脚本必须跑在 Vast 实例里"
  mkdir -p "$ENV_ROOT" "$CACHE_DIR" "$LOG_DIR"

  # pip / conda 缓存也放 /workspace，重启后仍能复用
  export PIP_CACHE_DIR="$CACHE_DIR/pip"
  export CONDA_PKGS_DIRS="$CACHE_DIR/conda-pkgs"
  export XDG_CACHE_HOME="$CACHE_DIR/xdg"

  local avail_mb
  avail_mb=$(df -Pk "$WORKSPACE" | awk 'NR==2 {print $4}')
  if (( avail_mb < 20 * 1024 * 1024 )); then
    warn "$WORKSPACE 剩余空间约 $((avail_mb / 1024))MB，建议留 20GB 以上"
  else
    log "$WORKSPACE 剩余空间 $((avail_mb / 1024 / 1024))GB"
  fi
}

ensure_base_deps() {
  local bin
  for bin in curl git; do
    command -v "$bin" >/dev/null 2>&1 && continue
    log "缺少 $bin，正在安装"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$bin"
    else
      die "缺少 $bin，且镜像里没有 apt-get，请换一个含 $bin 的基础镜像"
    fi
  done
}

ensure_conda() {
  if [[ -x "$CONDA_ROOT/bin/conda" ]]; then
    log "Miniconda 已存在，跳过安装"
  else
    log "安装 Miniconda -> $CONDA_ROOT（静默模式）"
    local tmp
    tmp="$(mktemp -d)"
    curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 \
      -o "$tmp/miniconda.sh" \
      https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
    # -b 批处理（跳过协议确认）/ -f 目录已存在也强制装 / -p 指定路径，全程无提示
    bash "$tmp/miniconda.sh" -b -f -p "$CONDA_ROOT"
    rm -rf "$tmp"
    log "Miniconda 安装完成"
  fi

  export PATH="$CONDA_ROOT/bin:$PATH"
  export CONDA_ENVS_PATH="$ENV_ROOT"
  # shellcheck disable=SC1091
  source "$CONDA_ROOT/etc/profile.d/conda.sh"

  conda config --set auto_activate_base false >/dev/null 2>&1 || true
  conda config --set always_yes true >/dev/null 2>&1 || true   # 兜底：任何确认都自动 yes
  accept_tos
}

accept_tos() {
  # 新版 conda 必须显式接受频道条款，否则 create/install 会失败
  if conda tos --help >/dev/null 2>&1; then
    local ch
    for ch in https://repo.anaconda.com/pkgs/main https://repo.anaconda.com/pkgs/r; do
      conda tos accept --override-channels --channel "$ch" \
        || warn "接受 $ch 条款失败（若后续 create 报错，手动执行一次）"
    done
    log "Anaconda 频道条款已接受"
  else
    log "当前 conda 没有 tos 子命令，跳过条款确认"
  fi
}

ensure_env() {
  if [[ -d "$ENV_ROOT/$ENV_NAME" ]]; then
    log "conda 环境 $ENV_NAME 已存在"
  else
    log "创建 conda 环境 $ENV_NAME (python=3.10)"
    conda create -y -n "$ENV_NAME" python=3.10
  fi
  conda activate "$ENV_NAME"
  log "已激活环境：$(python -V 2>&1) @ $(command -v python)"
}

ensure_source() {
  if [[ ! -d "$PROJECT_DIR/.git" ]]; then
    log "克隆 FaceFusion $FACEFUSION_VERSION"
    git clone --branch "$FACEFUSION_VERSION" --single-branch --depth 1 \
      https://github.com/facefusion/facefusion.git "$PROJECT_DIR"
  elif [[ "$UPDATE_SOURCE" == "1" ]]; then
    # 注意：clone 出来是 detached HEAD，直接 git pull 没用，必须 fetch tag 再 checkout
    log "更新源码到 $FACEFUSION_VERSION"
    git -C "$PROJECT_DIR" fetch --depth 1 origin \
      "+refs/tags/$FACEFUSION_VERSION:refs/tags/$FACEFUSION_VERSION"
    git -C "$PROJECT_DIR" checkout --force "tags/$FACEFUSION_VERSION"
  else
    log "源码已存在，跳过克隆（设 UPDATE_FACEFUSION=1 可强制更新）"
  fi
}

install_python_packages() {
  if [[ -f "$MARKER" ]]; then
    log "检测到完成标记，跳过 Python 依赖安装"
    return
  fi

  cd "$PROJECT_DIR"

  log "执行 install.py --onnxruntime cuda（耗时最长的一步）"
  python install.py --onnxruntime cuda

  # 注意：不要在这里再跑 pip install -r requirements.txt。
  # install.py 已经装完 requirements.txt 里除 onnxruntime 外的所有包，
  # 并最后强制装上 GPU 版；而 requirements.txt 固定的是 CPU 版
  # onnxruntime==1.22.0，再装一遍会把 GPU 版覆盖掉。
  log "补装 Web 依赖"
  pip install uvicorn fastapi tortoise-orm requests
  pip install pyngrok   # 可选：需要内网穿透时用
}

ensure_cuda_runtime() {
  [[ "$INSTALL_CUDA_RUNTIME" == "1" ]] || { log "跳过 conda CUDA runtime"; return; }

  local stamp="$ENV_ROOT/$ENV_NAME/.cuda-runtime-$CUDA_RUNTIME_VER"
  if [[ -f "$stamp" ]]; then
    log "conda CUDA runtime 已安装，跳过"
    return
  fi

  log "安装 conda-forge cuda-runtime=$CUDA_RUNTIME_VER cudnn=$CUDNN_VER"
  conda install -y -c conda-forge \
    "cuda-runtime=$CUDA_RUNTIME_VER" "cudnn=$CUDNN_VER"
  touch "$stamp"
}

verify_gpu() {
  log "验证依赖与 GPU 可用性"
  python - <<'PY'
import sys
import cv2
import onnxruntime as ort

print("OpenCV      :", cv2.__version__)
print("ONNX Runtime:", ort.__version__)
print("Providers   :", ort.get_available_providers())

sys.exit(0 if "CUDAExecutionProvider" in ort.get_available_providers() else 1)
PY
}

verify_or_fix_gpu() {
  if verify_gpu; then
    return
  fi
  # requirements.txt 里可能带进 CPU 版 onnxruntime，把 GPU 版顶掉了
  warn "缺少 CUDAExecutionProvider，重装 onnxruntime-gpu"
  pip uninstall -y onnxruntime onnxruntime-gpu >/dev/null 2>&1 || true
  pip install onnxruntime-gpu
  verify_gpu || die "onnxruntime 仍无 CUDA provider，检查宿主机驱动与 CUDA 版本"
}

write_shell_rc() {
  # /root 不在 /workspace 里，重启用不保证保留，所以每次都重写一份
  cat > "$HOME/.facefusion_env.sh" <<EOF
export PATH="$CONDA_ROOT/bin:\$PATH"
export CONDA_ENVS_PATH="$ENV_ROOT"
source "$CONDA_ROOT/etc/profile.d/conda.sh"
conda activate $ENV_NAME
# 让 Gradio 监听所有网卡，否则 Vast 的端口映射打不进来
export GRADIO_SERVER_NAME=0.0.0.0
export GRADIO_SERVER_PORT=$PORT
# 登录后直接进入项目目录
[ -d "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
EOF

  if ! grep -qF '.facefusion_env.sh' "$HOME/.bashrc" 2>/dev/null; then
    printf '\n[ -f ~/.facefusion_env.sh ] && source ~/.facefusion_env.sh\n' >> "$HOME/.bashrc"
  fi
  log "已配置 $HOME/.bashrc：登录后自动激活 $ENV_NAME 并 cd 到 $PROJECT_DIR"
}

start_service() {
  [[ "$START_SERVICE" == "1" ]] || return 0
  [[ -f "$MARKER" ]] || return 0

  local run_cmd
  run_cmd="cd $PROJECT_DIR && source $CONDA_ROOT/etc/profile.d/conda.sh && conda activate $ENV_NAME && export GRADIO_SERVER_NAME=0.0.0.0 GRADIO_SERVER_PORT=$PORT && exec python facefusion.py run $SERVICE_ARGS"

  if command -v supervisorctl >/dev/null 2>&1 && [[ -d /etc/supervisor/conf.d ]]; then
    log "通过 supervisor 常驻 Web UI（端口 $PORT）"
    cat > /etc/supervisor/conf.d/facefusion.conf <<EOF
[program:facefusion]
command=/bin/bash -lc '$run_cmd'
autostart=true
autorestart=true
startsecs=10
stdout_logfile=$LOG_DIR/facefusion.log
stderr_logfile=$LOG_DIR/facefusion.err.log
environment=PATH="$CONDA_ROOT/bin:/usr/local/bin:/usr/bin:/bin",CONDA_ENVS_PATH="$ENV_ROOT",GRADIO_SERVER_NAME="0.0.0.0",GRADIO_SERVER_PORT="$PORT"
EOF
    supervisorctl reread >/dev/null
    supervisorctl update >/dev/null || warn "supervisor update 失败，稍后手动重启服务"
  else
    if pgrep -f 'facefusion.py run' >/dev/null 2>&1; then
      log "FaceFusion 已在运行，跳过启动"
      return 0
    fi
    log "后台启动 Web UI（端口 $PORT，日志 $LOG_DIR/facefusion.log）"
    nohup /bin/bash -lc "$run_cmd" >>"$LOG_DIR/facefusion.log" 2>&1 &
  fi
}

summary() {
  cat <<EOF

============================================================
 FaceFusion 环境就绪
   版本    : $FACEFUSION_VERSION
   conda   : $CONDA_ROOT
   环境    : $ENV_ROOT/$ENV_NAME
   源码    : $PROJECT_DIR
   日志    : $LOG_DIR

 新开一个 ssh 会话会自动激活环境；当前会话请执行：
   source ~/.facefusion_env.sh

 手动启动：
   source ~/.facefusion_env.sh && cd $PROJECT_DIR && python facefusion.py run
============================================================

EOF
}

# ---------------------------------------------------------------- 主流程
main() {
  log "开始 provisioning（镜像内的首次启动）"
  prepare_dirs
  ensure_base_deps
  ensure_conda
  ensure_env
  ensure_source
  install_python_packages
  ensure_cuda_runtime
  verify_or_fix_gpu
  write_shell_rc

  # 标记必须写在启动服务之前，否则 start_service 会以为还没装好
  date -Is > "$MARKER"
  start_service
  summary
}

main "$@"
