# 本机 MCP 开发与验证记录

日期：2026-10-30（Asia/Shanghai）。实现位于 AnyWhere 和同级 anywhere-todo 两个仓库，均保留开发前已有的未提交内容。开发初期未提交、发布、更新真实插件数据或修改 Codex 配置；后续接入与分离提交的验证分别记录在下文。

## 实现

- schema 5 的 commands 声明定义后台入口、受管存储键、参数/结果 Schema；mcp 声明只导出指定命令。
- AnyWhere 自动提供 list 和插件工具；当前 Todo 导出 list/create/update/complete。本机 stdio 辅助程序随 App 打包，通过同用户 Unix Socket 调用宿主。
- 授权默认关闭并绑定声明，执行及副作用前复核授权；支持动态撤销工具通知。不同插件隔离命名空间，未授权的重名插件不会遮蔽已授权插件。
- 界面、AI、提醒按钮共用插件命令队列；受管数据禁止普通页面旁路写入。Todo 校验版本，保留冲突草稿，复用原有提醒生成和调度。
- 保存结果与提醒同步结果分别返回；启动恢复读取最新 Todo。后台页面关闭后，队列等待已开始的原生调用及进程退出，避免旧副作用晚到。

## Review

独立进行规范/工程检查和需求检查，确认的阻塞项均已修正并复核：

| 检查 | 发现与处理 |
| --- | --- |
| 需求 | 待办与清单 ID 可相同，版本映射拆为独立集合，并添加冲突回归 |
| 需求 | 通用标量/数组结果包装成 MCP structuredContent 对象 |
| 工程 | 后台命令的副作用增加只读与授权检查，禁止交互式宿主调用 |
| 工程 | 先关闭命令页面，再等待原生操作和脚本退出；测试确认完成回调不能再次启动脚本 |
| 工程 | 新设置加入中英 String Catalog，工具链文档同步为 Xcode 16.3+/Swift 6.1 |
| 集成 | busy 变化立即渲染按钮状态；异步操作的原有测试改为等待真实就绪条件 |

## 验证证据

最终代码树摘要（含两个仓库代码、测试、声明、构建配置和解析后的依赖输入）：

`0975009dff690affb775172679c560c09124b28d2407b94c31e972a5079ce48a`

完整文件摘要与命令记录保存在本机临时文件 `/tmp/anywhere-mcp-final-freeze.json`。环境：Apple Silicon、Xcode 26.5 / Swift 6.3.2，SDK 固定为官方 MCP Swift SDK 0.12.1。没有可用 IDE MCP build_project，使用工程原生工具验证。

| 验证 | 结果 | 日志 |
| --- | --- | --- |
| Core `swift test` | 202 项通过，0 失败；Core 在此之后未修改 | `/tmp/anywhere-mcp-final-core.log` |
| Todo `node test.cjs`、`node commands.test.cjs`、`node --check app.js` | 全部通过 | 本聊天工具输出 |
| 最终原生相关测试 | 12 项通过，0 失败：5 项命令/MCP 测试和 7 项 Todo 原有回归 | `/tmp/anywhere-mcp-final-native-2.log` |
| 其余未受后续 Todo/UI 修正影响的原生测试 | 7 项通过：目录校验、文档、JSON/Quicklinks、提醒面板、普通插件桥接；复用通过证据 | `/tmp/anywhere-mcp-final-native.log` |
| Debug App 与辅助程序打包 | 原生测试构建通过；真实运行包内 anywhere-mcp | 同最终原生日志 |
| `codesign --verify --deep --strict build/Build/Products/Debug/AnyWhere.app` | 通过 | 本聊天工具输出 |
| 两仓库 `git diff --check` | 通过 | 本聊天工具输出 |

实际 stdio 测试完成 initialize、工具发现、创建、修改、冲突、完成、查询，并等待客户端收到授权撤销通知后确认旧工具无法调用。真实 WebView 测试确认两个待办的修改互相保留、同一待办旧版本被拒绝且草稿保留、重复提醒完成后取消、只读命令不能写、脚本完全退出后才执行下一条。

首次扩大原生验证发现的旧夹具声明和就绪判断问题已修复；最终只重跑受影响的 12 项，不重复运行已经通过且输入未变化的 Core 与其他 7 项原生检查。

## 产物与边界

Debug 应用：`build/Build/Products/Debug/AnyWhere.app`；辅助程序位于其 `Contents/MacOS/anywhere-mcp`。使用与插件接入说明见 [mcp.zh.md](mcp.zh.md)。重新加载本地 Todo 包并开启其 MCP 访问后，客户端只需注册一次 AnyWhere 服务。

开发阶段尚未连接用户真实 Codex 会话；后续本机接入结果见下节。未做旧版 macOS 回归、Release 归档/公证或远程访问验证。系统通知相关证据仅覆盖当前测试宿主，不代表其他机器的通知授权或送达。

## 后续：本机 Codex 接入与实际待办验证

2026-10-30 已将验证后的 Debug 应用更新到 `/Applications/AnyWhere.app`，使用 `codex mcp add anywhere -- /Applications/AnyWhere.app/Contents/MacOS/anywhere-mcp` 添加全局配置。语义比较确认其他 Codex 配置未改变。

原 Todo 为远程 schema 4 安装。保留安装键 `appdev-anywhere-todo`，将安装来源切换到同级 `anywhere-todo` 本地仓库，再通过 AnyWhere 的“重新加载本地包…”审阅并应用 schema 5。界面已开启“允许通过 AnyWhere MCP 调用”。重载完成、测试开始前，待办数据文件 SHA-256 与重载前一致。

旧应用与原 Codex/插件安装配置备份在本机私有临时目录 `/var/folders/ts/77d2rhjn34l7d8_n9qdff2f00000gn/T/anywhere-mcp-setup-rkduvk76`。本轮没有手工修改 Todo 数据文件。

实际验证使用 **Codex CLI 0.153.4 的 App Server**，通过其官方 `mcpServerStatus/list` 和 `mcpServer/tool/call` 接口调用配置中的 stdio 服务。使用内存测试上下文（ephemeral），没有发起模型 turn 或创建持久化的用户聊天，也未重启当前 Codex。电脑操作工具禁止访问 Codex 自身窗口，因此未点击桌面端的刷新按钮，不能把本次结果描述为当前聊天工具列表已热刷新。

| 步骤 | 实际结果 |
| --- | --- |
| Codex 发现服务 | `anywhere`，工具为 `list`、`todo` |
| 查询插件 | Todo 导出 `list/create/update/complete` |
| 创建前查询 | 测试 ID 无记录 |
| 新建 | saved=true，提醒同步 synced，无提醒时间 |
| 修改 | 标题追加“（已修改）”、更新备注，优先级设为 1 |
| 完成 | done=true，提醒同步 synced |
| 完成后回查 | 按测试 ID 查询 completed，返回唯一记录且标题/完成状态正确 |
| 界面核对 | Todo 的“已完成”列表可见该测试项，复选框为已完成；原有已完成记录仍在 |

保留的测试待办：`Codex MCP 联调测试 2026-10-30（已修改）`，ID 为 `codex-e2e-20261030-908b5a9682ea`。只操作这一条测试项，未改其他待办。调用结果记录在上述临时目录的 `codex-mcp-e2e.json`。

## 2026-10-31：新建待办自动生成 ID

create 的 requestId 已改为可选；新任务的 ID 由 Todo 内部生成，可选去重键另行持久化。旧任务不改 ID，仍兼容旧的请求键重试；未传键的重复创建请求会产生不同任务，结果不确定时不能自动重发。界面与命令共用原有随机 ID 生成方式，创建响应继续返回 item.id/version 供修改和完成使用。

本轮代码树：`8438de0ce4be5e8051acf97aebafb271afa3954403bd27b389e17fb13be212a4`；文件摘要见 `/tmp/anywhere-auto-id-full-tree.json`。两组 Todo Node 测试及语法检查通过，覆盖无键创建、键与 ID 分离、跨重新读取去重、旧任务重试、删除/恢复后的键冲突和版本保护。原生相关 12 项全部通过（`/tmp/anywhere-auto-id-native.log`），包含不传 requestId 的真实 stdio 流程与原有界面回归。宿主生产代码未改，不重跑无关 Core/其他模块测试。

已通过 AnyWhere 界面重载本地 Todo 并重新开启 MCP。Codex App Server 实际发现 create.required 只有 fields；仅传 fields.title 即创建成功，随后以返回 ID 查询、修改、完成和回查通过。测试待办为“Codex MCP 自动 ID 测试 2026-10-31”，ID `6a33f2808a90a08ba13c9fb02085f56d`，保留为已完成，提醒同步 synced。详细结果见 `/tmp/anywhere-auto-id-live.json`。本次未修改其他待办或 Codex 配置。

## 2026-10-31：独立提交快照验证

按开发前快照逐处拆分暂存内容，排除既有的摘要、图标、设置页重排、提醒面板和 Todo 时间选择器等改动。MCP 刷新事件由命令运行时提供；授权开关抽为独立组件，在现有插件列表中接入，避免依赖尚未提交的设置页。Todo 命令保留既有提醒生成策略，并报告系统通知未授权的同步失败。

两个仓库的索引内容导出到独立临时目录后验证，不依赖工作区的其他改动：Core `swift test` 194 项通过（`/tmp/anywhere-commit-core.log`）；原生测试 7 项通过（`/tmp/anywhere-commit-native.log`），包含全部 5 项命令/MCP 测试、Todo 数据升级与完整界面生命周期、真实表单持久化及提醒同步。Todo 的 `node test.cjs`、`node commands.test.cjs`、`node --check app.js` 在索引快照和原工作区均通过。两个索引的 `git diff --cached --check` 通过。

此次只验证并分别提交 MCP 与 Todo 命令接入；其他未提交内容保留。未重新安装应用、修改 Codex 配置、操作真实待办或执行 Release 归档/公证。
