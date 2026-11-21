#!/usr/bin/env bash
# =============================================================================
# mall 演示环境 · 服务器验收（只读，逐项 PASS/FAIL）
#
# 用法（在服务器上）：
#   bash verify.sh
#   TARGET_BASE=/srv bash verify.sh      # 编排没装在 /opt 时
#
# 退出码：0 = 全部 PASS（WARN 不算失败）；1 = 有 FAIL。
# 每条 FAIL 会附上可直接复制的排查命令。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET_BASE="${TARGET_BASE:-/opt}"

SWARM_DIR="$TARGET_BASE/mall-swarm"
AGENT_DIR="$TARGET_BASE/mall-agent"
VECTOR_DIR="$TARGET_BASE/mall-agent-vector"

# mall 库表数量基线：离线 dump 里实测 86 张，留容差
MYSQL_TABLE_EXPECT=86
MYSQL_TABLE_MIN=80

# 容器验收表：编排目录|服务名|中文名|期望健康度（healthy / none）|检查项名
CTRS=(
  "$SWARM_DIR|mysql|MySQL|healthy|ctr.mysql"
  "$SWARM_DIR|redis|Redis|healthy|ctr.redis"
  "$SWARM_DIR|mongo|MongoDB|none|ctr.mongo"
  "$SWARM_DIR|rabbitmq|RabbitMQ|healthy|ctr.rabbitmq"
  "$SWARM_DIR|nacos|Nacos|healthy|ctr.nacos"
  "$SWARM_DIR|elasticsearch|Elasticsearch|healthy|ctr.elasticsearch"
  "$SWARM_DIR|minio|MinIO|none|ctr.minio"
  "$AGENT_DIR|postgres|PostgreSQL|healthy|ctr.postgres"
  "$VECTOR_DIR|etcd|etcd(milvus)|healthy|ctr.etcd"
  "$VECTOR_DIR|minio|MinIO(milvus)|healthy|ctr.vector-minio"
  "$VECTOR_DIR|milvus|Milvus|healthy|ctr.milvus"
)

# 宿主机监听端口：端口|组件
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

row() { # $1=检查项(ASCII) $2=PASS/FAIL/WARN $3=说明
  local key="$1" status="$2" detail="$3" color="$C_GRN"
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) color="$C_RED"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    WARN) color="$C_YEL"; WARN_COUNT=$((WARN_COUNT + 1)) ;;
  esac
  printf '%-26s %s%-4s%s %s\n' "$key" "$color" "$status" "$C_OFF" "$detail"
}

hint() { HINTS+=("$1"); }
step() { printf '\n%s==== %s ====%s\n' "$C_CYN" "$*" "$C_OFF"; }

# ---------------- Docker 访问 ----------------
SUDO=()
if [ "$(id -u)" -ne 0 ] && command -v sudo > /dev/null 2>&1; then
  SUDO=(sudo)
fi
DOCKER=(docker)
if ! docker info > /dev/null 2>&1; then
  DOCKER=("${SUDO[@]}" docker)
fi

step "环境"
if "${DOCKER[@]}" info > /dev/null 2>&1; then
  row "docker.daemon" PASS "Docker 守护进程可访问"
else
  row "docker.daemon" FAIL "无法访问 Docker 守护进程"
  hint "systemctl status docker"
  printf '\n%sDocker 不可用，后续检查无法进行。%s\n' "$C_RED" "$C_OFF" >&2
  exit 1
fi

if "${DOCKER[@]}" compose version > /dev/null 2>&1; then
  row "docker.compose" PASS "Compose $("${DOCKER[@]}" compose version --short 2> /dev/null || echo v2)"
else
  row "docker.compose" FAIL "缺少 docker compose v2"
  hint "apt-get install -y docker-compose-v2"
fi

if command -v ss > /dev/null 2>&1; then
  row "cmd.ss" PASS "ss 可用（用于检查端口监听）"
else
  row "cmd.ss" WARN "没有 ss，端口检查退化为查 docker 端口映射"
  hint "apt-get install -y iproute2"
fi

for dir in "$SWARM_DIR" "$AGENT_DIR" "$VECTOR_DIR"; do
  name="$(basename "$dir")"
  if [ -f "$dir/compose.deploy.yaml" ]; then
    row "compose.$name" PASS "compose.deploy.yaml 存在"
  else
    row "compose.$name" FAIL "缺少 $dir/compose.deploy.yaml"
    hint "先执行 bash deploy.sh（它会生成 compose.deploy.yaml）"
  fi
done

# ---------------- 容器 ----------------
step "容器状态（11 个中间件）"

resolve_ctr() { # $1=编排目录 $2=服务名
  local dir="$1" svc="$2" out=""
  [ -f "$dir/compose.deploy.yaml" ] || { printf ''; return 0; }
  out="$("${DOCKER[@]}" compose -f "$dir/compose.deploy.yaml" ps -aq "$svc" 2> /dev/null | head -n1 || true)"
  printf '%s' "$out"
}

for entry in "${CTRS[@]}"; do
  IFS='|' read -r cdir csvc clabel cexpect ckey <<< "$entry"
  ctr="$(resolve_ctr "$cdir" "$csvc")"
  if [ -z "$ctr" ]; then
    row "$ckey" FAIL "$clabel 容器不存在"
    hint "${DOCKER[*]} compose -f $cdir/compose.deploy.yaml up -d   # 重新拉起 $(basename "$cdir")"
    continue
  fi
  status="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$ctr" 2> /dev/null || echo unknown)"
  health="$("${DOCKER[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$ctr" 2> /dev/null || echo none)"

  if [ "$status" != "running" ]; then
    row "$ckey" FAIL "$clabel 状态=$status（应为 running）"
    hint "${DOCKER[*]} logs --tail 100 $ctr   # 看 $clabel 为什么起不来"
  elif [ "$cexpect" = "healthy" ] && [ "$health" != "healthy" ]; then
    row "$ckey" FAIL "$clabel running 但健康=$health（应为 healthy）"
    hint "${DOCKER[*]} logs --tail 100 $ctr   # $clabel 健康检查未通过"
  elif [ "$health" = "none" ]; then
    row "$ckey" PASS "$clabel running（无健康检查）"
  else
    row "$ckey" PASS "$clabel running/healthy"
  fi
done

# 一次性初始化容器（Milvus 卷属主修正），跑完应为 exited 0
vinit="$(resolve_ctr "$VECTOR_DIR" volume-init)"
if [ -n "$vinit" ]; then
  vstate="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$vinit" 2> /dev/null || echo unknown)"
  vcode="$("${DOCKER[@]}" inspect -f '{{.State.ExitCode}}' "$vinit" 2> /dev/null || echo 1)"
  if [ "$vstate" = "exited" ] && [ "$vcode" = "0" ]; then
    row "ctr.volume-init" PASS "一次性初始化容器已正常退出（0）"
  else
    row "ctr.volume-init" FAIL "状态=$vstate 退出码=$vcode（应为 exited 0）"
    hint "${DOCKER[*]} logs --tail 50 $vinit"
  fi
else
  row "ctr.volume-init" WARN "未找到 volume-init 容器（Milvus 可能没起来）"
fi

# ---------------- 端口 ----------------
step "端口监听（全部应绑 127.0.0.1，靠 SSH 隧道访问）"

check_port() { # $1=端口 $2=组件
  local port="$1" name="$2" addrs=""
  if command -v ss > /dev/null 2>&1; then
    addrs="$(ss -Hltn "sport = :$port" 2> /dev/null | awk '{print $4}' | tr '\n' ' ' || true)"
    if printf '%s' "$addrs" | grep -q "127\.0\.0\.1:$port"; then
      row "port.$port" PASS "$name → 127.0.0.1:$port 监听中"
    elif [ -n "${addrs// /}" ]; then
      row "port.$port" FAIL "$name → 监听地址 [${addrs}]，期望 127.0.0.1:$port"
      hint "ss -ltnp | grep ':$port'   # 确认是否有其他进程占用，或有人把绑定改成了 0.0.0.0"
    else
      row "port.$port" FAIL "$name → 未监听 $port"
      hint "${DOCKER[*]} ps --format 'table {{.Names}}\t{{.Ports}}' | grep $port"
    fi
  else
    if "${DOCKER[@]}" ps --format '{{.Ports}}' 2> /dev/null | tr ',' '\n' | grep -q "127.0.0.1:${port}->"; then
      row "port.$port" PASS "$name → docker 映射 127.0.0.1:$port"
    else
      row "port.$port" FAIL "$name → 没有 127.0.0.1:$port 的映射"
      hint "${DOCKER[*]} ps --format 'table {{.Names}}\t{{.Ports}}'"
    fi
  fi
}

for item in "${PORTS[@]}"; do
  IFS='|' read -r port pname <<< "$item"
  check_port "$port" "$pname"
done

# ---------------- 数据 ----------------
step "数据完整性"

mysql_ctr="$(resolve_ctr "$SWARM_DIR" mysql)"
if [ -z "$mysql_ctr" ]; then
  row "mysql.db.mall" FAIL "MySQL 容器不存在，跳过数据检查"
else
  mall_db="$(printf "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='mall';\n" \
    | "${DOCKER[@]}" exec -i "$mysql_ctr" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N' 2> /dev/null \
    | tr -d '[:space:]' || true)"
  mall_db="$(printf '%s' "${mall_db:-0}" | tr -cd '0-9')"
  mall_db="${mall_db:-0}"
  if [ "${mall_db:-0}" -ge 1 ]; then
    row "mysql.db.mall" PASS "mall 库存在"
  else
    row "mysql.db.mall" FAIL "mall 库不存在"
    hint "gunzip -c <离线包>/data/01-mysql-all.sql.gz | ${DOCKER[*]} exec -i $mysql_ctr sh -c 'mysql -uroot -p\$MYSQL_ROOT_PASSWORD'"
  fi

  mtables="$(printf "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='mall';\n" \
    | "${DOCKER[@]}" exec -i "$mysql_ctr" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -N' 2> /dev/null \
    | tr -d '[:space:]' || true)"
  mtables="$(printf '%s' "${mtables:-0}" | tr -cd '0-9')"
  mtables="${mtables:-0}"
  if [ "$mtables" -ge "$MYSQL_TABLE_MIN" ]; then
    if [ "$mtables" -eq "$MYSQL_TABLE_EXPECT" ]; then
      row "mysql.tables" PASS "mall 库 ${mtables} 张表（基线 ${MYSQL_TABLE_EXPECT}）"
    else
      row "mysql.tables" PASS "mall 库 ${mtables} 张表（基线 ${MYSQL_TABLE_EXPECT}，有少量差异）"
    fi
  else
    row "mysql.tables" FAIL "mall 库只有 ${mtables} 张表（期望 ≈${MYSQL_TABLE_EXPECT}），dump 没导全"
    hint "bash deploy.sh --force-restore   # 重新导入 MySQL 快照"
  fi
fi

pg_ctr="$(resolve_ctr "$AGENT_DIR" postgres)"
if [ -z "$pg_ctr" ]; then
  row "pg.db.mall_agent" FAIL "PostgreSQL 容器不存在，跳过数据检查"
else
  pg_db="$("${DOCKER[@]}" exec -i "$pg_ctr" psql -q -U mall_agent_owner -d postgres -tAc \
    "select count(*) from pg_database where datname='mall_agent'" 2> /dev/null | tr -d '[:space:]' || true)"
  pg_db="$(printf '%s' "${pg_db:-0}" | tr -cd '0-9')"
  pg_db="${pg_db:-0}"
  if [ "${pg_db:-0}" -ge 1 ]; then
    row "pg.db.mall_agent" PASS "mall_agent 库存在"
  else
    row "pg.db.mall_agent" FAIL "mall_agent 库不存在"
    hint "bash deploy.sh --force-restore   # 重新导入 PostgreSQL 快照"
  fi

  ptables="$("${DOCKER[@]}" exec -i "$pg_ctr" psql -q -U mall_agent_owner -d mall_agent -tAc \
    "select count(*) from information_schema.tables where table_schema='public'" 2> /dev/null | tr -d '[:space:]' || true)"
  ptables="$(printf '%s' "${ptables:-0}" | tr -cd '0-9')"
  ptables="${ptables:-0}"
  if [ "$ptables" -gt 0 ]; then
    row "pg.tables" PASS "mall_agent 库 public 下 ${ptables} 张表"
  else
    row "pg.tables" FAIL "mall_agent 库里没有表"
    hint "bash deploy.sh --force-restore   # 重新导入 PostgreSQL 快照"
  fi
fi

mongo_ctr="$(resolve_ctr "$SWARM_DIR" mongo)"
if [ -z "$mongo_ctr" ]; then
  row "mongo.db.mall-port" FAIL "MongoDB 容器不存在，跳过数据检查"
else
  mdbs="$("${DOCKER[@]}" exec -i "$mongo_ctr" mongosh --quiet --eval 'db.getMongo().getDBNames().join(",")' 2> /dev/null | tr -d '\r' || true)"
  case ",${mdbs:-}," in
    *",mall-port,"*) row "mongo.db.mall-port" PASS "mall-port 库存在（现有库：${mdbs}）" ;;
    *)
      row "mongo.db.mall-port" FAIL "mall-port 库不存在（现有库：${mdbs:-空}）"
      hint "bash deploy.sh --force-restore   # 重新导入 MongoDB 快照"
      ;;
  esac
fi

# ---------------- 服务可用性 ----------------
step "服务可用性"

curl_ok() { curl -fsS --max-time 6 "$@" > /dev/null 2>&1; }
curl_body() { curl -sS --max-time 6 "$@" 2> /dev/null || true; }

# Elasticsearch 集群状态
es_ctr="$(resolve_ctr "$SWARM_DIR" elasticsearch)"
es_body="$(curl_body http://127.0.0.1:9200/_cluster/health)"
es_status="$(printf '%s' "$es_body" | grep -o '"status":"[a-z]*"' | head -n1 | cut -d'"' -f4 || true)"
case "${es_status:-}" in
  green|yellow)
    row "es.cluster" PASS "集群状态 ${es_status}"
    if [ "$es_status" = "yellow" ]; then
      hint "yellow 是单节点副本无处分配的常态，不影响演示，无需处理"
    fi
    ;;
  red)
    row "es.cluster" FAIL "集群状态 red（有主分片未分配）"
    hint "curl -s 'http://127.0.0.1:9200/_cluster/allocation/explain?pretty'"
    ;;
  *)
    row "es.cluster" FAIL "拿不到集群状态（接口无响应）"
    hint "curl -s http://127.0.0.1:9200/ ; ${DOCKER[*]} logs --tail 100 ${es_ctr:-<es容器>}"
    ;;
esac

# IK 中文分词插件
es_plugins="$(curl_body 'http://127.0.0.1:9200/_cat/plugins')"
if printf '%s' "$es_plugins" | grep -q 'analysis-ik'; then
  row "es.ik-plugin" PASS "中文分词插件 analysis-ik 已加载"
else
  row "es.ik-plugin" FAIL "没有 analysis-ik 插件（中文搜索会全废）"
  hint "ls -l $SWARM_DIR/es-ik/plugin-descriptor.properties ; ${DOCKER[*]} restart ${es_ctr:-<es容器>}"
fi

# Nacos
if curl_ok http://127.0.0.1:8848/nacos/v1/console/health/readiness; then
  row "nacos.http" PASS "8848 readiness 就绪（控制台 http://127.0.0.1:18848/nacos，隧道后访问）"
else
  row "nacos.http" FAIL "8848 readiness 不通"
  hint "curl -v http://127.0.0.1:8848/nacos/v1/console/health/readiness 及 nacos 容器日志"
fi

# MinIO
if curl_ok http://127.0.0.1:9000/minio/health/live; then
  row "minio.http" PASS "9000 存活探针通过"
else
  row "minio.http" FAIL "9000 存活探针不通"
  hint "curl -v http://127.0.0.1:9000/minio/health/live 及 minio 容器日志"
fi

# Milvus 健康端口（顺带确认向量栈可用）
milvus_ctr="$(resolve_ctr "$VECTOR_DIR" milvus)"
if curl_ok http://127.0.0.1:19091/healthz; then
  row "milvus.healthz" PASS "19091 /healthz 通过"
else
  row "milvus.healthz" WARN "19091 /healthz 未通过（Milvus 首次启动要 90 秒预热，稍等再跑一次）"
  hint "${DOCKER[*]} logs --tail 100 ${milvus_ctr:-<milvus容器>}"
fi

# ---------------- 汇总 ----------------
step "验收结果"
printf 'PASS %s 个，WARN %s 个，FAIL %s 个\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

if [ "${#HINTS[@]}" -gt 0 ]; then
  printf '\n排查命令：\n'
  seen=""
  for h in "${HINTS[@]}"; do
    case "$seen" in *"|$h|"*) continue ;; esac
    seen="${seen}|${h}|"
    printf '  - %s\n' "$h"
  done
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
  printf '\n%s有 %s 项 FAIL，先按上面的排查命令处理，再重跑 bash verify.sh。%s\n' "$C_RED" "$FAIL_COUNT" "$C_OFF" >&2
  exit 1
fi

printf '\n%s服务器侧验收全部通过。%s\n' "$C_GRN" "$C_OFF"
cat <<'EOF'

下一步（在本机 Windows 上）：
  1) 把 deployment/.dev-ssh.json 的 host/username/password 换成这台服务器
  2) .\deployment\start-local.ps1
  3) 打开 http://127.0.0.1:5173（H5 商城）/ http://127.0.0.1:5100（管理后台）
     网关 8201、智能体 8099 由本机进程提供，不需要在服务器上开端口
EOF
exit 0
