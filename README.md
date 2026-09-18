# amazon-connect-acxd

把 Amazon Connect **Agentic CX Designer (ACXD)** 的应用配置导出成本地 JSON，再导入到另一个 workspace 的小工具。

两个交互式 shell 脚本，只依赖 `curl` 和 `jq`，不需要 Node.js、Python 或 AWS SDK。它们直接调用 ACXD 的 REST API：

| 脚本 | 作用 |
| --- | --- |
| `export-acxd.sh` | 把 application、它引用的 flow、build、deployment（可选还有 workspace 级共享资源）拉到本地目录 |
| `import-acxd.sh` | 把导出目录里的 application 和 flow 写回指定 workspace，可选顺手 build 和 deploy |

典型用途是版本管理、跨环境比对备份，以及把一个应用从测试 workspace 搬到生产 workspace。

## 导出：快速开始

```bash
./export-acxd.sh
```

脚本会依次询问两件事：

1. **ACXD API Key** —— 隐藏输入，不回显。在 Admin Hub > Programmatic Users 里生成，格式类似 `acxd_live_<前缀>.<密钥>`。
2. **控制台 URL 或 workspace ID** —— 直接粘贴浏览器地址栏里的 ACXD 链接即可，脚本会从中解析 `workspaceId` 和 `applicationId`：

   ```
   https://<实例别名>.my.connect.aws/acxd/w/<workspaceId>/applications/<applicationId>/build
   ```

之后脚本会自动探测 workspace 所在区域、列出可导出的 application 让你选择，并询问是否导出共享资源和输出目录。

### 前置条件

- `curl` 和 `jq`（macOS: `brew install jq`）
- 一个有目标 workspace 访问权限的 ACXD API Key
- 需要在**交互式终端**里运行。API Key 只从终端读取，不支持环境变量或 `.env` 文件，也不会写入磁盘

## 导出：命令行参数

提供了参数就跳过对应的提问，适合脚本化调用（API Key 仍然需要交互输入）：

| 参数 | 说明 |
| --- | --- |
| `--url <url>` | 控制台 URL，自动解析 workspaceId 和 applicationId |
| `--workspace <uuid>` | workspace ID |
| `--application <uuid>` | application ID |
| `--all` | 导出该 workspace 下所有 application |
| `--list` | 只列出 workspace 里的 application 然后退出 |
| `--out <dir>` | 输出目录（默认 `./export-<应用名>`） |
| `--region <region>` | 端点区域，默认 `auto` 自动探测 |
| `--endpoint <url>` | 直接指定完整端点，跳过区域探测 |
| `--builds <n>` | 抓取最近 n 个 build 的详情（默认 5，`0` 表示不抓） |
| `--with-shared` | 同时导出共享资源（知识库、data request、slot type、guardrail 等） |
| `--no-shared` | 不导出共享资源 |
| `-h`, `--help` | 显示帮助 |

示例：

```bash
# 先看看这个 workspace 里有哪些 application
./export-acxd.sh --workspace <workspaceId> --list

# 从控制台 URL 导出单个应用
./export-acxd.sh --url "https://xxx.my.connect.aws/acxd/w/<workspaceId>/applications/<appId>/build"

# 导出整个 workspace，包含共享资源，不抓 build 详情
./export-acxd.sh --workspace <workspaceId> --all --with-shared --builds 0 --out ./export
```

## 导出：输出结构

```
export-<应用名>/
├── manifest.json                       # 本次导出的清单：时间、区域、端点、统计、失败请求
├── workspace.json                      # 仅 --with-shared
├── applications/
│   ├── _index.json                     # workspace 下 application 列表
│   └── <应用名>-<applicationId>/
│       ├── application.json            # 应用定义（flows / settings / deploymentSettings 等）
│       ├── flows/<flowId>.json         # 应用引用到的 flow 完整定义
│       ├── builds.json                 # build 列表
│       ├── builds/<buildId>.json       # 最近 N 个 build 的详情
│       ├── deployments.json            # deployment 列表
│       └── deployments/<deploymentId>.json
└── workspace/                          # 仅 --with-shared
    ├── flows/                          # 所有 flow，含未挂到任何 application 上的
    ├── context-variables.json
    ├── analytics-tags.json
    ├── secrets.json                    # secret 列表（列表接口一般只返回元数据）
    ├── data-requests/  slot-types/  guardrails/  modalities/  live-sync-scripts/
    └── knowledge-bases/<kbId>/
        ├── knowledge-base.json
        ├── articles/
        ├── documents.json
        └── publications.json
```

仓库里的 `export-acme0911/` 是一次导出的样例（应用名等已替换为虚构名称 `acme0911`），可以对照着看实际的文件形态。

关于 flow 的收集方式：脚本先从 `application.json` 里取种子 flow（`flows[]`、`settings.defaultFlows`、`settings.lifecycleHooks`），然后顺着 flow 定义里出现的其它 flowId 递归展开（redirect、handoff 之类的跳转），直到没有新的 flow 为止。所以即使应用只声明了一个入口 flow，被它间接调用的 flow 也会一起导出。

## manifest.json

每次导出都会生成清单，字段含义：

| 字段 | 说明 |
| --- | --- |
| `exportedAt` | 导出时间（UTC） |
| `sourceUrl` | 如果是通过 URL 导出，记录原始链接 |
| `workspaceId` / `region` / `endpoint` | 数据来源 |
| `applications[]` | 每个应用的 ID、名称、目录，以及 flow / build / deployment 数量 |
| `sharedResourceCounts` | 各类共享资源的数量（未开启 `--with-shared` 时为空对象） |
| `errors[]` | 失败的请求，含资源路径、HTTP 状态码和消息 |

单个请求失败不会中断整体导出，脚本会继续处理剩余资源，最后把失败项汇总到 `errors` 里。结束时如果有失败，控制台也会提示。

## 导入：快速开始

```bash
./import-acxd.sh
```

脚本会依次询问：源目录、目标 workspace 的 API Key、目标 workspace URL（或 ID）、要导入哪个 application、遇到重名怎么办、是否 build、是否 deploy。全程中文提示，API Key 隐藏输入。

想先看看会提交什么而不真的写入，用 `--dry-run`。这个模式不发任何请求，也不需要 API Key，只把请求体写到 `./import-dryrun-<时间戳>/` 供检查：

```bash
./import-acxd.sh --dir ./export-acme0911 --all --dry-run
```

导入顺序是固定的，因为 application 通过 `flowId` 引用 flow，flow 必须先存在：

```
flow  ->  application  ->  build（可选）  ->  deployment（可选）
```

### 导入：命令行参数

| 参数 | 说明 |
| --- | --- |
| `--dir <dir>` | 导入源目录（`export-acxd.sh` 的输出目录） |
| `--url <url>` / `--workspace <uuid>` | 目标 workspace |
| `--application <name>` | 只导入源目录里这个名字的 application |
| `--all` | 导入源目录里所有 application |
| `--name <新名称>` | 导入后使用的应用名称（只在导入单个应用时有效） |
| `--on-conflict <策略>` | 重名处理：`skip` / `update` / `rename` |
| `--build` / `--no-build` | 导入后是否创建 build |
| `--deploy` / `--no-deploy` | build 成功后是否创建 deployment（默认不做） |
| `--environment <env>` | deployment 环境：`development` / `qa` / `staging` / `production` |
| `--create-context-vars` | 自动创建 flow 用到但目标缺失的 context variable |
| `--region` / `--endpoint` | 同导出脚本 |
| `--dry-run` | 只打印请求体，不发任何写请求 |
| `--simulate-conflict` | 仅 dry-run：假设目标里已存在源里所有同名资源，用来演练重名策略 |

示例：

```bash
# 把样例目录导入目标 workspace，重名就换个名字导入，导入后 build 但不部署
./import-acxd.sh --dir ./export-acme0911 --all --on-conflict rename --build --no-deploy \
  --url "https://xxx.my.connect.aws/acxd/w/<workspaceId>/applications"

# 演练一遍重名策略，不发请求
./import-acxd.sh --dir ./export-acme0911 --all --dry-run --simulate-conflict --on-conflict rename
```

### 重名策略

flow 在 workspace 里是按 `flowId`（也就是名字）唯一的，application 按名字区分，所以跨 workspace 导入时很容易撞名。三种处理方式：

- `skip` 目标已有同名资源就跳过，目标现有配置一点不动
- `update` 用源文件覆盖目标里的同名资源，**会改动目标现有配置**
- `rename` 给导入的资源加 `Imported` 后缀（`flowId` 只允许字母数字，所以后缀不含符号），目标原有资源保持不变。重命名会同步改写所有引用：其它 flow 里的跳转、application 的 `flows[]` 和 `settings.defaultFlows`

### 导入能带过去什么，不能带什么

能：application 本体（`name` / `description` / `settings` / `metadata` / `deploymentSettings`）、它引用的 flow 完整节点图、可选的新 build 和新 deployment、缺失的 workspace context variable。

不能：

- **历史 build 和 deployment**。它们是不可变记录，接口只支持新建。导入后是一个全新的 build，版本号和 ID 都跟源不同
- **共享资源**。flow 如果引用了知识库、guardrail、data request、slot type、modality、live sync script，这些是按 ID 引用的，目标 workspace 里没有同 ID 的资源，导入后引用会悬空。这类应用需要先手工在目标 workspace 建好这些资源，再改 flow 里的 ID
- **原有的 ID**。`applicationId` 由目标 workspace 新分配，源目录里的 ID 只用于定位文件

脚本会在导入前扫描 flow 里 `stateModifications` 用到的 workspace context variable，把目标 workspace 里缺失的列出来（缺失会导致 build 校验失败），并可以选择自动创建。仓库里的样例应用用到一个 `modelNumber`。

### 导入报告

每次运行都会在当前目录生成 `import-report-<时间戳>.json`：

| 字段 | 说明 |
| --- | --- |
| `dryRun` | 是否是演练 |
| `sourceDir` / `workspaceId` / `region` / `endpoint` | 这次导入的来源和目标 |
| `onConflict` | 实际生效的重名策略 |
| `results[]` | 每个资源的类型、名称、动作（`create` / `update` / `skip` / `failed` / `partial`）和详情 |
| `renamedFlows[]` | flowId 的重命名映射 |
| `errors[]` | 失败的请求，含路径、HTTP 状态码和消息 |

## 工作原理

ACXD SDK 本质上就是一套 REST API：

- 端点：`https://api.acxd.connect.<region>.amazonaws.com`
- 认证：`x-api-key` 请求头
- 范围：`x-workspace-id` 请求头
- 路径：`/sdk/...`，分页通过 `maxResults` + `nextToken`

`--region auto` 的探测方式是依次向候选区域请求 `/sdk/workspaces`，第一个返回 200 的就是目标区域。候选列表：`us-west-2`、`us-east-1`、`us-east-2`、`eu-west-2`、`eu-central-1`、`ap-southeast-1`、`ap-southeast-2`、`ap-northeast-1`。如果你的 workspace 在其它区域，用 `--region` 或 `--endpoint` 显式指定。

两个脚本用到的操作：

| 操作 | 请求 | 用在 |
| --- | --- | --- |
| ListFlows / GetFlow | `GET /sdk/flows`、`GET /sdk/flows/<flowId>` | 导出、导入前查重 |
| CreateFlow / UpdateFlow | `POST /sdk/flows`、`PUT /sdk/flows/<flowId>` | 导入 |
| ListApplications / GetApplication | `GET /sdk/applications[/<id>]` | 导出、导入前查重 |
| CreateApplication / UpdateApplication | `POST /sdk/applications`、`PUT /sdk/applications/<id>` | 导入 |
| CreateApplicationBuild / GetApplicationBuild | `POST` / `GET /sdk/applications/<id>/builds[/<buildId>]` | 导入（`--build`） |
| CreateApplicationDeployment | `POST /sdk/applications/<id>/deployments` | 导入（`--deploy`） |
| CreateContextVariable | `POST /sdk/context-variables` | 导入（补缺失变量） |

导入时提交的请求体会先剔除只读字段（flow 的 `saveId` / `createdAt` / `updatedAt` / `updatedBy`，application 的 `applicationId` 等），只保留 Create/Update 接受的字段。

参考文档：[Agentic CX Designer SDK](https://docs.aws.amazon.com/connect/latest/devguide/acxd-sdk.html)、[API Reference](https://docs.aws.amazon.com/connect/latest/devguide/acxd-api-reference.html)、[Applications](https://docs.aws.amazon.com/connect/latest/devguide/acxd-applications.html)、[Flows](https://docs.aws.amazon.com/connect/latest/devguide/acxd-flows.html)、[Application Builds](https://docs.aws.amazon.com/connect/latest/devguide/acxd-application-builds.html)、[Application Deployments](https://docs.aws.amazon.com/connect/latest/devguide/acxd-application-deployments.html)

## 常见问题

**所有区域都探测失败** —— 通常是 API Key 复制错了（注意末尾空格）、Key 已被撤销，或者该 programmatic user 没有这个 workspace 的权限。

**提示需要在终端里运行** —— 脚本检测到 stdin 不是 tty 就会退出，因为 API Key 必须交互输入。别用管道或重定向的方式喂输入。

**知识库 documents 接口报 400** —— 该接口校验的是 `size` 参数而不是 `maxResults`，脚本已经针对它跳过分页参数，无需处理。

**导入时 build 状态是 FAILED** —— build 会跑校验，常见原因是 flow 引用的资源在目标 workspace 不存在：context variable、知识库、guardrail、data request、slot type。脚本会打印返回体里的校验信息，按提示先在目标 workspace 补齐资源，再重新 build。

**导入返回 403** —— 导入用的 API Key 需要写权限。只读的 programmatic user 能通过认证、能列出资源，但 `POST` / `PUT` 会被拒。

## 安全提示

- API Key 不落盘、不进环境变量、不回显，仅存在于脚本运行期间的内存里
- `secrets.json` 来自列表接口，一般只有元数据；导出后建议自己确认一遍里面没有敏感值
- 导出内容仍然包含 workspace ID、application ID、flow 逻辑和 prompt 文本等业务信息，提交到公开仓库前请自行评估
- 导入脚本默认**不**创建 deployment。deployment 会让新 build 对终端用户生效并使上一个 deployment 失效，需要显式确认或加 `--deploy`
- `update` 重名策略会覆盖目标 workspace 里的现有 flow / application 配置，跑之前建议先对目标做一次导出留底
