#!/usr/bin/env bash
# =============================================================================
# mall 演示环境 · 中间件服务器一键部署（离线包版）
#
# 做的事：在干净的 Linux 服务器上把 11 个中间件容器（3 套编排）拉起来，
#         并恢复 MySQL / PostgreSQL / MongoDB 数据快照。
#         本机（Windows）的 6 个 Java 服务 + Python 智能体 + 2 个前端通过
#         deployment/dev.cjs 内置的 SSH 隧道连过来，服务器上不跑业务进程。
#
# 幂等：可以反复执行。镜像已加载会跳过，数据已存在会跳过恢复。
#
# 用法：
#   bash deploy.sh                    # 正常部署 / 修复性重跑
#   bash deploy.sh --force-restore    # 强制重新导入 dump（覆盖服务器现有数据）
#   bash deploy.sh --skip-restore     # 只起容器，不导数据
#   bash deploy.sh --skip-load        # 跳过镜像加载（镜像已在本地时）
#   bash deploy.sh --skip-verify      # 跳过 sha256 校验（不推荐）
#   bash deploy.sh --yes              # 不做交互确认（自动化用）
#
# 环境变量：
#   OFFLINE_DIR   离线包目录，默认 <脚本目录>/../offline
#   TARGET_BASE   编排落地根目录，默认 /opt
#
# 注意：绝对不要给 docker compose 加 --build。镜像全部来自离线包，
#       无外网环境下 --build 必然失败（本脚本已把 compose 里的 build 段删掉）。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# ---------------- 常量 ----------------
OFFLINE_DIR="${OFFLINE_DIR:-$SCRIPT_DIR/../offline}"
TARGET_BASE="${TARGET_BASE:-/opt}"

SWARM_DIR="$TARGET_BASE/mall-swarm"
AGENT_DIR="$TARGET_BASE/mall-agent"
VECTOR_DIR="$TARGET_BASE/mall-agent-vector"

MYSQL_WAIT_TIMEOUT=360
PG_WAIT_TIMEOUT=180

# mall 库导入后的表数量基线（dump 里实际是 86 张，留 6 张容差防版本漂移）
MYSQL_TABLE_EXPECT=86
MYSQL_TABLE_MIN=80

# 离线镜像包 → 镜像名。第二/第三列是"已加载就跳过"的判定依据（兼容带源前缀与短名两种写法）。
IMAGES=(
  "01-mysql-8.0.35.tar|docker.m.daocloud.io/library/mysql:8.0.35|"
  "02-redis-7.4-alpine.tar|docker.m.daocloud.io/library/redis:7.4-alpine|"
  "03-mongo-7.0.tar|docker.m.daocloud.io/library/mongo:7.0|"
  "04-rabbitmq-3.13-alpine.tar|docker.m.daocloud.io/library/rabbitmq:3.13-management-alpine|"
  "05-nacos-2.5.1.tar|docker.m.daocloud.io/nacos/nacos-server:v2.5.1|"
  "06-postgres-16-alpine.tar|docker.m.daocloud.io/library/postgres:16-alpine|postgres:16-alpine"
  "07-elasticsearch-8.18.0.tar|docker.m.daocloud.io/library/elasticsearch:8.18.0|"
  "08-milvus-3.0.5.tar|docker.m.daocloud.io/milvusdb/milvus:v3.0.5|milvusdb/milvus:v3.0.5"
  "09-minio-2024-12-18.tar|docker.m.daocloud.io/milvusdb/minio:RELEASE.2024-12-18T13-15-44Z|milvusdb/minio:RELEASE.2024-12-18T13-15-44Z"
  "10-maven-3.9.9.tar|docker.m.daocloud.io/library/maven:3.9.9-eclipse-temurin-17|"
  "11-temurin-17-jre.tar|docker.m.daocloud.io/library/eclipse-temurin:17-jre-jammy|"
  "12-nginx-1.28-alpine.tar|docker.m.daocloud.io/library/nginx:1.28-alpine|"
  "13-etcd-3.5.25.tar|quay.io/coreos/etcd:v3.5.25|"
  "14-mall-swarm-minio-2025-07-23.tar|mall-swarm/minio:RELEASE.2025-07-23T15-54-02Z|"
)

# 三套编排真正用到的 11 个镜像（maven / jre / nginx 只在服务器上构建 Java 时才用）
RUNTIME_REFS=(
  "docker.m.daocloud.io/library/mysql:8.0.35"
  "docker.m.daocloud.io/library/redis:7.4-alpine"
  "docker.m.daocloud.io/library/mongo:7.0"
  "docker.m.daocloud.io/library/rabbitmq:3.13-management-alpine"
  "docker.m.daocloud.io/nacos/nacos-server:v2.5.1"
  "docker.m.daocloud.io/library/elasticsearch:8.18.0"
  "mall-swarm/minio:RELEASE.2025-07-23T15-54-02Z"
  "postgres:16-alpine"
  "milvusdb/milvus:v3.0.5"
  "milvusdb/minio:RELEASE.2024-12-18T13-15-44Z"
  "quay.io/coreos/etcd:v3.5.25"
)

# ---------------- 参数 ----------------
FORCE_RESTORE=0
RESTORE_MODE="auto"   # auto | force | skip
SKIP_LOAD=0
SKIP_VERIFY=0
ASSUME_YES=0

usage() {
  # 打印文件头的注释块（从第 2 行到第一个非注释行为止）
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force-restore) RESTORE_MODE="force"; FORCE_RESTORE=1 ;;
    --skip-restore) RESTORE_MODE="skip" ;;
    --skip-load) SKIP_LOAD=1 ;;
    --skip-verify) SKIP_VERIFY=1 ;;
    --yes| -y) ASSUME_YES=1 ;;
    --offline-dir=*) OFFLINE_DIR="${1#*=}" ;;
    -h| --help) usage ;;
    *) printf '[错误] 未知参数：%s（用 -h 看用法）\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# ---------------- 输出样式 ----------------
if [ -t 1 ]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
  C_CYN=$'\033[1;36m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''; C_OFF=''
fi

info() { printf '  %s\n' "$*"; }
step() { printf '\n%s==== %s ====%s\n' "$C_CYN" "$*" "$C_OFF"; }
warn() { printf '%s  [警告] %s%s\n' "$C_YEL" "$*" "$C_OFF" >&2; }
FAILURES=()
fail() { printf '%s  [失败] %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; FAILURES+=("$*"); }
die() { printf '%s[错误] %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }

# ---------------- 环境初始化 ----------------
SUDO=()
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo > /dev/null 2>&1 || die "非 root 且没有 sudo，请用 root 执行"
  SUDO=(sudo)
fi

DOCKER=(docker)
if ! docker info > /dev/null 2>&1; then
  DOCKER=("${SUDO[@]}" docker)
fi
"${DOCKER[@]}" info > /dev/null 2>&1 || die "无法访问 Docker 守护进程：请执行 systemctl start docker，或用 sudo bash deploy.sh"

if ! "${DOCKER[@]}" compose version > /dev/null 2>&1; then
  die "缺少 docker compose v2 插件（不是 docker-compose v1）。安装：apt-get install -y docker-compose-v2"
fi

if [ ! -d "$OFFLINE_DIR" ]; then
  die "找不到离线包目录：$OFFLINE_DIR（用 OFFLINE_DIR=/实际路径 指定，或把整个 offline 目录上传到 $SCRIPT_DIR/../offline）"
fi
OFFLINE_DIR="$(cd -- "$OFFLINE_DIR" && pwd -P)"
IMAGE_DIR="$OFFLINE_DIR/images"
DATA_DIR="$OFFLINE_DIR/data"
SRC_CONFIG="$OFFLINE_DIR/server-config"

[ -d "$IMAGE_DIR" ] || die "离线包缺少 images/ 目录"
[ -d "$DATA_DIR" ] || die "离线包缺少 data/ 目录"
[ -d "$SRC_CONFIG" ] || die "离线包缺少 server-config/ 目录（没有它容器起不来）"

printf '离线包：%s\n' "$OFFLINE_DIR"
printf '部署到：%s\n' "$TARGET_BASE"

# ---------------- 工具函数 ----------------

# 取出某个编排里某个服务的容器 ID（不依赖容器命名规则，比硬编码 mall-swarm-mysql-1 稳）
resolve_ctr() { # $1=编排目录 $2=服务名
  local dir="$1" svc="$2" out=""
  [ -f "$dir/compose.deploy.yaml" ] || { printf ''; return 0; }
  out="$("${DOCKER[@]}" compose -f "$dir/compose.deploy.yaml" ps -aq "$svc" 2> /dev/null | head -n1 || true)"
  printf '%s' "$out"
}

# 等容器 healthy（带超时轮询，不死等）
wait_healthy() { # $1=编排目录 $2=服务名 $3=中文标签 $4=超时秒
  local dir="$1" svc="$2" label="$3" timeout="$4"
  local ctr state waited=0
  ctr="$(resolve_ctr "$dir" "$svc")"
  if [ -z "$ctr" ]; then
    fail "$label 没有容器（compose up 可能失败了），排查：${DOCKER[*]} compose -f $dir/compose.deploy.yaml logs --tail 100 $svc"
    return 1
  fi
  while :; do
    state="$("${DOCKER[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$ctr" 2> /dev/null || echo unknown)"
    case "$state" in
      healthy)
        info "$label 已就绪（等待 ${waited}s）"
        return 0
        ;;
      exited|dead)
        fail "$label 容器已退出（$state），排查：${DOCKER[*]} logs --tail 200 $ctr"
        return 1
        ;;
    esac
    if [ "$waited" -ge "$timeout" ]; then
      fail "$label 等待超时（${timeout}s，当前状态 $state），排查：${DOCKER[*]} logs --tail 200 $ctr"
      return 1
    fi
    if [ $((waited % 30)) -eq 0 ]; then
      printf '  … 等待 %s（%ss/%ss，当前 %s）\n' "$label" "$waited" "$timeout" "$state"
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

mysql_table_count() { # $1=容器ID
  printf "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='mall';\n" \
    | "${DOCKER[@]}" exec -i "$1" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N --default-character-set=utf8mb4' 2> /dev/null \
    | tr -d '[:space:]'
}

pg_table_count() { # $1=容器ID
  "${DOCKER[@]}" exec -i "$1" psql -q -U mall_agent_owner -d mall_agent -tAc \
    "select count(*) from information_schema.tables where table_schema='public'" 2> /dev/null \
    | tr -d '[:space:]'
}

mongo_databases() { # $1=容器ID
  "${DOCKER[@]}" exec -i "$1" mongosh --quiet --eval 'db.getMongo().getDBNames().join(",")' 2> /dev/null \
    | tr -d '\r'
}

# =============================================================================
# 1/7 完整性校验
# =============================================================================
step "1/7 校验离线包完整性（sha256）"

if [ "$SKIP_VERIFY" -eq 1 ]; then
  warn "已按 --skip-verify 跳过校验（传输不完整时会在后面报奇怪的错，谨慎使用）"
else
  if [ ! -f "$OFFLINE_DIR/SHA256SUMS.txt" ]; then
    die "缺少 $OFFLINE_DIR/SHA256SUMS.txt，无法校验"
  fi
  info "对 18 个文件做 sha256sum -c（3 GB，约 10-30 秒）…"
  if (cd "$OFFLINE_DIR" && sha256sum -c SHA256SUMS.txt > /tmp/mall-sha256.log 2>&1); then
    info "校验通过（$(grep -c ': OK$' /tmp/mall-sha256.log || true) 个文件）"
  else
    printf '%s' "$C_RED"
    grep -v ': OK$' /tmp/mall-sha256.log | head -n 10
    printf '%s' "$C_OFF"
    die "校验失败。上面列出的文件不完整，请用 scp/rsync 重新上传（日志：/tmp/mall-sha256.log）"
  fi
fi

# =============================================================================
# 2/7 加载镜像
# =============================================================================
step "2/7 加载离线镜像"

if [ "$SKIP_LOAD" -eq 1 ]; then
  warn "已按 --skip-load 跳过镜像加载"
else
  loaded=0
  skipped=0
  for entry in "${IMAGES[@]}"; do
    IFS='|' read -r tarfile ref1 ref2 <<< "$entry"
    tarfile="${tarfile:-}"; ref1="${ref1:-}"; ref2="${ref2:-}"
    [ -n "$tarfile" ] || continue

    if "${DOCKER[@]}" image inspect "$ref1" > /dev/null 2>&1 \
      || { [ -n "$ref2" ] && "${DOCKER[@]}" image inspect "$ref2" > /dev/null 2>&1; }; then
      info "已有镜像 $ref1，跳过"
      skipped=$((skipped + 1))
      continue
    fi

    [ -f "$IMAGE_DIR/$tarfile" ] || die "缺少镜像文件：$IMAGE_DIR/$tarfile"
    printf '  ==> 加载 %-38s (%s)\n' "$tarfile" "$(du -h "$IMAGE_DIR/$tarfile" | cut -f1)"
    if ! "${DOCKER[@]}" load -i "$IMAGE_DIR/$tarfile" > /tmp/mall-image-load.log 2>&1; then
      tail -n 5 /tmp/mall-image-load.log >&2
      die "镜像 $tarfile 加载失败，排查：${DOCKER[*]} load -i $IMAGE_DIR/$tarfile"
    fi
    grep -E 'Loaded image|Loaded image ID' /tmp/mall-image-load.log | sed 's/^/      /' || true
    loaded=$((loaded + 1))
  done
  info "本次加载 ${loaded} 个，跳过 ${skipped} 个"
fi

# 2.1 补短名 tag：两套编排用的是官方短名，离线包里的 tag 带 docker.m.daocloud.io/ 前缀
step "2.1/7 补写镜像短名 tag"

tag_short() { # $1=源引用 $2=短名
  local src="$1" dst="$2"
  if "${DOCKER[@]}" image inspect "$dst" > /dev/null 2>&1; then
    info "$dst 已存在"
    return 0
  fi
  if "${DOCKER[@]}" image inspect "$src" > /dev/null 2>&1; then
    if "${DOCKER[@]}" tag "$src" "$dst" 2> /dev/null; then
      info "tagged $dst"
    else
      warn "打短名 tag 失败：$dst（源自 $src）"
    fi
  else
    warn "找不到 $src，无法生成短名 $dst（稍后统一校验时会报出来）"
  fi
}

tag_short "docker.m.daocloud.io/library/postgres:16-alpine" "postgres:16-alpine"
tag_short "docker.m.daocloud.io/milvusdb/milvus:v3.0.5" "milvusdb/milvus:v3.0.5"
tag_short "docker.m.daocloud.io/milvusdb/minio:RELEASE.2024-12-18T13-15-44Z" "milvusdb/minio:RELEASE.2024-12-18T13-15-44Z"

# 2.2 三套编排实际引用的 11 个镜像必须全部就位，否则容器起不来
missing=0
for ref in "${RUNTIME_REFS[@]}"; do
  if "${DOCKER[@]}" image inspect "$ref" > /dev/null 2>&1; then
    printf '  %s[OK]%s   %s\n' "$C_GRN" "$C_OFF" "$ref"
  else
    printf '  %s[MISS]%s %s\n' "$C_RED" "$C_OFF" "$ref"
    missing=$((missing + 1))
  fi
done
[ "$missing" -eq 0 ] || die "有 ${missing} 个编排依赖的镜像缺失，容器起不来。请确认离线包完整后重跑"

# =============================================================================
# 3/7 内核参数（ES 8 硬性要求）
# =============================================================================
step "3/7 内核参数 vm.max_map_count（Elasticsearch 8 需要 ≥262144）"

cur_mmc="$(sysctl -n vm.max_map_count 2> /dev/null || echo 0)"
if [ "${cur_mmc:-0}" -ge 262144 ]; then
  info "vm.max_map_count=$cur_mmc，已满足"
else
  warn "vm.max_map_count=$cur_mmc 偏低，正在调高到 262144（不改的话 ES 容器会反复重启）"
  if "${SUDO[@]}" sysctl -w vm.max_map_count=262144 > /dev/null 2>&1; then
    printf 'vm.max_map_count = 262144\n' | "${SUDO[@]}" tee /etc/sysctl.d/99-mall-demo.conf > /dev/null
    info "已调整并写入 /etc/sysctl.d/99-mall-demo.conf（重启后仍生效）"
  else
    warn "自动调整失败。请手工执行：sudo sysctl -w vm.max_map_count=262144"
    fail "vm.max_map_count 未满足，Elasticsearch 可能起不来"
  fi
fi

# =============================================================================
# 4/7 铺开编排目录
# =============================================================================
step "4/7 铺开三套编排到 $TARGET_BASE"

sync_tree() { # $1=源目录 $2=目标目录（保留权限与执行位，幂等覆盖）
  local src="$1" dst="$2"
  [ -d "$src" ] || die "缺少源目录：$src"
  "${SUDO[@]}" mkdir -p "$dst"
  "${SUDO[@]}" cp -a "$src"/. "$dst"/
}

# mall-swarm：只铺 compose.yaml + es-ik + minio-runtime。
# 刻意不铺 init/：compose 里 ./init:/docker-entrypoint-initdb.d 会先建表，
# 再导 dump 就撞 "table already exists"，所以本次走 dump 恢复路线，不碰 init。
sync_tree "$SRC_CONFIG/mall-swarm/es-ik" "$SWARM_DIR/es-ik"
sync_tree "$SRC_CONFIG/mall-swarm/minio-runtime" "$SWARM_DIR/minio-runtime"
"${SUDO[@]}" install -m 0644 "$SRC_CONFIG/mall-swarm/compose.yaml" "$SWARM_DIR/compose.yaml"
info "$SWARM_DIR/  ← compose.yaml + es-ik/ + minio-runtime/（不含 init/）"

# mall-agent：整目录（compose.yaml + .env）
sync_tree "$SRC_CONFIG/mall-agent" "$AGENT_DIR"
info "$AGENT_DIR/  ← compose.yaml + .env"

# mall-agent-vector：整目录（compose.yaml + .env + user.yaml + user.initial-namespace.yaml）
sync_tree "$SRC_CONFIG/mall-agent-vector" "$VECTOR_DIR"
info "$VECTOR_DIR/  ← compose.yaml + .env + user*.yaml"

[ -f "$SWARM_DIR/es-ik/plugin-descriptor.properties" ] || die "es-ik 插件没铺成功，ES 会缺中文分词"
[ -f "$AGENT_DIR/.env" ] || die "$AGENT_DIR/.env 缺失，PostgreSQL 起不来"
[ -f "$VECTOR_DIR/.env" ] || die "$VECTOR_DIR/.env 缺失，Milvus 栈起不来"

# =============================================================================
# 5/7 生成"可直接部署"的 compose 副本
# =============================================================================
step "5/7 生成 compose.deploy.yaml（去掉宿主目录依赖）"

# 用 sed 生成副本而不是 compose 的 !override 叠加，原因：
#   !override / !reset 需要 Docker Compose ≥ 2.24.4，老服务器上会直接报 unknown tag，
#   而 sed 对所有 v2 版本都一样稳。两份改动都是"删行"，改完立刻 grep 自检。
make_deploy_compose() { # $1=编排目录
  local dir="$1" name
  name="$(basename "$dir")"
  "${SUDO[@]}" cp -f "$dir/compose.yaml" "$dir/compose.deploy.yaml"
  # (1) 删掉 init SQL 挂载：走 dump 恢复，不能让容器启动时先跑建表脚本
  # (2) 删掉 build 段：镜像来自离线包，留着 build 段等于给 --build 留后门
  "${SUDO[@]}" sed -i \
    -e '/docker-entrypoint-initdb\.d/d' \
    -e '/^    build:$/,+1d' \
    "$dir/compose.deploy.yaml"

  if "${SUDO[@]}" grep -q 'docker-entrypoint-initdb\.d' "$dir/compose.deploy.yaml"; then
    die "$name：init 挂载没删掉，会导致「表已存在」冲突"
  fi
  if "${SUDO[@]}" grep -q '^    build:$' "$dir/compose.deploy.yaml"; then
    die "$name：build 段没删掉，可能触发无外网构建"
  fi
  if ! "${DOCKER[@]}" compose -f "$dir/compose.deploy.yaml" config -q 2> /tmp/mall-compose-config.log; then
    cat /tmp/mall-compose-config.log >&2
    die "$name：compose.deploy.yaml 语法校验失败"
  fi
  info "$name/compose.deploy.yaml 就绪（无 init 挂载、无 build 段、语法通过）"
}

make_deploy_compose "$SWARM_DIR"
make_deploy_compose "$AGENT_DIR"
make_deploy_compose "$VECTOR_DIR"

# =============================================================================
# 6/7 启动三套编排
# =============================================================================
step "6/7 启动容器（不加 --build）"

if [ "$RESTORE_MODE" = "force" ] && [ "$ASSUME_YES" -eq 0 ]; then
  warn "--force-restore 会覆盖服务器上现有的数据库内容"
  printf '  继续请按 Ctrl-C 中断，5 秒后自动开始…\n'
  sleep 5
fi

compose_up() { # $1=编排目录
  local dir="$1"
  info "up -d  $(basename "$dir")"
  if ! "${DOCKER[@]}" compose -f "$dir/compose.deploy.yaml" up -d --remove-orphans 2>&1 | sed 's/^/      /'; then
    fail "$(basename "$dir") 启动失败，排查：${DOCKER[*]} compose -f $dir/compose.deploy.yaml up -d"
    return 1
  fi
}

compose_up "$SWARM_DIR" || true
compose_up "$AGENT_DIR" || true
compose_up "$VECTOR_DIR" || true

info "等待 MySQL / PostgreSQL 进入 healthy（首次初始化需要 1-3 分钟）"
wait_healthy "$SWARM_DIR" mysql "MySQL" "$MYSQL_WAIT_TIMEOUT" || true
wait_healthy "$AGENT_DIR" postgres "PostgreSQL" "$PG_WAIT_TIMEOUT" || true

# =============================================================================
# 7/7 恢复数据快照
# =============================================================================
step "7/7 恢复数据快照"

restore_mysql() { # $1=容器ID
  local ctr="$1" dump="$DATA_DIR/01-mysql-all.sql.gz" n
  [ -f "$dump" ] || { fail "缺少 $dump"; return 1; }
  info "导入 $(basename "$dump")（$(du -h "$dump" | cut -f1)，约 1-2 分钟）…"
  # 前提：这份 dump 是 --all-databases 导出，连 mysql 系统库（含用户密码哈希）一起导。
  # 本部署刻意沿用旧环境密码（compose.yaml 明文与 deployment/secrets.json 一致），
  # 所以导入后 root/mall 的密码不会被改坏，不需要 ALTER USER。
  if ! gunzip -c "$dump" | "${DOCKER[@]}" exec -i "$ctr" sh -c \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot --default-character-set=utf8mb4'; then
    fail "MySQL 导入失败，排查：gunzip -c $dump | ${DOCKER[*]} exec -i $ctr sh -c 'mysql -uroot -p\$MYSQL_ROOT_PASSWORD'"
    return 1
  fi
  # dump 覆盖了 mysql.user 表，刷新一次权限缓存
  printf 'FLUSH PRIVILEGES;\n' | "${DOCKER[@]}" exec -i "$ctr" sh -c \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot' > /dev/null 2>&1 || warn "FLUSH PRIVILEGES 执行失败，可忽略但建议手工补一次"

  n="$(mysql_table_count "$ctr" || echo 0)"
  if [ "${n:-0}" -ge "$MYSQL_TABLE_MIN" ]; then
    info "MySQL 恢复完成：mall 库 ${n} 张表（基线 ${MYSQL_TABLE_EXPECT}）"
  else
    fail "MySQL 恢复后 mall 库只有 ${n} 张表（期望 ≈${MYSQL_TABLE_EXPECT}），排查：${DOCKER[*]} logs --tail 200 $ctr"
  fi
}

restore_pg() { # $1=容器ID
  local ctr="$1" dump="$DATA_DIR/02-postgres-all.sql.gz" log n
  [ -f "$dump" ] || { fail "缺少 $dump"; return 1; }
  log="$(mktemp)"
  info "导入 $(basename "$dump")（$(du -h "$dump" | cut -f1)，约 30-90 秒）…"
  # 两处兼容处理：
  # 1) 较新版 psql 会在 dump 里写 \restrict / \unrestrict 元命令，老版本 psql 会报
  #    "invalid command"，这里直接滤掉（这两个只是屏蔽 \! 的保护标记，不含数据）。
  # 2) 不设 ON_ERROR_STOP：dump 里的 CREATE ROLE / CREATE DATABASE 在角色/库已存在时
  #    会报 already exists，属预期错误，后面单独统计。
  gunzip -c "$dump" \
    | sed -e '/^\\restrict /d' -e '/^\\unrestrict /d' \
    | "${DOCKER[@]}" exec -i "$ctr" psql -v ON_ERROR_STOP=0 -q -U mall_agent_owner -d postgres \
      > "$log" 2>&1 || true

  local fatal errors benign real_errors
  fatal="$(grep -cE '^(psql:.*error|FATAL:)' "$log" 2> /dev/null || true)"
  errors="$(grep -c '^ERROR:' "$log" 2> /dev/null || true)"
  benign="$(grep '^ERROR:' "$log" 2> /dev/null | grep -c 'already exists' || true)"
  real_errors=$((errors - benign))

  if [ "${fatal:-0}" -gt 0 ]; then
    tail -n 10 "$log" >&2
    fail "PostgreSQL 连接/导入失败，排查：tail -50 $log 或 ${DOCKER[*]} logs --tail 200 $ctr"
    rm -f "$log" 2> /dev/null || true
    return 1
  fi
  if [ "$real_errors" -gt 0 ]; then
    warn "PostgreSQL 导入有 ${real_errors} 条非预期错误："
    grep '^ERROR:' "$log" | grep -v 'already exists' | head -n 10 >&2
    fail "PostgreSQL 导入不完整（日志：$log）"
    return 1
  fi
  info "PostgreSQL 导入完成（已忽略 ${benign} 条 role/database already exists，属预期）"

  # 保险：把 owner 密码重新对齐到 compose 的 .env（dump 里带的是旧环境的密码哈希，
  # 值相同则是无操作；万一不一致，这一步保证本机 .run/agent-env.json 仍能连上）。
  local pg_pw esc
  pg_pw="$("${SUDO[@]}" sed -n 's/^POSTGRES_PASSWORD=//p' "$AGENT_DIR/.env" 2> /dev/null | head -n1 || true)"
  if [ -n "${pg_pw:-}" ]; then
    esc="${pg_pw//\'/\'\'}"
    if printf "ALTER ROLE mall_agent_owner WITH PASSWORD '%s';\n" "$esc" \
      | "${DOCKER[@]}" exec -i "$ctr" psql -q -U mall_agent_owner -d postgres > /dev/null 2>&1; then
      info "已把 mall_agent_owner 密码对齐到 .env（与 dump 内一致时为空操作）"
    else
      warn "owner 密码对齐失败，如本机智能体连不上 PG，检查 $AGENT_DIR/.env 与 dump 里的密码是否一致"
    fi
  fi

  n="$(pg_table_count "$ctr" || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then
    info "PostgreSQL 恢复完成：mall_agent 库 public 下 ${n} 张表"
  else
    fail "PostgreSQL 的 mall_agent 库里没有表，导入没生效"
  fi
  rm -f "$log" 2> /dev/null || true
}

restore_mongo() { # $1=容器ID
  local ctr="$1" dump="$DATA_DIR/03-mongo-all.gz" dbs
  [ -f "$dump" ] || { fail "缺少 $dump"; return 1; }
  info "恢复 mall-port 库（快照 1.3 KB，只有少量收藏/浏览记录）…"
  if ! "${DOCKER[@]}" exec -i "$ctr" sh -c 'exec mongorestore --archive --gzip --drop' < "$dump" > /dev/null 2>&1; then
    fail "MongoDB 恢复失败，排查：${DOCKER[*]} exec -i $ctr mongorestore --archive --gzip --drop < $dump"
    return 1
  fi
  dbs="$(mongo_databases "$ctr" || true)"
  case ",$dbs," in
    *",mall-port,"*) info "MongoDB 恢复完成：mall-port 库已存在（现有库：$dbs）" ;;
    *) fail "MongoDB 恢复后没看到 mall-port 库（现有库：${dbs:-空}）" ;;
  esac
}

if [ "$RESTORE_MODE" = "skip" ]; then
  warn "已按 --skip-restore 跳过数据恢复"
else
  # --- MySQL ---
  mysql_ctr="$(resolve_ctr "$SWARM_DIR" mysql)"
  if [ -z "$mysql_ctr" ]; then
    fail "找不到 MySQL 容器，跳过 MySQL 恢复"
  else
    cur="$(mysql_table_count "$mysql_ctr" || echo 0)"
    if [ "${cur:-0}" -ge "$MYSQL_TABLE_MIN" ] && [ "$FORCE_RESTORE" -eq 0 ]; then
      info "MySQL mall 库已有 ${cur} 张表，跳过恢复（要覆盖请加 --force-restore）"
    else
      restore_mysql "$mysql_ctr"
    fi
  fi

  # --- PostgreSQL ---
  pg_ctr="$(resolve_ctr "$AGENT_DIR" postgres)"
  if [ -z "$pg_ctr" ]; then
    fail "找不到 PostgreSQL 容器，跳过恢复"
  else
    cur="$(pg_table_count "$pg_ctr" || echo 0)"
    if [ "${cur:-0}" -gt 0 ] && [ "$FORCE_RESTORE" -eq 0 ]; then
      info "PostgreSQL mall_agent 库已有 ${cur} 张表，跳过恢复（要覆盖请加 --force-restore）"
    else
      restore_pg "$pg_ctr"
    fi
  fi

  # --- MongoDB ---
  mongo_ctr="$(resolve_ctr "$SWARM_DIR" mongo)"
  if [ -z "$mongo_ctr" ]; then
    fail "找不到 MongoDB 容器，跳过恢复"
  else
    dbs="$(mongo_databases "$mongo_ctr" || true)"
    case ",$dbs," in
      *",mall-port,"*)
        if [ "$FORCE_RESTORE" -eq 0 ]; then
          info "MongoDB mall-port 库已存在，跳过恢复（要覆盖请加 --force-restore）"
        else
          restore_mongo "$mongo_ctr"
        fi
        ;;
      *) restore_mongo "$mongo_ctr" ;;
    esac
  fi

  info "MinIO 对象数据（06-minio-data.tar.gz，37 KB）本次跳过：原环境几乎没往对象存储放东西，"
  info "商品图由本机 http://127.0.0.1:18080/demo-assets/ 提供，不依赖服务器 MinIO。"
  info "Milvus / Elasticsearch 没有数据快照，集合与索引由本机侧准备脚本在隧道通后重建。"
fi

# =============================================================================
# 容器状态总览
# =============================================================================
step "容器状态"

printf '  %-28s %-14s %s\n' "container" "service" "status"
for dir in "$SWARM_DIR" "$AGENT_DIR" "$VECTOR_DIR"; do
  [ -f "$dir/compose.deploy.yaml" ] || continue
  "${DOCKER[@]}" compose -f "$dir/compose.deploy.yaml" ps -a --format '{{.Name}}|{{.Service}}|{{.Status}}' 2> /dev/null \
    | while IFS='|' read -r ctr_name ctr_svc ctr_status; do
        [ -n "${ctr_name:-}" ] || continue
        printf '  %-28s %-14s %s\n' "$ctr_name" "$ctr_svc" "$ctr_status"
      done
done

# =============================================================================
# 汇总
# =============================================================================
printf '\n%s==== 部署结果 ====%s\n' "$C_CYN" "$C_OFF"
if [ "${#FAILURES[@]}" -gt 0 ]; then
  printf '%s有 %s 个步骤失败：%s\n' "$C_RED" "${#FAILURES[@]}" "$C_OFF" >&2
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f" >&2; done
  printf '\n先按上面的排查命令处理，再重跑 bash deploy.sh（幂等，不会重复导数据）。\n' >&2
  exit 1
fi

cat <<'EOF'

全部步骤完成。下一步：

  1) 跑验收：      bash verify.sh
  2) 本机改隧道目标：deployment/.dev-ssh.json 的 host/username/password 换成这台服务器
  3) 本机启动：    .\deployment\start-local.ps1
                  然后开 http://127.0.0.1:5173（H5 商城）/ http://127.0.0.1:5100（管理后台）

注意：中间件端口只绑 127.0.0.1，安全组只需要放行 22（SSH），其余端口一律不要开到公网。
EOF
exit 0
