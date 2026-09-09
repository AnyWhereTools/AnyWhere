# Independent Launcher Product Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将现有快捷启动器改造成与 AnyWhere 现有视觉一致的 A 版单列全局工具面板。

**Architecture:** 复用 `PackManager`、`PluginSession`、`ActionRunner` 和 `WorkflowExecutor`。新增统一目录索引与面板状态，面板只负责搜索/导航，执行由路由层分发。

**Tech Stack:** Swift 5、SwiftUI、AppKit、WebKit、Swift Package Manager XCTest。

## 实施结果（2026-09-09）

已在 `main` 工作区完成，按用户要求不提交。用户后续明确要求保留原快速启动，因此保留应用搜索和自建快捷指令；空查询显示已启用入口的最近使用。

- 统一目录：`LauncherCatalog.swift` 复用 `PluginSearch`，整合动作、工具、工作流，按标题、关键词、描述及最近使用排序。
- 面板：单列结果、类型与描述、最近使用、返回保留搜索词和选择、Esc/回车/方向键；重新打开运行中的应用会展示面板。
- 执行：复用 `ActionRunner`，由 `LauncherWorkflowRun` 调用 `WorkflowExecutor` 顺序传值，支持失败停止、取消和结果重试。路由直接保留在现有控制器，不新增只做转发的路由对象。
- 独立窗口：`ToolWorkspaceController` 每个工具持有独立 `PluginSession`/WebView，重复打开聚焦已有窗口，关闭后重新创建会话；插件返回事件只影响所属窗口。
- 管理：工作流有单独启用开关，默认禁用；禁用、更新和卸载关联会话与任务，复用现有偏好和配置存储。
- Demo：`examples/tool-panel-demo/`，含便笺、JSON 面板、动作、成功与失败工作流，已在本机导入并启用供试用。

### 验证证据

- `swift test --package-path Core`：188 项通过。
- Xcode App 测试：搜索/最近使用、工作流真实脚本传值/失败停止/取消、独立 WebView 状态隔离/关闭重开、原有桥接/权限限制、Demo JSON 页面与浅深色渲染均通过（5 个测试方法，按影响分批运行）。
- 最终 Debug 构建和 `git diff --check` 通过。测试后仅新增的入口/失败文案修正已构建并实机确认，没有重复运行未受影响的 Core 测试。
- 真实 UI：本地导入审阅、默认禁用、启用、标题/关键词参数搜索、方向键/回车/Esc、返回保留查询、独立窗口、成功/失败工作流与重试、重启后最近使用、禁用后入口消失、本地重载、卸载后入口和会话清理、重新导入全部验证。
- 数据回归：Demo 卸载后配置精确恢复原有 10 条；重新导入后仅多出 Demo 的 5 条。原有 Xlog 包及 Finder 的“解密 Xlog”“打开终端”等菜单仍可见。
- 边界：自动化发送的全局热键没有得到可靠的系统级响应；实际使用已配置的全局快捷键仍需物理键盘确认。面板本身的键盘导航已验证，菜单/重新打开应用入口可用。

下面保留原始任务步骤供追溯；其中提交与逐步先失败命令不作为本次已执行记录。

## Global Constraints

- 首屏只搜索已启用扩展包的工具、动作和工作流。
- 主入口使用可配置全局快捷键，菜单栏图标保留为备用入口。
- 面板使用 A 方案单列列表，沿用现有 AnyWhere 视觉和深浅色主题。
- 工具和工作流默认在面板内展开，带 UI 工具保留独立窗口入口。
- 不增加应用/文件搜索、在线市场、跨 Pack 工作流、拖拽编排、账户或云同步 UI。
- 不改变 Finder 菜单和扩展包导入协议。

---

### Task 1: 建立启用 Pack 的统一目录

**Files:**
- Create: `App/Plugins/LauncherCatalog.swift`
- Modify: `App/Plugins/PluginLauncher.swift`
- Test: `AppTests/LauncherCatalogTests.swift`

**Interfaces:**
- `LauncherCatalog(entries:)` 接收 `[PackConfiguration]` 或现有 Pack 管理结果。
- `search(_ query: String) -> [LauncherEntry]` 返回按匹配优先级和最近使用排序的条目。
- `LauncherEntry` 包含 `id`、`title`、`subtitle`、`kind`、`packID` 和执行引用。

- [ ] 写测试：禁用 Pack 不出现在结果；标题匹配排在描述匹配前；空查询返回最近使用。
- [ ] 运行 `xcodebuild test -scheme AnyWhere -destination 'platform=macOS' -only-testing:AppTests/LauncherCatalogTests`，确认先失败。
- [ ] 使用现有 manifest/action/workflow 字段实现最小索引，不复制 Pack 校验逻辑。
- [ ] 重跑同一测试，确认通过。
- [ ] 提交 `feat: add enabled pack launcher catalog`。

### Task 2: 实现 A 版面板列表 UI

**Files:**
- Modify: `App/Plugins/PluginLauncher.swift:226-360`
- Modify: `App/UI/ShortcutsScreen.swift`（仅复用现有颜色、圆角、快捷键编辑入口）
- Test: `AppTests/PluginSessionTests.swift`（补充面板状态不依赖 WebView 的测试）

**Interfaces:**
- `PluginLauncherView` 使用 `LauncherCatalog.search`，绑定 `query`、`selectedID` 和 `focusRequest`。
- 新增 `PanelState`：`.search`, `.tool`, `.workflowResult`。

- [ ] 写状态测试：空查询为 `.search`；进入工具后为 `.tool`；返回恢复原 query 和 selectedID。
- [ ] 运行 `xcodebuild test -scheme AnyWhere -destination 'platform=macOS' -only-testing:AppTests/PluginSessionTests`，确认先失败。
- [ ] 将现有启动器结果区改为单列“最近使用/搜索结果”，保留原 `NSTextField`/AppKit 键盘处理方式。
- [ ] 调整窗口高度随结果数变化，复用现有半透明、圆角、阴影、深浅色颜色。
- [ ] 重跑测试并执行 `make build`。
- [ ] 提交 `feat: add launcher search panel UI`。

### Task 3: 接入动作、工具和工作流执行

**Files:**
- Modify: `App/Plugins/PluginLauncher.swift`
- Modify: `App/ActionRunner.swift`
- Modify: `Core/Sources/AnyWhereCore/Workflow.swift`（仅在接口不足时）
- Test: `AppTests/LauncherExecutionTests.swift`

**Interfaces:**
- `ExecutionRouter.execute(_ entry: LauncherEntry, input: String, completion: @escaping (Result<ExecutionOutput, Error>) -> Void)`。
- 动作调用现有 `ActionRunner.run`；工具复用 `PluginSession`；工作流调用 `WorkflowExecutor.run`。

- [ ] 写测试：动作路由一次；工作流按顺序传递输出并在失败处停止；未知条目返回错误。
- [ ] 运行聚焦测试确认先失败。
- [ ] 实现最小路由，错误在面板状态中显示“返回/重试”。
- [ ] 工具页面顶部提供“返回”和“独立窗口打开”，独立窗口继续使用现有独立 `PluginSession`。
- [ ] 重跑聚焦测试和 `swift test --package-path Core`。
- [ ] 提交 `feat: route launcher entries to existing runtimes`。

### Task 4: 管理联动、最近使用和最终验收

**Files:**
- Modify: `App/Managers/PackManager.swift`
- Modify: `App/Plugins/PluginLauncher.swift`
- Modify: `App/AppState.swift`（若现有配置入口在其他文件，以实际定义为准）
- Test: `AppTests/LauncherIntegrationTests.swift`

**Interfaces:**
- `PackManager` 变更后向目录发布刷新事件。
- `LauncherCatalog.recordUse(_ id: UUID)` 持久化最近使用顺序。

- [ ] 写集成测试：启停 Pack 刷新结果；更新/卸载关闭关联会话；重新打开面板没有旧会话。
- [ ] 运行聚焦集成测试。
- [ ] 接入刷新事件和最近使用存储，保持现有配置存储边界。
- [ ] 执行 `swift test --package-path Core`、`make build`、启动 Debug App，手工验证快捷键、搜索、回车、Esc、返回、独立窗口和浅/深色主题。
- [ ] 运行 `git diff --check`，提交 `feat: complete launcher management integration`。
