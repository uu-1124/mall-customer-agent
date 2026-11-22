# Newshop 独立演示

买家端、后台和业务接口都从当前 Git 提交的源码构建。中间件和构建镜像固定到版本和镜像摘要，中文搜索插件校验 SHA-256。可以在本机编译，也可以拉取 GitHub Actions 验收后发布的私有镜像。两种方式都不需要访问原服务器。本项目使用独立 Docker 卷。默认从空的演示数据启动；要把已有部署的订单、账号、知识库和上传文件带过来，见[迁移到另一台服务器](#迁移到另一台服务器)。

## 运行前确认

| 项 | 要求 | 说明 |
| --- | --- | --- |
| Docker | Compose v2，**Linux 容器模式** | Windows 需启用 WSL2；macOS / Windows 用 Docker Desktop |
| 内存 | 建议 12–16 GB | 8 GB 是下限，Milvus 与 Elasticsearch 同时运行时可能 OOM |
| 磁盘 | ≥ 20 GB 可用 | 镜像与构建缓存约占 8–10 GB |
| 架构 | x86-64 | ARM 尚未验证 |
| 网络 | 能访问 Docker Hub 与依赖源 | 基础镜像来自 `docker.io`，构建阶段另需 `ghcr.io`（uv 镜像） |

首次构建要编译 6 个 Java 服务、构建两个前端并安装 Python 依赖，**通常 15–30 分钟**。期间终端可能长时间没有输出，看到 `[+] Building` 即在正常构建，不是卡死。

**Linux 宿主机先执行一次**（Elasticsearch 必需，否则容器会反复重启）：

```sh
sudo sysctl -w vm.max_map_count=262144
```

访问 Docker Hub 受限时，请先为 Docker 配置镜像加速，或通过 `DEMO_*_IMAGE` 指向可访问的镜像源。

## 克隆和启动

需要 Git、Docker Compose v2 与 Linux 容器模式。已有源码时直接进入目录，不需要访问原开发服务器。

从你有权限访问的 GitHub 仓库克隆本项目，再在仓库根目录执行 `cd deployment/demo`。以下命令都在该目录运行。

Linux/macOS：

```sh
if [ ! -f demo.env ]; then
  (umask 077; docker run --rm -i python:3.13.5-slim-bookworm python - < generate-env.py > demo.env)
fi
```

Windows PowerShell：

```powershell
if (-not (Test-Path demo.env)) {
  $demoConfig = Get-Content -Raw generate-env.py | docker run --rm -i python:3.13.5-slim-bookworm python -
  if ($LASTEXITCODE -ne 0) { throw '生成演示配置失败' }
  $demoConfig | Set-Content -Encoding ascii demo.env
}
```

两边用同一条启动命令：

```sh
docker compose --env-file demo.env up --build -d --wait --wait-timeout 480
```

如果仓库已配置镜像发布，可从同一提交的「Portable demo」成功运行摘要取得五个 `DEMO_*_IMAGE` 摘要引用，加到 `demo.env`。默认不发布镜像；仓库维护者可将 Actions 变量 `PUBLISH_DEMO_IMAGES` 设为 `true`，并在 `main` 上运行。拉取私有镜像需要相应包的读取权限。然后运行：

```sh
docker compose --env-file demo.env pull
docker compose --env-file demo.env up --no-build -d --wait --wait-timeout 480
```

请使用验收摘要所对应的 Git 提交，以便镜像与启动脚本保持一致。发布的镜像目前面向 `linux/amd64`。

| 入口 | 地址 | 演示账号 |
| --- | --- | --- |
| 买家端 | http://127.0.0.1:18180/ | `demo-buyer` |
| 管理后台 | http://127.0.0.1:18181/ | `demo-admin` |

两个合成账号使用公开的本机演示口令 `NewshopDemo!2026`。端口冲突时可以改 `demo.env` 内的 `DEMO_SHOP_PORT` 和 `DEMO_ADMIN_PORT`。只在本机打开演示；不要将这些账号用于联网环境，也不要提交生成的 `demo.env`。

买家端可从商品详情进入客服，也可演示购物车、模拟支付和订单；后台可查看商品、发货及处理售后。在客服会话中申请人工接待，后台进入「智能客服 → 客服工作台」，切换在线后领取。初始化包含商品、SKU、图片、收发货地址和售后规则，订单从空库开始。历史营销活动可能已过期。

## 常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `pull access denied`、`i/o timeout`、`TLS handshake timeout` | 访问 Docker Hub 受限 | 配置镜像加速后重试 |
| `elasticsearch` 反复重启，日志提示 `max virtual memory areas vm.max_map_count [65530] is too low` | 宿主机内核参数过低 | 执行上面的 `sysctl` 命令 |
| `no matching manifest for windows/amd64` | Docker 未切到 Linux 容器模式 | Windows 启用 WSL2 后重启 Docker Desktop |
| `--wait` 超时，`docker compose ps` 里有服务 `Exited` | 内存不足或端口被占用 | 释放内存；改 `demo.env` 里的 `DEMO_SHOP_PORT` / `DEMO_ADMIN_PORT` |
| 构建长时间停在同一层 | 首次下载 Maven / npm / Python 依赖 | 属正常现象；超过 40 分钟再排查代理设置 |

排查时先看服务状态和日志，再决定是否重启：

```sh
docker compose --env-file demo.env ps -a
docker compose --env-file demo.env logs --tail=100 agent gateway search
```

## 接入自己的模型

默认 `DEMO_AI_PROVIDER=fixture`：可以试商品咨询、流式测试回复和人工接待；测试回复不会发给外部模型，也不会替用户执行 Agent 交易。普通商城订单仍可操作。

要启用真实对话，请编辑本机的 `demo.env`；如需查看可选配置命令，运行 `python3 enable-ai.py --help`。不要把实际密钥写进项目文档、公开截图或版本控制。修改后重启演示服务。

```dotenv
DEMO_AI_PROVIDER=openai_responses
DEMO_AI_URL=https://api.openai.com/v1
DEMO_AI_MODEL=填入该端点支持的模型名
DEMO_AI_KEY=填入个人密钥
```

对话端点需支持 Responses 接口和项目所需的工具调用，使用 HTTPS。要启用视觉，另填 `DEMO_VISION_ENABLED=true` 和 `DEMO_VISION_MODEL`；语音能力使用 `DEMO_ALI_KEY`。知识索引还需要 Milvus：提供 `DEMO_ALI_KEY`、设置 `DEMO_KNOWLEDGE_ENABLED=true`，按以下顺序启动。知识文档由演示者在后台导入、构建和发布。

```sh
docker compose --env-file demo.env --profile knowledge up --build -d vector-init
docker compose --env-file demo.env --profile knowledge wait vector-init
docker compose --env-file demo.env --profile knowledge up --build -d --wait --wait-timeout 480
```

建议在首次启动真实模式前设置好模型。真实模式已初始化后，模型版本由数据库管理；修改环境变量里的模型名不会替换后台已激活的模型版本。项目保留模拟支付、退款和物流；生产备份服务及外部监控不在本演示范围内。

## 迁移到另一台服务器

新机器从空库启动只有演示种子数据。要带走会话、订单、知识文档和上传文件，用备份脚本做一次完整导出：

```sh
python backup.py
```

它先停栈保证 MySQL、PostgreSQL、MinIO、MongoDB、Milvus 处于一致状态，写入 `backups/<时间戳>/`（含 dumps、卷归档、`manifest.json` 校验和），然后自动把栈重新拉起来。加 `--keep-running` 可以不停机，但存在写入不一致的风险。

把整个备份目录和**生成它的那份 `demo.env`** 一起复制到新机器：

```sh
python restore.py backups/20261118T120000Z
```

恢复会先停栈、只启数据库、导入 dumps、替换对象与向量卷，再拉起全套并跑 `smoke.py`。`manifest.json` 记录了密钥指纹；如果新机器用的是重新生成的 `demo.env`，脚本会提示旧的加密操作行和附件将无法读取——需要这些数据时务必复用原 `demo.env`。

## 验收和停止

默认测试模式下，可以用 Python 3 运行 `python smoke.py`（Linux/macOS 也可用 `python3 smoke.py`）。它会检查双端登录、演示商品和中文搜索、后台上传、流式客服回复、人工接待队列。端口改过时，按顺序把买家端和后台的完整 URL 作为两个参数传给脚本。脚本会在演示库创建一条会话和待接待工单。

```sh
docker compose --env-file demo.env ps -a
docker compose --env-file demo.env logs --tail=100 search-init pg-init object-init
docker compose --env-file demo.env --profile knowledge down
```

停止时会保留演示数据。只有明确要重置这套演示库时，才对最后一条命令加 `--volumes`。若 Elasticsearch 日志要求调整 `vm.max_map_count`，在 Linux 宿主机或 Docker 所在的 Linux 虚拟机按日志提示设置后重试。
