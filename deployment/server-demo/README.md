# 中间件服务器部署包（演示版）

给**演示用**的 Linux 服务器准备的一套脚本：把 11 个中间件容器（MySQL / Redis / MongoDB /
RabbitMQ / Nacos / Elasticsearch / MinIO / PostgreSQL / etcd / Milvus×2）从离线包拉起来，
并恢复三份数据快照。

**业务进程都跑在你本机**（6 个 Java 服务 + Python 智能体 + 2 个前端），服务器只当"数据库机房"。
本机通过 `deployment/dev.cjs` 内置的 SSH 隧道连服务器，所以**服务器只有 22 端口需要对外**。

```
本机 Windows                                     Linux 服务器
┌──────────────────────────────┐                ┌──────────────────────────────┐
│ 5173 H5 商城 / 5100 管理后台  │                │ 127.0.0.1:3306  MySQL        │
│ 8201 网关 / 8099 智能体 API   │  SSH 隧道(22)  │ 127.0.0.1:6379  Redis        │
│        ↓ 127.0.0.1:13306 …   │ ─────────────► │ 127.0.0.1:27017 MongoDB      │
│  deployment/dev.cjs 转发      │                │ 127.0.0.1:5672  RabbitMQ     │
└──────────────────────────────┘                │ 127.0.0.1:8848  Nacos        │
                                                 │ 127.0.0.1:9200  ES + IK      │
                                                 │ 127.0.0.1:9000  MinIO        │
                                                 │ 127.0.0.1:15432 PostgreSQL   │
                                                 │ 127.0.0.1:19530 Milvus 栈    │
                                                 └──────────────────────────────┘
```

## 一、服务器规格与安全组

| 项目 | 要求 | 说明 |
| --- | --- | --- |
| CPU | ≥ 2 核（建议 4） | Milvus 单容器就占 2 核 |
| 内存 | ≥ 12 GB（建议 16） | 三套编排 `mem_limit` 合计约 12.6 GB |
| 磁盘 | ≥ 40 GB 可用 | 离线镜像 3 GB，解压后约 8 GB |
| 系统 | Ubuntu 22.04 / 24.04 | 需要 Docker + Compose **v2**、bash ≥ 4.4 |
| 入站端口 | **只开 22（SSH）** | 其余端口全部只绑 `127.0.0.1`，走隧道 |

> 安全组里千万不要给 3306 / 6379 / 27017 / 9200 / 15432 开公网。这些库的密码是明文写在
> compose 里的固定值，开出去等于公开。

## 二、三步走

### 1. 上传离线包（本机执行，3 GB 左右）

```powershell
scp -r D:\newshop\deployment\offline  root@<新服务器IP>:/root/offline
```

连同本目录一起传上去（脚本要在 `server-demo/` 的兄弟目录找到 `../offline`）：

```powershell
scp -r D:\newshop\deployment\server-demo  root@<新服务器IP>:/root/server-demo
```

服务器上的目录结构应是这样：

```
/root/offline/          images/ data/ server-config/ SHA256SUMS.txt
/root/server-demo/      preflight.sh deploy.sh verify.sh 本文件
```

### 2. 体检 + 部署（服务器执行）

```bash
cd /root/server-demo
bash preflight.sh        # 只体检：docker / 内存 / 磁盘 / 端口 / 离线包完整性
bash deploy.sh           # 校验 sha256 → 加载镜像 → 起 11 个容器 → 导数据
```

`deploy.sh` 大约 6-12 分钟（首次 MySQL 初始化最慢）。**可以反复执行**：镜像已加载会跳过，
数据已存在会跳过恢复。

### 3. 验收（服务器执行）

```bash
bash verify.sh           # 逐项打印 PASS/FAIL，FAIL 会给出排查命令
```

看到 `服务器侧验收全部通过` 就可以回本机了。

## 三、脚本说明

| 脚本 | 作用 | 常用参数 |
| --- | --- | --- |
| `preflight.sh` | 只读体检，不满足条件直接退出非 0 | `OFFLINE_DIR=...` |
| `deploy.sh` | 部署主脚本（幂等） | `--force-restore` 强制重导数据<br>`--skip-restore` 只起容器<br>`--skip-load` 跳过镜像加载<br>`--skip-verify` 跳过 sha256<br>`--yes` 免确认 |
| `verify.sh` | 逐项验收，输出 PASS/FAIL 表 | `TARGET_BASE=...` |

`deploy.sh` 具体做了 7 步：

1. `sha256sum -c SHA256SUMS.txt` 校验 18 个文件，不一致立刻停（并打出坏掉的文件名）
2. 逐个 `docker load` 14 个镜像（已存在的跳过），补 3 个短名 tag，
   再检查三套编排真正引用的 11 个镜像是否齐（缺一个就停）
3. 把 `vm.max_map_count` 调到 262144 并持久化（ES 8 的硬性要求，不调 ES 必崩）
4. 把编排铺到 `/opt/mall-swarm`、`/opt/mall-agent`、`/opt/mall-agent-vector`
   （含 `es-ik/`、`minio-runtime/`；**不铺 `init/`**）
5. 生成 `compose.deploy.yaml` 副本：**删掉 init 挂载**、**删掉 build 段**，并 `docker compose config -q` 校验语法
6. `docker compose up -d`（**绝无 --build**），轮询等 MySQL / PostgreSQL 变 healthy（带超时，不死等）
7. 导 MySQL / PostgreSQL / MongoDB 三份快照，最后打印容器状态表

## 四、本机侧唯一要改的东西

`deployment/.dev-ssh.json` —— 这个文件不在仓库里，需要你自己创建（可参照 `.dev-ssh.example.json`）：

```json
{ "host": "你的服务器IP", "port": 22, "username": "root", "password": "你的SSH密码" }
```

填 `host` / `username` / `password` 三项即可（`port` 一般还是 22）。改完不需要动别的东西：
`secrets.json`、`.run/agent-env.json`、`deployment/config/*.yaml` 全部保持不变——服务器的
中间件密码刻意沿用了旧环境的同一套值，所以本机不用改一行配置。

然后本机启动：

```powershell
.\deployment\start-local.ps1
```

四个入口：

| 地址 | 是什么 |
| --- | --- |
| http://127.0.0.1:5173 | H5 商城（uni-app） |
| http://127.0.0.1:5100 | 管理后台（mall-admin-web） |
| http://127.0.0.1:8201 | 网关 mall-gateway（Java 统一入口） |
| http://127.0.0.1:8099 | 智能体 API（`/readyz` 就绪探针） |

隧道端口是 `dev.cjs` 里写死的，不用改：

| 服务器端口（绑 127.0.0.1） | 组件 | 本机隧道端口 |
| --- | --- | --- |
| 3306 | MySQL | 13306 |
| 6379 | Redis | 16379 |
| 27017 | MongoDB | 27018 |
| 5672 | RabbitMQ AMQP | 15672 |
| 15672 | RabbitMQ 管理台 | 15673 |
| 8848 | Nacos HTTP | 18848 |
| 9848 | Nacos gRPC | 19848 |
| 9200 | Elasticsearch | 19200 |
| 9000 | MinIO API | 19000 |
| 9001 | MinIO 控制台 | 19001 |
| 15432 | PostgreSQL | 15432 |
| 19530 | Milvus | 19530 |
| 19091 | Milvus 健康端口 | 19091 |

## 五、六个必知的坑（都已在脚本里处理）

1. **init 挂载会撞"表已存在"** —— `compose.yaml` 里 `./init:/docker-entrypoint-initdb.d:ro` 会让
   MySQL 首次启动先建表，再导 dump 就冲突；`compose.deploy.yaml` 已删掉这一行，也不铺 `init/`。
2. **MySQL 密码会被 dump 覆盖** —— 快照是 `--all-databases` 导出，含 `mysql` 系统库的用户哈希；
   本次刻意沿用旧密码（与 `deployment/secrets.json` 一致），所以不需要 `ALTER USER`。
3. **PG 会报 `role already exists`** —— 预期错误，脚本已把它和真正的错误分开统计，只有非预期错误才判失败。
4. **ES 必须挂 `es-ik/`** —— 没有中文分词插件中文搜索全废；`preflight.sh` 会检查这个目录存在。
5. **别加 `--build`** —— 镜像全来自离线包，无外网构建必失败；脚本连 compose 里的 `build:` 段都删了。
6. **别把中间件端口开到公网** —— 全部只绑 `127.0.0.1`，安全组只放 22。

补充两条容易踩的：`vm.max_map_count` 低于 262144 时 ES 会反复重启（`deploy.sh` 会自动调）；
MinIO 对象数据快照只有 37 KB，服务器 MinIO 里几乎没有图片，商品图由本机
`http://127.0.0.1:18080/demo-assets/` 提供，属正常现象。

## 六、排障（每条都是一行命令）

```bash
# 容器起不来 —— 先看它自己的日志
docker compose -f /opt/mall-swarm/compose.deploy.yaml logs --tail 100 mysql

# 端口不通 —— 确认有没有在 127.0.0.1 上监听
ss -ltnp | grep -E ':(3306|9200|15432)'

# 全部容器状态一把看
for d in /opt/mall-swarm /opt/mall-agent /opt/mall-agent-vector; do
  docker compose -f $d/compose.deploy.yaml ps -a; done || true

# 隧道断了（本机 PowerShell 侧）—— 看隧道连接日志
Get-Content D:\newshop\deployment\.run\manager.log -Tail 30

# Java 连不上库 —— 从容器内部验一次账号密码（MySQL 为例）
docker exec -it $(docker compose -f /opt/mall-swarm/compose.deploy.yaml ps -q mysql) \
  sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -Nse "select count(*) from information_schema.tables where table_schema=\"mall\""'

# 重新导数据（会覆盖现有数据）
cd /root/server-demo && bash deploy.sh --force-restore
```
