# QwenPaw 2.0 Worker 完整升级与验收计划

## 1. 目标

将 AgentTeams 托管的 QwenPaw Worker 从 QwenPaw 1.1.11 升级到固定稳定版本
QwenPaw 2.0.1，并彻底移除源码覆盖、运行时源码 patch，以及对 QwenPaw 自有配置
文件的直接写入。

最终架构必须满足：

- `runtime.yaml` 是 controller 向 worker 下发 desired state 的唯一协议；
- AgentTeams 扩展全部使用 QwenPaw 公共插件 API；
- AgentTeams Matrix 能力以自定义 Channel 插件实现；
- Worker 通过 QwenPaw HTTP API 修改运行时；
- 每次修改后必须 GET 回读并进行语义校验；
- 只允许在启动窗口进行有界重试；
- 必须在真实 QwenPaw、真实镜像、真实 Matrix 和真实模型调用上完成最终验收。

任何阶段性通过都不代表项目完成。只有第 10 节全部门禁通过，且第 9 节列出的
旧路径全部清零，才允许宣布升级完成。

## 2. 边界与非目标

- 不为了适配 QwenPaw 内部结构而随意修改 controller 所有的 `runtime.yaml` 协议。
- Worker 不得读取 CRD、Helm、controller 内部状态或 UI 状态推断 desired state。
- 不覆盖 QwenPaw 内置 `matrix` Channel。
- 不向已安装的 `qwenpaw` Python package 复制 AgentTeams 源文件。
- 镜像构建和容器启动时都不 patch QwenPaw 源码。
- HTTP 返回 2xx 但没有 GET 回读，不算配置成功。
- 不保留对 `agent.json`、`config.json`、`access_control.json`、Driver Card、
  credential 文件等 QwenPaw 自有文件的永久直接写入 fallback。
- 任一 Channel、ACL、MCP、插件、包更新、重启、升级、回滚场景未验收，不得完成。

## 3. 目标架构

```text
Controller
  生成并发布 runtime.yaml
            |
            v
qwenpaw-worker desired-state reconciler
  解析并校验 desired state
  按资源计算差异
  将 AgentTeams 字段翻译为 QwenPaw 2.0 API 模型
            |
            v
QwenPawApiClient（localhost HTTP）
  健康、版本、能力探测
  PUT / POST / DELETE
  GET 回读与语义校验
            |
            v
QwenPaw 2.0.1
  负责持久化、reload、Channel、ACL、MCP/Driver 和 Agent runtime

镜像内安装的 AgentTeams 插件
  agentteams-matrix-channel（phase 1 Channel 插件）
  teamharness（仅公共插件 API）
  workerflow（仅公共插件 API）
```

### 3.1 Channel 标识

Controller 协议继续使用 `matrix`。Worker 将它映射为 QwenPaw 自定义 Channel key：

```text
runtime.yaml: matrix
        -> worker adapter
        -> QwenPaw: agentteams_matrix
```

自定义 Channel 必须：

- 实现 QwenPaw `BaseChannel` 公共契约；
- 通过 `PluginApi.register_channel()` 注册；
- 不继承、不替换 QwenPaw 内置 `MatrixChannel`；
- 自己负责 AgentTeams Matrix 登录、sync、invite、mention、thread、附件、
  streaming、TaskRoom 和 reply routing；
- 在 workspace 启动前作为 phase 1 Channel 插件加载；
- 配置、健康检查和 ACL API 统一使用 `agentteams_matrix`。

### 3.2 插件边界

| AgentTeams 能力 | QwenPaw 2.0 扩展点 |
| --- | --- |
| AgentTeams Matrix 传输 | 自定义 Channel 注册 |
| Team/Task 上下文 | prompt section 或 middleware |
| TaskRoom 控制命令 | control command 注册 |
| TeamHarness/WorkerFlow 工具 | tool 注册 |
| 请求与响应处理 | middleware 或 lifecycle hook |
| 插件自有诊断接口 | plugin HTTP router |
| 初始化与清理 | startup/shutdown/uninstall hook |

禁止直接 import QwenPaw 的 runner、workspace service factory、内部注册表和配置持久化
实现。如果公共插件 API 缺少必要能力，应先记录明确缺口并向 QwenPaw 上游补充通用扩展
点；在固定版本仍无法使用公共扩展点之前，该项阻塞最终验收。

### 3.3 API reconcile 边界

Worker 负责 desired-state 比较和协议翻译；QwenPaw 负责校验、持久化和运行时 reload。

新增集中式 `QwenPawApiClient`，统一负责：

- connect timeout 和 request timeout；
- 仅启动窗口使用的有界退避重试；
- 类型化请求、响应和错误解析；
- 日志脱敏；
- retryable 与 permanent failure 分类；
- mutation 后 GET 回读；
- 允许服务端默认值的语义比较；
- 在不泄露 Secret 的前提下报告资源和不一致字段。

## 4. 必须实现的运行时映射

### 4.1 Channel

必须使用单 Channel API，不得使用全量覆盖接口：

```text
PUT /api/config/channels/{channel_name}
GET /api/config/channels/{channel_name}
GET /api/config/channels/{channel_name}/health
```

更新语义：

- `runtime.yaml` 本次没有出现的 Channel 保持现状；
- 本次提供的 Channel，其非 Secret `Config` 是目标状态；
- Secret 只有非空时才覆盖，空值表示保留已有值；
- 更新一个 Channel 不得改变其他 Channel。

可见性字段在 Worker 边界转换：

```text
show_thinking = !filter_thinking
show_tool_calls = !filter_tool_messages
```

`show_tool_results` 必须定义明确默认值并写测试，不能偶然继承 QwenPaw 默认值。

### 4.2 ACL

按 Channel 使用 QwenPaw ACL API：

```text
GET  /api/access-control/{channel}
POST /api/access-control/whitelist/add
POST /api/access-control/whitelist/remove
POST /api/access-control/blacklist/add
POST /api/access-control/blacklist/remove
POST /api/access-control/remark
```

Reconciler 必须计算新增、删除、名单迁移和 remark 更新。清空已有 remark 必须显式调用
remark API。一个 Channel 的 ACL 更新不能覆盖任何其他 Channel 的状态。

### 4.3 MCP

使用 QwenPaw 2.0 基于 Driver runtime 的 MCP API：

```text
GET    /api/mcp
POST   /api/mcp
GET    /api/mcp/{client_key}
PUT    /api/mcp/{client_key}
DELETE /api/mcp/{client_key}
```

必须覆盖创建、更新、启停、删除、凭据轮换、工具策略和重启持久化。Worker 不得构造
QwenPaw 内部 MCP Config，也不得写 Driver Card 和 credential 文件。

### 4.4 模型和 Agent 配置

使用 QwenPaw model/provider/agent API。通过 GET 回读确认 provider、model 和 active
agent。最终验收必须包含一次真实模型请求，禁止直接编辑 root 或 workspace 配置文件。

### 4.5 AgentSpec package 和 Skills

AgentSpec 下载、digest 校验以及 AgentTeams 自有 workspace 资产同步仍由 Worker 负责。
涉及 QwenPaw 管理的 Skill、Plugin、MCP 或 Agent 注册时，必须调用对应 API 或插件生命周期。

AgentSpec 热更新不能重启 Pod；删除旧 package 资产时不能删除用户自有资产。

## 5. 实施阶段

每个阶段有局部退出条件，但任何单独阶段都不满足最终 Definition of Done。

### 阶段 0：基线和契约清单

- 固定旧基线 QwenPaw 1.1.11 和目标版本 2.0.1。
- 清点所有 QwenPaw 直接 import、patch、覆盖文件和自有配置文件写入。
- 清点 Worker 当前消费的所有 `runtime.yaml` 字段。
- 用测试记录 Matrix、Channel、ACL、MCP、模型、插件、AgentSpec、存储、心跳和可观测性行为。
- 构建并运行 1.1.11 当前镜像测试，记录可复现基线及已有失败。

退出条件：每个旧集成点都有明确替代方案或删除项，并进入测试或变更清单。

### 阶段 1：QwenPaw 2.0 镜像与 API Client

- Worker metadata 和 Docker build 默认值均固定为 QwenPaw 2.0.1。
- 验证 Python、AgentScope、LoongSuite、matrix-nio 等依赖兼容性。
- 新增集中式 `QwenPawApiClient`，禁止 HTTP 调用散落在 update 逻辑中。
- 实现健康、版本和能力探测。
- 启动顺序改为：安装插件、启动 QwenPaw、等待健康、首次完整 reconcile、进入增量轮询。
- 首次 reconcile 失败必须阻止 readiness。

退出条件：干净镜像能够启动 QwenPaw 2.0.1 并提供 API；此时仍不能发布。

### 阶段 2：AgentTeams 自定义 Matrix Channel

- 创建 `agentteams-matrix-channel` 插件和 manifest。
- 基于 QwenPaw 2.0 `BaseChannel` 移植 AgentTeams 行为。
- 以 `agentteams_matrix` 注册 phase 1 Channel。
- 实现配置 schema、健康检查和 restart。
- 将 `runtime.yaml.desired.channels.matrix` 映射到自定义 Channel API。
- ACL 使用 `agentteams_matrix` API reconcile。
- 删除 Dockerfile Matrix 源码覆盖。

退出条件：内置 Matrix 文件完全未改动，自定义 Channel 的全部单测和集成测试通过。

### 阶段 3：TeamHarness 和 WorkerFlow 新插件迁移

- prompt/context 改用公共 prompt 或 middleware API。
- 工具和命令改用公共插件注册 API。
- 启动、关闭、reload、uninstall 改用插件 hooks。
- 删除对内部 runner、workspace service、registry 和 config persistence 的 import。
- 验证安装、启用、禁用、reload、卸载和重装。
- 验证故障隔离，单个可选插件失败不得破坏 QwenPaw 或 Matrix 插件。

退出条件：两个插件的公共 API 扫描和完整生命周期测试通过。

### 阶段 4：完整 API desired-state reconcile

- 模型/provider 更新迁移到 API 和回读。
- Matrix、DingTalk、Feishu、WeCom 更新迁移到单 Channel API。
- 所有 Channel ACL 迁移到 API。
- MCP 迁移到 QwenPaw 2.0 MCP/Driver API。
- 保持 Channel 增量和非空 Secret 更新语义。
- 相同 desired state 必须幂等，不产生 mutation。
- 失败 generation 不得记录为 applied，并必须可重试。
- 某项更新被拒绝时保留 last-known-good runtime state。
- 删除永久直接文件写入 fallback。

退出条件：所有支持的 `runtime.yaml` 更新均由 API 执行、GET 回读并有测试覆盖。

### 阶段 5：AgentSpec、存储、生命周期与可观测性

- 验证 AgentSpec 安装、更新、回滚和资产所有权。
- 验证 MinIO/OSS 恢复以及后台 push 的包含/排除规则。
- 验证 heartbeat、readiness 和 last-active 上报。
- 验证优雅退出以及 QwenPaw 子进程退出传播。
- 验证 LoongSuite 启动和 trace，无运行时 import error。
- 保证 QwenPaw stdout/stderr 出现在容器日志中，且没有重复 PIPE 转发。
- 确保日志不包含 Channel Secret、MCP credential、模型 key、存储凭据和授权值。

退出条件：非 Channel Worker 生命周期相对 1.1.11 基线无回归。

### 阶段 6：升级、恢复和发布资格

- 空存储全新安装。
- 使用真实 1.1.11 持久化目录进行原地升级。
- 成功 reconcile 后重启。
- QwenPaw 启动时不可用和运行中短暂不可用。
- 非法 desired state 后发布修正 generation。
- 多资源 reconcile 中途进程崩溃。
- 回滚旧 Worker 镜像或通过 snapshot 恢复。
- 在精确 release-candidate digest 上运行全部最终验收。

退出条件：第 10 节所有门禁在同一个候选镜像 digest 上通过。

## 6. 测试策略

### 6.1 单元与契约测试

- 每个 `runtime.yaml` 字段的解析和校验；
- AgentTeams 到 QwenPaw 字段转换；
- Secret 保留和日志脱敏；
- 资源 diff 和幂等；
- API 请求、响应和错误分类；
- GET 回读语义比较；
- 插件 manifest、注册、加载顺序和卸载清理；
- Matrix event 解析、渲染、thread 和 routing；
- ACL 增删、迁移和清空 remark；
- MCP CRUD 和凭据轮换映射。

### 6.2 真实 QwenPaw API 集成测试

测试必须连接真实 QwenPaw 2.0.1，不能只用 mock HTTP handler：

- 健康和版本探测；
- 插件列表及自定义 Channel schema；
- 单 Channel PUT 后 GET；
- Channel 健康和 restart；
- ACL mutation 后按 Channel GET；
- MCP CRUD 后 GET/list；
- model/provider 更新后 GET；
- agent reload 完成及进程重启后的持久化。

### 6.3 镜像集成测试

- 镜像中不存在 QwenPaw patch 或源码覆盖；
- AgentTeams 插件已安装并成功加载；
- readiness 前完成首次完整 reconcile；
- `runtime.yaml` 增量 reconcile；
- MinIO/OSS 启动恢复和后台 push；
- 重启持久化和优雅退出；
- 容器日志中不存在 Secret。

### 6.4 真实端到端测试

使用真实 Matrix server、真实 QwenPaw 2.0.1、候选 Worker 镜像和真实模型 endpoint：

- Worker 登录和首次 sync；
- direct room 收消息和回复；
- team room mention gating；
- invite 和 auto-join；
- TaskRoom 请求、进度、工具活动、结果和 reviewer 流程；
- Matrix thread root 和 continuation routing；
- 长文本、Markdown、附件和错误渲染；
- 重启后无需重新配置即可继续收发；
- Matrix credential 在线轮换；
- 与另一个已启用 QwenPaw Channel 共存；
- 一次真实模型调用和一次真实注册工具调用。

## 7. 失败与恢复语义

- QwenPaw 未就绪：只在启动策略内重试，Worker readiness 保持 false。
- 启动后临时 API 失败：保持 applied generation 不变，报告 degraded，并重试同一 desired state。
- 校验或永久拒绝：保留 last-known-good，记录被拒 generation 和原因，等待 desired state 变化或显式 reconcile。
- 多资源部分成功：不得宣称 generation 已应用；重试时读取真实状态后幂等收敛。
- 必需 Matrix 插件加载失败：必须阻止 readiness，并明确插件名称。
- Readback 不一致：即使 mutation 返回 2xx，也按失败处理。
- 状态、错误、日志和测试快照都不能包含 Secret。

## 8. 升级与回滚策略

- 升级测试必须从真实 1.1.11 working directory 和对象存储 snapshot 开始。
- QwenPaw 内部存储迁移由 QwenPaw 2.0 自己负责。
- Worker 不得预先重写旧 QwenPaw 存储文件。
- 验收升级前创建可恢复 snapshot。
- 必须证明旧镜像可重新启动，或者验证基于 snapshot 的恢复流程。
- 如果 QwenPaw 迁移导致直接镜像回滚不安全，发布文档必须明确恢复边界和精确步骤。

## 9. 强制旧路径清理门禁

以下任一项残留，最终验收直接失败：

- Dockerfile 向 `site-packages/qwenpaw/...` 复制文件；
- Matrix `channel.py` overlay；
- `patch-qwenpaw-defer-mcp-startup.py` 或其他 QwenPaw 源码 patch；
- 直接写 QwenPaw `agent.json`、`config.json`、`access_control.json`、Driver Card 或 credential；
- Worker/插件构造 QwenPaw 内部配置模型进行 mutation；
- TeamHarness/WorkerFlow import QwenPaw 内部 runner/workspace service；
- API 失败后静默切换到直接文件写入；
- 只验证 mock 请求形状、不验证真实 QwenPaw 持久化和 GET 回读。

必须增加自动仓库扫描，检查已知文件路径和 import pattern。任何例外都必须带有明确所有权说明并人工审查。

## 10. 最终验收门禁

以下 A-J 全部强制通过。

### A. 构建与依赖完整性

- 从干净 checkout 为所有支持架构构建候选镜像；
- 镜像内版本精确为 QwenPaw 2.0.1；
- 没有未解决依赖冲突；
- LoongSuite 和 AgentScope instrumentation 正常 import 和启动；
- 镜像不包含 QwenPaw overlay 或 patch 产物。

### B. 插件完整性

- `agentteams-matrix-channel`、TeamHarness、WorkerFlow 均显示 loaded；
- Channel 插件在 workspace 构建前加载；
- install/reload/disable/uninstall/reinstall 全部通过；
- 公共插件 API 扫描通过；
- 卸载后无残留 registration，重装后无重复 tool/Channel。

### C. Desired-state 正确性

- 每个消费的 `runtime.yaml` 字段都有契约测试；
- readiness 前完成首次 desired-state 应用；
- 增量更新只修改本次提供的资源；
- 空 Secret 保留旧值，非空 Secret 完成轮换；
- 不变 generation 不产生 mutation；
- 失败或回读不一致不得记录成功；
- 每个 mutation 都有 GET 回读。

### D. Channel 行为

- `agentteams_matrix`、DingTalk、Feishu、WeCom 的启用、更新、禁用、restart 通过；
- visibility flags 的用户语义保持不变；
- 更新一个 Channel 不修改其他 Channel；
- 自定义 Matrix 与另一个 Channel 可同时运行；
- Channel health 反映真实运行状态。

### E. ACL 行为

- Matrix、DingTalk、Feishu、WeCom ACL 独立 reconcile；
- whitelist/blacklist 新增、删除和迁移通过；
- username/remark 更新通过，包括清空 remark；
- ACL 在 QwenPaw 和 Worker 重启后保持；
- 一个 Channel 更新不覆盖第三方 Channel ACL。

### F. MCP 与模型

- MCP 创建、更新、启停、删除和凭据轮换通过；
- MCP 重启后保持，删除项不会重新出现；
- MCP tool policy 应用并回读；
- model/provider 更新并回读；
- 一次真实模型请求和一次真实 MCP 或注册工具调用通过。

### G. Matrix 与 TaskRoom E2E

- direct、team、task room 收发正确；
- mention 要求及 bot/self-message 过滤正确；
- invite、auto-join、首次 sync、断线重连通过；
- thread root、continuation 和 result routing 通过；
- 长消息、Markdown 和附件通过；
- TeamHarness Task 创建、进度、工具活动、结果和 reviewer 流程完成；
- 运行中重启后继续成功处理消息。

### H. Package、存储和生命周期

- AgentSpec 安装、热更新、删除和回滚通过；
- package-owned 文件收敛且不删除 user-owned 文件；
- MinIO/OSS 恢复和后台 push 边界通过；
- heartbeat、readiness、last-active 通过；
- 优雅退出后没有孤儿 QwenPaw 进程；
- crash/restart 后收敛到 desired generation。

### I. 升级、回滚和安全

- 全新安装和 1.1.11 持久数据升级都通过；
- 存储迁移行为已记录并测试；
- 旧镜像回滚或 snapshot 恢复流程通过；
- QwenPaw Secret store 之外的运行时文件、日志、状态和测试产物不包含凭据；
- API client 仅连接预期本地 endpoint，不弱化认证，不对外暴露管理 API。

### J. 回归测试与发布证据

- QwenPaw Worker focused tests 通过；
- 插件 adapter tests 通过；
- 若协议改变，controller projection tests 通过；若未改变，记录协议未变证据；
- 所有镜像集成测试在同一个 release-candidate digest 上通过；
- 所有真实 E2E 在同一个 digest 上通过；
- 保存测试命令、日志、镜像 digest、QwenPaw 版本、环境信息和结果；
- 强制门禁中不存在未解释的 skip、flaky 或 expected failure；
- 源码、候选镜像、远端镜像、部署状态、Matrix 事件和 Trace 证据分别记录，互不替代。

## 11. Definition of Done

升级只有同时满足以下条件才算完成：

1. A-J 全部门禁在同一个不可变候选镜像 digest 上通过；
2. 旧路径自动扫描无未审查例外；
3. `runtime.yaml` 仍是 controller/worker 唯一 source of truth；
4. QwenPaw API 和公共插件 API 是唯一运行时 mutation 与扩展机制；
5. 全新安装、持久数据升级、重启恢复和回滚/恢复均已证明；
6. 真实 Matrix TaskRoom、真实模型请求和真实工具调用完成；
7. 文档全部更新，不再把 overlay、patch 或直接写文件描述为当前实现；
8. 源码测试通过不能替代镜像验证，镜像发布不能替代部署验证，Matrix 事件发送成功不能替代 Worker 执行和 Trace 证明。

任何少于以上条件的状态都只是中间实现，不得作为 QwenPaw 2.0 Worker 完整升级发布。

## 12. 2026-07-26 实施与验收记录

### 12.1 已完成实现

- Worker 和镜像固定使用 QwenPaw 2.0.1。
- 新增集中式 `QwenPawApiClient`，Channel、ACL、MCP、模型、Agent 和 Skill
  均通过 HTTP API 更新并 GET 回读。
- `runtime.yaml.channels.matrix` 映射到自定义 `agentteams_matrix` Channel；QwenPaw
  内置 `matrix` 保持存在且未被覆盖。
- TeamHarness 和 WorkerFlow 已迁移到 QwenPaw 2 公共插件 API。
- 删除 Matrix overlay 和 `patch-qwenpaw-defer-mcp-startup.py`，删除 Worker 内旧的
  私有插件注入路径。
- QwenPaw 管理的配置不再由 Worker 直接写入；AgentTeams 自有的 prompt、workspace
  和 package 资产仍由 Worker 按所有权写入。
- 修复首次后台 push 从时间零开始扫描整个 QwenPaw 工作目录的问题。
- package MCP 的旧 `http` transport 在 API 边界规范化为 `streamable_http`。

### 12.2 同一候选镜像的本地证据

候选镜像：

```text
agentteams/qwenpaw-worker:202607262326
linux/amd64
sha256:215edb138233ffe4f4aac078c7ba80954bbe2307658ed3cabc876c0aa7c8e90b
```

已通过：

- 单元、Worker 和插件测试：`183 passed, 2 skipped`；两个 skip 是平台/环境既有
  条件，不是本次功能 expected failure。
- `git diff --check` 和全部相关 shell `bash -n`。
- 镜像只读预检：QwenPaw 精确为 2.0.1，三个插件及安装 marker 存在，旧 patch
  不存在，内置 Matrix 源文件仍存在，自定义 Channel key 为 `agentteams_matrix`。
- 真实 QwenPaw 2.0.1 API：Channel、ACL、MCP、model、agent mutation 与 GET
  readback；内置 Matrix 和自定义 Matrix 同时出现在 Channel 列表。
- Worker daemon：API、TeamHarness health、heartbeat/readiness 通过。
- MinIO：启动恢复及后台 push 包含/排除边界通过。
- `runtime.yaml` 热更新：model、MCP、Channel、ACL 和 AgentSpec package 在不重启
  Worker 容器的情况下收敛并回读通过。
- QwenPaw 1.x 单 Agent working directory：使用 QwenPaw 2.0.1 原生迁移器迁移
  sessions、memory、chats、AGENTS.md、SOUL.md，生成 default `agent.json`，根配置
  保留降级兼容字段，第二次执行幂等 no-op。

复现迁移验收：

```bash
AGENTTEAMS_QWENPAW_IMAGE=agentteams/qwenpaw-worker:202607262326 \
  bash qwenpaw/tests/integration/test-qwenpaw-1-workdir-migration.sh
```

### 12.3 尚未完成且不能用本地证据替代的发布 Gate

以下动作会写远端镜像仓库或真实 AgentTeams 环境，需要明确发布目标和写操作授权；
在完成前，本计划状态是“本地 release candidate 验收通过，尚未完成生产级最终验收”：

- 将同一候选源码构建并推送为远端不可变多架构镜像；
- 在指定 AgentTeams 实例替换 QwenPaw Worker 镜像并验证 rollout/rollback；
- 使用真实 Matrix direct/team/task room 验证收发、mention、invite、thread、附件、
  TaskRoom reviewer 和重启恢复；
- 使用真实模型 endpoint 完成一次模型请求，并完成一次真实 MCP/注册工具调用；
- 读取部署后的容器日志和 SLS Trace，确认请求链路、插件加载、无 Secret 泄露；
- 对升级前 snapshot 执行一次真实恢复演练。

因此 A、C、H 的本地部分及 1.x 数据迁移已通过；B、D、E、F 的真实 QwenPaw API
部分已通过；F、G、I、J 中依赖远端发布和真实环境的条目仍保持未通过，不能宣布完整
Definition of Done。
