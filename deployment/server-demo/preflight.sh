#!/usr/bin/env bash
# =============================================================================
# mall 演示环境 · 服务器前置体检（只读，不改任何东西）
#
# 用法（在服务器上，offline 目录的兄弟目录中执行）：
#   bash preflight.sh
#   OFFLINE_DIR=/data/offline bash preflight.sh      # 离线包放在别处时
#
# 退出码：0 = 全部满足，可以跑 deploy.sh；1 = 有硬性条件不满足。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# ---------------- 可通过环境变量覆盖的常量 ----------------
OFFLINE_DIR="${OFFLINE_DIR:-$SCRIPT_DIR/../offline}"
TARGET_BASE="${TARGET_BASE:-/opt}"

# ---------------- 硬件门槛（按三套编排 mem_limit 合计约 12.6GB 推算）----------------
MIN_DISK_GB=40
MIN_MEM_GB=12
MIN_CPU=2
MIN_MAX_MAP_COUNT=262144

# 中间件在宿主机上的监听端口（全部绑 127.0.0.1，靠 SSH 隧道访问）
PORTS=(
  "3306|MySQL"
  "6379|Redis"
  "27017|MongoDB"
  "5672|RabbitMQ-AMQP"
  "15672|RabbitMQ-管理台"
  "8848|Nacos-HTTP"
  "9848|Nacos-gRPC"
  "9200|Elasticsearch"
  "9000|MinIO-API"
  "9001|MinIO-控制台"
  "15432|PostgreSQL"
  "19530|Milvus"
  "19091|Milvus-健康检查"
)

# ---------------- 输出样式 ----------------
if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
  C_CYN=$'\033[1;36m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''; C_OFF=''
fi

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
HINTS=()

row() { # $1 检查项(ASCII) $2 PASS/FAIL/WARN $3 说明
  local key="$1" status="$2" detail="$3" color="$C_GRN"
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) color="$C_RED"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    WARN) color="$C_YEL"; WARN_COUNT=$((WARN_COUNT + 1)) ;;
  esac
  printf '  %-24s %s%-4s%s %s\n' "$key" "$color" "$status" "$C_OFF" "$detail"
}

hint() { HINTS+=("$1"); }
step() { printf '\n%s==== %s ====%s\n' "$C_CYN" "$*" "$C_OFF"; }

# ---------------- 0. 定位离线包 ----------------
step "0/7 定位离线包"

if [ ! -d "$OFFLINE_DIR" ]; then
  printf '%s[错误] 找不到离线包目录：%s%s\n' "$C_RED" "$OFFLINE_DIR" "$C_OFF" >&2
  printf '       请把整个 offline 目录上传到服务器，或用 OFFLINE_DIR=/实际路径 bash preflight.sh\n' >&2
  exit 1
fi
OFFLINE_DIR="$(cd -- "$OFFLINE_DIR" && pwd -P)"
DATA_DIR="$OFFLINE_DIR/data"
printf '  离线包：%s\n' "$OFFLINE_DIR"
printf '  目标目录：%s/mall-swarm、%s/mall-agent、%s/mall-agent-vector\n' "$TARGET_BASE" "$TARGET_BASE" "$TARGET_BASE"

# ---------------- 1. 基础命令 ----------------
step "1/7 系统命令"

for cmd in docker gzip sed awk sha256sum df curl; do
  if command -v "$cmd" > /dev/null 2>&1; then
    row "cmd.$cmd" PASS "已安装"
  else
    row "cmd.$cmd" FAIL "缺少命令 $cmd"
    case "$cmd" in
      docker) hint "apt-get install -y docker.io docker-compose-v2   # 或按官方文档安装 Docker CE" ;;
      curl) hint "apt-get install -y curl" ;;
      *) hint "apt-get install -y coreutils gzip sed gawk" ;;
    esac
  fi
done

# ---------------- 2. Docker 与 Compose v2 ----------------
step "2/7 Docker 与 Compose v2"

DOCKER=()
SUDO=()
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo > /dev/null 2>&1; then SUDO=(sudo); fi
fi

if command -v docker > /dev/null 2>&1; then
  if docker info > /dev/null 2>&1; then
    DOCKER=(docker)
    row "docker.daemon" PASS "守护进程可访问（当前用户）"
  elif [ "${#SUDO[@]}" -gt 0 ] && sudo docker info > /dev/null 2>&1; then
    DOCKER=(sudo docker)
    row "docker.daemon" WARN "普通用户无权限，已能用 sudo docker（deploy.sh 会提示输入密码）"
  else
    # 可能是需要密码的 sudo，留待 deploy.sh 现场提权
    DOCKER=(sudo docker)
    row "docker.daemon" FAIL "无法访问 Docker 守护进程"
    hint "systemctl status docker && systemctl start docker   # 启动守护进程"
    hint "usermod -aG docker \$USER  # 或直接用 sudo bash deploy.sh"
  fi
else
  row "docker.daemon" FAIL "未安装 docker"
  hint "参考 https://docs.docker.com/engine/install/ubuntu/ 安装 Docker，或用 apt-get install -y docker.io"
fi

COMPOSE_OK=0
if [ "${#DOCKER[@]}" -gt 0 ]; then
  if COMPOSE_VER="$("${DOCKER[@]}" compose version --short 2> /dev/null)"; then
    COMPOSE_OK=1
    if [ "${COMPOSE_VER%%.*}" -ge 2 ] 2> /dev/null; then
      row "docker.compose" PASS "Compose v$COMPOSE_VER（v2 语法）"
    else
      row "docker.compose" FAIL "检测到 Compose v$COMPOSE_VER，需要 v2"
      hint "安装 compose 插件：apt-get install -y docker-compose-v2  # 之后用 docker compose（空格）"
    fi
  else
    row "docker.compose" FAIL "缺少 docker compose（v2 插件）"
    hint "apt-get install -y docker-compose-v2  # 注意不是 docker-compose（v1 带横线）"
  fi
fi

DOCKER_ROOT="/var/lib/docker"
if [ "$COMPOSE_OK" -eq 1 ]; then
  DOCKER_ROOT="$("${DOCKER[@]}" info -f '{{.DockerRootDir}}' 2> /dev/null || echo /var/lib/docker)"
fi
printf '  Docker 数据目录：%s\n' "$DOCKER_ROOT"

# ---------------- 3. 硬件规格 ----------------
step "3/7 硬件规格"

CPU_N="$(nproc 2> /dev/null || echo 0)"
if [ "${CPU_N:-0}" -ge "$MIN_CPU" ]; then
  row "hw.cpu" PASS "${CPU_N} 核（要求 ≥${MIN_CPU}）"
else
  row "hw.cpu" FAIL "${CPU_N} 核（要求 ≥${MIN_CPU}），三套编排里 Milvus 单容器就要 2 核"
  hint "换更大的实例规格（建议 4 核）"
fi

MEM_GB="$(awk '/^MemTotal:/{printf "%d", $2/1048576}' /proc/meminfo 2> /dev/null || echo 0)"
if [ "${MEM_GB:-0}" -ge "$MIN_MEM_GB" ]; then
  row "hw.memory" PASS "${MEM_GB} GB（要求 ≥${MIN_MEM_GB}）"
else
  row "hw.memory" FAIL "${MEM_GB} GB（要求 ≥${MIN_MEM_GB}），11 个容器 mem_limit 合计约 12.6 GB"
  hint "扩容内存到 16 GB，否则 Nacos / ES / Milvus 会被 OOM killer 干掉"
fi

DISK_CHECK_PATH="/"
if [ -d "$DOCKER_ROOT" ]; then DISK_CHECK_PATH="$DOCKER_ROOT"; fi
DISK_GB="$(df -Pk "$DISK_CHECK_PATH" 2> /dev/null | awk 'NR==2{printf "%d", $4/1048576}' || echo 0)"
if [ "${DISK_GB:-0}" -ge "$MIN_DISK_GB" ]; then
  row "hw.disk" PASS "${DISK_GB} GB 可用 @${DISK_CHECK_PATH}（要求 ≥${MIN_DISK_GB}）"
else
  row "hw.disk" FAIL "${DISK_GB} GB 可用 @${DISK_CHECK_PATH}（要求 ≥${MIN_DISK_GB}）"
  hint "离线镜像 3 GB + 解压后约 8 GB + 数据卷，清盘或扩盘后再来"
fi

# ---------------- 4. Elasticsearch 内核参数 ----------------
step "4/7 内核参数"

MAX_MAP_COUNT="$(sysctl -n vm.max_map_count 2> /dev/null || echo 0)"
if [ "${MAX_MAP_COUNT:-0}" -ge "$MIN_MAX_MAP_COUNT" ]; then
  row "kernel.max_map_count" PASS "$MAX_MAP_COUNT（ES 8 要求 ≥$MIN_MAX_MAP_COUNT）"
else
  row "kernel.max_map_count" WARN "$MAX_MAP_COUNT 偏低，ES 8 会启动失败——deploy.sh 会自动调高"
  hint "手工修：sudo sysctl -w vm.max_map_count=262144  # 并写入 /etc/sysctl.d/99-mall.conf 持久化"
fi

# ---------------- 5. 端口占用 ----------------
step "5/7 端口占用（全部应绑 127.0.0.1）"

check_port_usage() { # $1=端口 $2=组件名
  local port="$1" pname="$2" listeners owner
  listeners="$(ss -Hltn "sport = :$port" 2> /dev/null | awk '{print $4}' | tr '\n' ' ' || true)"
  if [ -z "${listeners// /}" ]; then
    row "port.$port" PASS "$pname 空闲"
    return 0
  fi
  # 已被本项目的容器占着（重复执行 deploy.sh 的正常情况）
  owner=""
  if [ "$COMPOSE_OK" -eq 1 ]; then
    owner="$("${DOCKER[@]}" ps --format '{{.Names}}|{{.Ports}}' 2> /dev/null \
      | grep -F ":$port->" | cut -d'|' -f1 | head -n1 || true)"
  fi
  if [ -n "$owner" ]; then
    row "port.$port" PASS "$pname 已被本项目容器 $owner 占用（可继续）"
  else
    row "port.$port" FAIL "$pname 端口 $port 被其他进程占用：[${listeners}]"
    hint "ss -ltnp | grep ':$port'   # 找出占用进程，或先停掉旧环境的中间件"
  fi
}

if command -v ss > /dev/null 2>&1; then
  for item in "${PORTS[@]}"; do
    IFS='|' read -r port pname <<< "$item"
    check_port_usage "$port" "$pname"
  done
else
  row "port.check" WARN "缺少 ss，跳过端口占用检查（不影响部署，建议装 iproute2）"
  hint "apt-get install -y iproute2"
fi

# ---------------- 6. 离线包完整性（只看文件在不在） ----------------
step "6/7 离线包内容"

TAR_COUNT=0
if [ -d "$OFFLINE_DIR/images" ]; then
  TAR_COUNT="$(find "$OFFLINE_DIR/images" -maxdepth 1 -name '*.tar' -type f | wc -l | tr -d ' ')"
fi
if [ "$TAR_COUNT" -eq 14 ]; then
  row "offline.images" PASS "14 个镜像包齐全"
else
  row "offline.images" FAIL "只找到 ${TAR_COUNT} 个 .tar（应有 14 个）"
  hint "重新上传 offline/images 目录，注意断点续传要校验 SHA256SUMS.txt"
fi

for item in "01-mysql-all.sql.gz|data.mysql" "02-postgres-all.sql.gz|data.postgres" "03-mongo-all.gz|data.mongo"; do
  IFS='|' read -r f key <<< "$item"
  if [ -f "$DATA_DIR/$f" ]; then
    row "$key" PASS "$f（$(du -h "$DATA_DIR/$f" | cut -f1)）"
  else
    row "$key" FAIL "缺少数据快照 $DATA_DIR/$f"
    hint "重新上传 offline/data 目录"
  fi
done

for d in mall-swarm mall-agent mall-agent-vector; do
  if [ -d "$OFFLINE_DIR/server-config/$d" ]; then
    row "config.$d" PASS "编排目录存在"
  else
    row "config.$d" FAIL "缺少 $OFFLINE_DIR/server-config/$d"
    hint "重新上传 offline/server-config 目录（没有它容器起不来）"
  fi
done

if [ -f "$OFFLINE_DIR/SHA256SUMS.txt" ]; then
  row "offline.sha256sums" PASS "校验清单存在（deploy.sh 会自动校验）"
else
  row "offline.sha256sums" FAIL "缺少 SHA256SUMS.txt"
  hint "从原始离线包补齐 SHA256SUMS.txt，否则无法校验完整性"
fi

# ES 中文分词插件（缺了中文搜索全废，且是挂载目录，必须存在）
if [ -f "$OFFLINE_DIR/server-config/mall-swarm/es-ik/plugin-descriptor.properties" ]; then
  row "config.es-ik" PASS "IK 中文分词插件目录存在"
else
  row "config.es-ik" FAIL "缺少 es-ik/ 插件目录"
  hint "补齐 offline/server-config/mall-swarm/es-ik/（ES 需要它提供中文分词）"
fi

# ---------------- 7. 现有部署状态 ----------------
step "7/7 现有部署状态"

if [ "$COMPOSE_OK" -eq 1 ]; then
  RUNNING="$("${DOCKER[@]}" ps --format '{{.Names}}' 2> /dev/null | grep -cE '^mall-swarm-|^mall-agent' || true)"
  printf '  检测到 %s 个 mall 相关容器在运行\n' "$RUNNING"
  if [ "${RUNNING:-0}" -gt 0 ]; then
    printf '  说明：deploy.sh 是幂等的，会复用这些容器并跳过已有数据。\n'
  fi
fi

if [ -e "$TARGET_BASE/mall-swarm/compose.deploy.yaml" ]; then
  printf '  %s 下已有上次部署的编排副本，deploy.sh 会覆盖更新。\n' "$TARGET_BASE"
fi

# ---------------- 汇总 ----------------
printf '\n%s==== 体检结果 ====%s\n' "$C_CYN" "$C_OFF"
printf '  PASS %s 个，WARN %s 个，FAIL %s 个\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

if [ "${#HINTS[@]}" -gt 0 ]; then
  printf '\n  处理建议：\n'
  seen=""
  for h in "${HINTS[@]}"; do
    case "$seen" in *"|$h|"*) continue ;; esac
    seen="${seen}|${h}|"
    printf '   - %s\n' "$h"
  done
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
  printf '\n%s有 %s 项硬性条件不满足，先修好再执行 bash deploy.sh%s\n' "$C_RED" "$FAIL_COUNT" "$C_OFF" >&2
  exit 1
fi

printf '\n%s体检通过，可以执行：bash deploy.sh%s\n' "$C_GRN" "$C_OFF"
exit 0
