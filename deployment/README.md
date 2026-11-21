# deployment 目录说明

本目录存放**部署、运维、验收**相关的脚本与配置，不包含应用代码。
应用代码分别在 `mall-swarm/`（Java）、`mall-agent/`（Python 智能体）、`mall-admin-web/`、`mall-app-web/`（前端）。

## 一、两种运行形态

同一套代码有两种跑法，区别只在中间件在哪里：

| 形态 | 应用 | 中间件 | 用途 | 入口 |
| --- | --- | --- | --- | --- |
| 本机开发 | 本机进程（Java 17 + Python 3.13 + Vite） | 远端服务器 Docker，经 SSH 隧道转发到本机回环端口 | 日常开发调试 | `start-local.ps1` |
| 独立演示 | Docker 容器 | Docker 容器（同机 22 个服务） | 换机器后一条命令起全套 | `demo/compose.yaml` |

两者**不冲突**，但不要同时占用同一组端口运行。

## 二、中间件在哪里

中间件本体不在仓库里，仓库只保存"怎么把它们跑起来"的定义。

- **远端开发环境**：`compose.yaml`（本机生成，已被 Git 忽略）+ `config/*.yaml`（各服务的生成配置）
- **独立演示环境**：`demo/compose.yaml`（22 个服务）+ `demo/*.Dockerfile`（5 个自建镜像）+ `demo/*-init.py`（初始化脚本）

### 服务清单

| 类别 | 组件 | 镜像来源 | 定义位置 |
| --- | --- | --- | --- |
| 数据 | MySQL 8.0.35（商城库） | 自建，预装种子数据 | `demo/mysql.Dockerfile` + `demo/seed.sql` |
| 数据 | PostgreSQL 16（智能体库） | 官方 `postgres:16.11-alpine` | `demo/compose.yaml` |
| 数据 | Redis 7.4.5 | 官方 `redis:7.4.5-alpine` | 同上 |
| 数据 | MongoDB 7.0.20 | 官方 `mongo:7.0.20` | 同上 |
| 消息 | RabbitMQ 3.13.7 | 官方 `rabbitmq:3.13.7-management-alpine` | 同上 |
| 注册配置 | Nacos 2.5.1 | 官方 `nacos/nacos-server:v2.5.1` | 同上 |
| 检索 | Elasticsearch 8.18 + IK 分词 | 自建，预装中文分词插件 | `demo/search.Dockerfile` |
| 对象存储 | MinIO | 官方 `milvusdb/minio` | `demo/compose.yaml` |
| 向量库 | Milvus 3.0.5 + etcd | 官方 `milvusdb/milvus:v3.0.5` | `demo/compose.yaml` + `demo/milvus.yaml` |
| 应用 | 6 个 Java 服务 | 自建 | `demo/java.Dockerfile` |
| 应用 | Python 智能体 + 4 个 worker | 自建 | `demo/agent.Dockerfile` |
| 网关 | 前端 + Nginx | 自建 | `demo/web.Dockerfile` + `demo/web.conf` |

有 5 个项目镜像（mysql / search / java / agent / web），其余由编排引用固定的中间件镜像。CI 从源码构建并验证；GitHub Packages 发布由仓库维护者显式开启，见[独立演示指南](demo/README.md)。

### 本机开发时的端口映射

远端中间件只监听服务器回环地址，通过 SSH 隧道转发到本机，不暴露公网。

| 本机 | 远端 | 用途 |
| --- | --- | --- |
| 13306 | 3306 | MySQL（库 `mall`） |
| 16379 | 6379 | Redis |
| 27018 | 27017 | MongoDB |
| 15672 / 15673 | 5672 / 15672 | RabbitMQ AMQP / 管理台 |
| 18848 / 19848 | 8848 / 9848 | Nacos HTTP / gRPC |
| 19200 | 9200 | Elasticsearch |
| 19000 / 19001 | 9000 / 9001 | MinIO API / 控制台 |
| 15432 | 15432 | 智能体 PostgreSQL（库 `mall_agent`） |
| 19530 / 19091 | 19530 / 19091 | Milvus RPC / 健康检查 |

## 三、目录索引

| 路径 | 作用 |
| --- | --- |
| `start-local.ps1` / `stop-local.ps1` | 本机开发环境启停（SSH 隧道 + 6 个 Java 服务 + 2 个前端 + 智能体进程组） |
| `start-agent-demo.ps1` | 智能体定向切包启动（需先停止管理器） |
| `restart-agent-process.ps1` | 重启单个智能体进程（`-Name agent-api` 等） |
| `rebuild-backend.ps1` | 后端增量编译并切换运行包，编译失败不停止现有进程 |
| `prepare*.cjs` | 环境准备：配置生成、数据库结构、Milvus、对象存储初始化 |
| `migrate-agent.cjs` | 智能体库 Alembic 迁移执行入口 |
| `acceptance.cjs` | 部署验收脚本（登录、商品、订单、上传等实际请求） |
| `check-secrets.py` | 扫描被跟踪文件中的凭据与真实主机名，CI 中强制运行 |
| `source-lock.json` | 上游三个仓库固定的 commit，用于界定"上游 vs 增量" |
| `*-manifest.json` | 各阶段的交付指纹与回滚依据（构建、定价、购物车、订单等） |
| `demo/` | 独立演示栈，自包含，见 `demo/README.md` |
| `init/` | 初始化表结构、商品及配置；本机账号 SQL 由 `prepare.cjs` 生成并忽略 |
| `config/` | 生成的服务配置（Git 忽略） |
| `.run/` | 运行产物：暂存 jar、日志、备份快照、诊断证据（Git 忽略） |

## 四、密钥与本机配置

以下文件**只存在于本机，不进入版本库**，删除后需重新生成：

| 文件 | 内容 |
| --- | --- |
| `secrets.json` | 各中间件与服务的口令 |
| `.dev-ssh.json` | 远端服务器地址与 SSH 凭据（模板见 `.dev-ssh.example.json`） |
| `compose.yaml` | 远端中间件编排（由准备脚本生成，含口令） |
| `config/*.yaml` | 6 个 Java 服务的生成配置 |

请勿提交部署凭据、实际业务数据、运行日志或离线备份。独立演示里的公开口令只用于新建的回环演示账号。

## 五、`.run/` 运行产物

该目录是运行时的工作区，不提交版本库，包含三类内容：

1. **活跃依赖**：`agent-jars/`（智能体切包用）、`agent-tools/`（内置 uv）、`pids.json`
2. **当前日志**：`portal.log`、`admin.log`、`gateway.log`、`agent-*.log` 等
3. **历史快照**：`*-2026MMDD*` 形式的备份、回滚与诊断目录

历史快照可安全归档或删除；**前两类不要清理**，删除会导致启动脚本或切包流程失效。

## 六、换机器后怎么跑

1. 安装 Docker（Linux 容器模式）与 Git
2. 见 `demo/README.md`：`generate-env.py` 生成配置 → `docker compose up --build -d`
3. 按需配置真实模型；在本机 `demo.env` 填入所用供应商的端点和凭据。

若要接手**本机开发形态**，还需要：JDK 17、Maven、Node 22、Python 3.13（uv）、
以及原服务器的 SSH 凭据（写入 `.dev-ssh.json`）。缺其中任一项，改走演示形态更省事。
