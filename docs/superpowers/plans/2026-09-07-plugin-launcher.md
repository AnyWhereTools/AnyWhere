# 插件搜索与自定义 UI 实施计划

> 本轮按用户后续指定的 `workflow` 串行执行，不启动其他编排流程。下方原始步骤保留作设计依据；实际文件与验证进度见下表，不将尚未执行的预期失败测试或分步提交勾选为完成。

## 当前实施进度（2026-09-08）

| 任务 | 实现与证据 |
|---|---|
| 1 清单与契约 | 已实现版本 4、UI API 1、纯 UI、资源边界；定向测试已通过 |
| 2 注册与入口 | 使用现有动作记录，Finder 快照和右键预览过滤纯搜索项；搜索开关单独持久化 |
| 3 搜索 | 标题/别名匹配、最长前缀、原文参数和最多十项最近使用；定向测试通过 |
| 4 数据 | 插件 KV、原子写入、配额、动作配置与密码完整删除；定向测试通过 |
| 5 任务 | `PluginTask.swift` 管理进程组、超时、取消、输出和跨块密码遮蔽 |
| 6–7 会话与 WebKit | 收口于 `PluginSession.swift`，使用原生 Promise 回复与自定义资源 scheme；真实 WKWebView 测试通过 |
| 8 搜索窗口 | `PluginLauncher.swift` 提供 Carbon 热键、原生输入、单窗口和会话切换；交互验收待完成 |
| 9 包生命周期与示例 | 独立开关、审阅资源变化、本地重载、更新停任务、可选清理；示例提供纯 UI 与 UI+后端两个功能 |
| 10 文档与验证 | 中英 SDK 文档、规范、README、类型声明已补全；177 项 Core 测试、预设回归、Debug 构建与 WebView 集成测试通过；桌面交互待验收 |

实现沿用现有配置与包事实来源，未建立额外的纯状态机、Host 接口或重复动作注册表。任务与输出过滤共用一个文件，网页 SDK 内嵌宿主并附独立类型声明。采用系统标题栏保留原生关闭、缩放和辅助功能。上述内部组织调整不改变批准的产品边界。

### 最终验证证据

- 2026-09-08，macOS arm64，Debug，ad-hoc 签名，原生 Xcode 工具链；当前工具列表无 IDE `build_project`。
- `swift test`：177 项通过。`make test-presets`：新建文件编号及剪切/粘贴回归通过。
- `xcodebuild -project AnyWhere.xcodeproj -scheme AnyWhere -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/anywhere-plugin-derived CODE_SIGN_IDENTITY=- build test`：构建及 AppTests 通过。
- AppTests 使用真实 WKWebView，验证上下文、标量 JSON 存储、未授权剪贴板、网页联网阻断、消息超限，以及真实后端的输出、退出结果和忙碌错误。
- 已核对新增中英文文案、JSON、文档链接及 `git diff --check`。验证时完整文件树 SHA-256：`f97c7fa7af26571fd20b1a8ea5c3b6cc4715b1fb28ce99d75dae4f8e23184e1c`（随后仅更新此进度文档）。
- 日志位于 `/tmp/anywhere-plugin-final-core.log`、`/tmp/anywhere-plugin-presets.log`、`/tmp/anywhere-plugin-final-app.log`，完整文件清单位于 `/tmp/anywhere-plugin-verified-tree.json`。
- 尚未把构建通过当成桌面验收：当前 CUA 无法连接尚未显示窗口的菜单栏应用，已请求用户从新版本菜单栏打开插件搜索。快捷键实体输入、中文输入法、多屏、Finder 实际菜单和导入/更新/卸载交互尚未全部验证。未使用真实私钥或用户日志。

**Goal:** 提供快捷键唤起的已安装插件搜索，在同一窗口展开自定义页面，并与现有 Finder 动作共享插件身份、配置和可选后端任务。

**Architecture:** Swift 主程序管理搜索、窗口会话和插件身份，WKWebView 运行插件自带静态页面。页面通过有界异步 Bridge 调用当前插件数据和当前动作任务；后端按需启动，退出时完成回收。

**Tech Stack:** macOS 13+、Swift 5.9、SwiftUI/AppKit、WebKit、Foundation、CryptoKit、Carbon 注册热键、XCTest、XcodeGen。保留现有 Swift Package 和 Xcode 应用结构，不引入 Node、Deno、Electron 或新增第三方依赖。

## 全局约束

- 已确认设计：[中文设计](../specs/2026-09-07-plugin-launcher-design.zh.md)。本计划不授权增加产品范围。
- 清单版本为 `4`，UI API 版本为 `1`；版本 `1–3` 的包行为和动作 UUID 保持兼容。
- 建议默认快捷键 `Control+Option+Space`；冲突时保留原绑定，不自动改用其他组合。
- 单搜索窗口、单 UI 会话、每会话单任务；隐藏保留会话，返回搜索结束会话。
- 搜索仅索引已安装且启用搜索入口的功能；最近使用最多 `10` 项，不保存查询正文。
- Bridge 消息上限 `1 MiB`，插件 JSON 数据上限 `5 MiB`，任务输出总量上限 `4 MiB`，任务取消宽限 `2 秒`。
- 插件 UI 默认离线，只加载包内资源；第一版原生能力为 `task.run`、`clipboard.write`，普通配置和本插件存储是基础接口。
- 现有密码仍由原生表单配置，任务注入密码，页面不获得通用密码读取能力。
- 不做跨应用文本服务、云同步、全盘索引、Node/Deno 运行时、常驻后端、多插件窗口或 Rubick 插件兼容。
- 源码起点为 `a66384d`，其后 `483369d` 仅增加设计文档；开始编码前重新核对 HEAD 和工作区，保留 `.codex/`、本地配置及其他用户改动。
- 新增生产代码属于 L3。先定向验证和审查，再冻结代码树，最后进行一次最终集成验证；不因提交或消息切换重复通过的检查。

## 执行路线与文件归属

任务依赖顺序：`1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10`。有些纯逻辑可独立编写，但其身份、持久化和事件接口尚在同一轮变动，采用串行实现，逐项检查后集成。实现前按 using-git-worktrees 技能建立隔离工作区和 `codex/` 分支；不清理当前 `.codex/`。

| 归属 | 路径 | 职责 |
| --- | --- | --- |
| 清单 | `Core/Sources/AnyWhereCore/PackManifest.swift`、`PackSnapshot.swift`、`PackInspector.swift` | 新声明与包内资源验证 |
| 共享类型 | 新增 `Core/Sources/AnyWhereCore/PluginContract.swift` | 身份、调用上下文、JSON 值、稳定错误码 |
| 搜索 | 新增 `Core/Sources/AnyWhereCore/PluginSearch.swift` | 纯索引、匹配、参数提取 |
| 数据 | 新增 `Core/Sources/AnyWhereCore/PluginDataStore.swift`、`PluginPreferencesStore.swift` | KV、入口开关、最近使用、已知动作归属 |
| 会话 | 新增 `Core/Sources/AnyWhereCore/PluginSessionState.swift` | 纯状态转换与效果，不调用 AppKit |
| 任务 | 新增 `Core/Sources/AnyWhereCore/ManagedTask.swift`、`StreamingRedactor.swift`、`ScriptInvocation.swift` | 可取消进程、输出处理、统一脚本命令构造 |
| 资源 | 新增 `Core/Sources/AnyWhereCore/PluginResourceResolver.swift` | 路径限定与可测试资源解析 |
| 宿主 | 新增 `App/Plugins/PluginHost.swift`、`PluginBridge.swift`、`PluginWebView.swift`、`PluginSchemeHandler.swift` | 会话效果执行、JS 通信、WKWebView 加载 |
| 入口 | 新增 `App/Plugins/LauncherWindowController.swift`、`LauncherView.swift`、`LauncherHotKey.swift` | 单窗口、搜索交互、热键注册 |
| 包管理 | `App/Managers/PackManager.swift`、`App/UI/PacksScreen.swift`、`App/UI/PackImportSheet.swift` | 统一解析、独立开关、更新与卸载 |
| 宿主测试 | 新增 `AppTests/`，修改 `project.yml` | WebKit、热键替身、包管理集成测试 |
| SDK | 新增 `App/PluginResources/anywhere.js`、`anywhere.d.ts` | Promise API、任务事件、类型提示 |
| 示例和文档 | 新增 `examples/ui-tool-pack/`，更新中英文 README 与规范 | 自定义 UI 示例和开发指南 |

新增类不是新的插件管理系统；包事实来源仍为 PackManager，已有配置来源仍为 PackConfigurationStore。所有下文新增类型都在对应任务中定义，不与原有对象保存重复事实。

## Task 1：清单 4、纯 UI 包与共享契约

**Files:** 修改 `PackManifest.swift`、`PackSnapshot.swift`、`PackInspector.swift`；新增 `PluginContract.swift`、`PluginResourceResolver.swift`；测试 `PackManifestTests.swift`、`PackSnapshotTests.swift`、新增 `PluginResourceResolverTests.swift`。

**Interfaces:**

```swift
public struct PackUI: Codable, Equatable, Sendable {
    public var entry: String
    public var height: Int?
}
public struct PackLauncher: Codable, Equatable, Sendable {
    public var keywords: [String]
}
public enum PluginCapability: String, Codable, Sendable {
    case runTask = "task.run", writeClipboard = "clipboard.write"
}
public enum PluginActionIdentity {
    public static func uuid(packKey: String, actionID: String) -> UUID {
        UUID.deterministic("pack.\(packKey).\(actionID)")
    }
}
public struct PluginInvocation: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case launcher, finder }
    public let apiVersion: Int
    public let invocationID: UUID
    public let actionID: UUID
    public let source: Source
    public let query: String
    public let argument: String
    public let paths: [String]
    public let variant: String?
}
```

`PluginContract.swift` 同时定义 `JSONValue`（null、bool、number、string、array、object；Codable/Equatable/Sendable）和 `PluginError`（code、message），错误码固定为 `invalidArguments`、`denied`、`sessionClosed`、`busy`、`failed`、`timedOut`、`cancelled`、`outputLimit`、`storageLimit`。上面结构需有 public 初始化器。

- [ ] 写入可复现的纯 UI 清单测试：

```swift
func testSchema4AcceptsUIWithoutScript() throws {
    let json = #"{"schemaVersion":4,"uiApiVersion":1,"name":"Text Tools","actions":[{"id":"format","title":"格式化","contextMenu":false,"launcher":{"keywords":["format"]},"ui":{"entry":"ui/index.html"}}]}"#
    let manifest = try PackManifest.decode(Data(json.utf8))
    try manifest.validate()
    XCTAssertNil(manifest.actions[0].script)
    XCTAssertEqual(manifest.actions[0].ui?.entry, "ui/index.html")
}
```

- [ ] 运行 `swift test --package-path Core --filter PackManifestTests`，确认失败来自新能力尚不存在。
- [ ] 将 `PackAction.script` 改为可选，并增加 `ui`、`launcher`、`contextMenu`、`capabilities` 默认值；包增加 `uiApiVersion`。低版本出现新字段必须拒绝；UI API 非 1 拒绝；UI 或脚本至少一个，菜单或搜索入口至少一个；`task.run` 必须有脚本。关键词去除外围空白后非空且忽略大小写去重；数组可为空；高度必须为正。调整受影响的 `map(\.script)` 为 `compactMap`，只改可选值相关代码，不移动业务逻辑。
- [ ] `PackSnapshot.read` 只读取已声明脚本，额外验证 HTML 为存在且可读的常规文件。`PluginResourceResolver.resolve(root: URL, relativePath: String) throws -> URL` 先拒绝绝对路径、NUL、反斜线和 `..` 段，再解析符号链接并比较完整路径分量；网络 URL 的解码仅由 scheme 层执行一次。
- [ ] 增加越界符号链接、嵌套资源、缺失 HTML、旧版本回读、错误 UI API、未知 capability、纯脚本及 UI+脚本的测试。运行 `swift test --package-path Core --filter 'PackManifestTests|PackSnapshotTests|PluginResourceResolverTests'`。
- [ ] 检查配置值未写入清单或 Finder 快照后，精确提交此任务文件，消息 `feat: define UI plugin manifest and invocation contract`。

## Task 2：统一动作解析与独立入口开关

**Files:** 修改 `Models.swift`、`ConfigStore.swift`、`App/Managers/PackManager.swift`、`App/AppState.swift`、`App/ActionDispatcher.swift`、`App/ActionRunner.swift`、`App/UI/MenuHubPanels.swift`；新增 `PluginPreferencesStore.swift`；测试 `ModelsTests.swift`、`IPCTests.swift`、新增 `PluginPreferencesStoreTests.swift`。

**Interfaces:** 在 App 中定义 `ResolvedPluginAction`，保存 `packKey: String`、`definition: PackAction`、`id: UUID`、`directory: URL` 和 `generation: UUID`。`PackManager.resolveAction(id: UUID) -> ResolvedPluginAction?` 从已安装清单派生，不从网页参数派生路径。新增 `launcherActions() -> [ResolvedPluginAction]` 和 `setLauncherEnabled(_: Bool, actionID: UUID) throws`。

- [ ] 在 `PluginPreferencesStoreTests` 使用两个稳定 action UUID，保存 A 的 launcher 开关并重建 store，断言 B 仍禁用；修改右键 `MenuAction.isEnabled` 不改变 store 结果。
- [ ] 定义 `PluginPreferencesStore(directory: URL)`，方法为 `isEnabled(actionID: UUID) throws -> Bool`、`setEnabled(_: Bool, actionID: UUID) throws`、`recent() throws -> [UUID]`、`recordUse(actionID: UUID, at: Date) throws`、`rememberActions(packKey: String, ids: Set<UUID>) throws`、`knownActions(packKey: String) throws -> Set<UUID>`、`removePack(packKey: String) throws`。文件保存单个 JSON，包含开关、最近使用和宿主记录的归属，原子写入，不保存查询。
- [ ] `MenuAction.Kind` 增加无网页资源载荷的 `.openPluginUI`。`MenuConfig.currentSchemaVersion` 提升为 2；保存含新 kind 的配置时标记版本 2，旧版本 1 可读取，旧客户端应通过现有版本探针拒绝新配置。补全所有 kind switch，插件 UI 不显示空脚本编辑器；不得构造 no-op ScriptSpec 伪装纯 UI。
- [ ] 导入只将 `contextMenu == true` 的动作写入菜单配置；搜索开关单独保存且默认禁用。`PackManager.actionUUID` 调用 Task 1 的唯一算法。配置读取新增按已解析动作获取 fields 的入口，原 `configurationFields(for:)` 委托它，保证 launcher-only 动作也可配置。
- [ ] 在 dispatcher 识别 `.openPluginUI` 后调用注入的 `openPluginUI: (ResolvedPluginAction, PluginInvocation) -> Void` 回调；未接 UI 的开发步骤仅记录功能尚未接入的受控错误，不能误执行脚本。纯脚本保持原通路。
- [ ] 补充配置版本 1→2、Finder IPC 编解码、纯搜索动作不进入菜单、来源变更不继承数据的测试，运行 `swift test --package-path Core --filter 'ModelsTests|IPCTests|PluginPreferencesStoreTests|MenuBuilderTests'`。
- [ ] 提交 `feat: register launcher entries beside Finder actions`。

## Task 3：搜索、参数提取与最近使用

**Files:** 新增 `PluginSearch.swift`、`PluginSearchTests.swift`；使用 Task 2 的 preferences。

**Interfaces:**

```swift
public struct PluginSearchEntry: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let keywords: [String]
    public init(id: UUID, title: String, keywords: [String]) {
        self.id = id; self.title = title; self.keywords = keywords
    }
}
public struct PluginSearchMatch: Equatable, Sendable {
    public let entry: PluginSearchEntry
    public let argument: String
}
// PluginSearch.matches(query:entries:recent:) -> [PluginSearchMatch]
```

- [ ] 添加首个排序与参数测试：

```swift
func testAliasKeepsArgumentCase() {
    let id = UUID()
    let entry = PluginSearchEntry(id: id, title: "翻译", keywords: ["tr"])
    let result = PluginSearch.matches(query: "TR Hello World", entries: [entry], recent: [])
    XCTAssertEqual(result.first?.entry.id, id)
    XCTAssertEqual(result.first?.argument, "Hello World")
}
```

- [ ] 运行 `swift test --package-path Core --filter PluginSearchTests` 得到预期失败。
- [ ] 实现不可变索引：查询比较使用忽略大小写选项，参数截取始终操作原字符串的 Range。匹配键为标题加别名；先比较匹配级别，再比较最近使用位置，最后 UUID 字符串；完整前缀参数匹配按原匹配长度降序。同分候选全部保留，由 UI 选择。
- [ ] 增加中文标题、重复别名、最长前缀、关键词含空格、换行参数、空白查询、无匹配、最近列表剔除已卸载项和 10 项上限测试。`recordUse` 仅在用户明确启动成功后更新，不在候选变化时更新。
- [ ] 运行同一测试类，提交 `feat: search installed plugin functions and parse arguments`。

## Task 4：插件数据与完整配置删除

**Files:** 新增 `PluginDataStore.swift`、`PluginDataStoreTests.swift`；修改 `PackSettings.swift`、`LocalEncryptedSecretStore.swift` 及相应测试中的 secret store 替身。

**Interfaces:** `PluginDataStore(directory: URL)` 提供 `get(_ key: String) throws -> JSONValue?`、`set(_ key: String, value: JSONValue) throws`、`remove(_ key: String) throws`、`removeAll() throws`。directory 由宿主绑定，不接受网页传目录。扩展 `PackSecretStore` 的 `removeAccounts(prefix: String) throws`，并由 `PackConfigurationStore.remove(actionID: UUID) throws` 同时删除动作明文文件及以 `UUID + "."` 开头的密码记录。

- [ ] 测试使用临时目录创建 A、B 两个 store：A 写入同名键不影响 B；A 删除全部不删除 B；重建实例仍能读取。加入错误 JSON、写入失败和超限后旧值不变的用例。
- [ ] 实现单 JSON 文件、串行读改写、原子替换和 `0700/0600` 权限；字节数在编码完成后判断，超过 5 MiB 返回 `storageLimit`，非有限浮点值、NUL 键或空键返回 `invalidArguments`。拒绝根目录及目标文件被替换成符号链接的情况。
- [ ] 密码前缀删除在现有加密 vault 的同一把锁内完成，不能反复 read/write 导致更新丢失。补充 A 的两个密码字段（含清单已移除字段）均删除、B 保留的测试；不要读旧钥匙串。
- [ ] 卸载所需动作列表来自当前清单与 Task 2 记录的历史归属并集。版本 4 之前已删除且没有归属记录的旧动作无法可靠反推所属包：不猜测或删除其他数据，清理提示明确仅处理可关联数据。这是兼容性限制，不新建全盘配置扫描工具。
- [ ] 运行 `swift test --package-path Core --filter 'PluginDataStoreTests|PackSettingsTests|LocalEncryptedSecretStoreTests'`，提交 `feat: isolate plugin data and support scoped configuration removal`。

## Task 5：可取消任务、流式输出与脱敏

**Files:** 新增 `ManagedTask.swift`、`StreamingRedactor.swift`、`ScriptInvocation.swift`；小范围修改 `ShellRunner.swift` 复用脚本命令构造；新增 `ManagedTaskTests.swift`、`StreamingRedactorTests.swift`、`ScriptInvocationTests.swift`。

**Interfaces:** `ScriptInvocation.make(spec:paths:variant:scriptBase:cwd:extraEnv:) -> CommandInvocation` 返回 executable、arguments、cwd、environment、timeout，保持现有 zsh 契约。`ManagedTask.start(command: CommandInvocation, secrets: [String], onEvent: @escaping @Sendable (TaskEvent) -> Void) throws -> ManagedTask`；实例 `cancel()`；`TaskEvent` 为 `.output(stream: TaskStream, text: String)` 和 `.finished(TaskCompletion)`；completion 包含正常化退出码、有界 stdout/stderr 以及可选 PluginError。

- [ ] 将已有 ShellRunner 脚本环境断言复用到 `ScriptInvocationTests`，保证参数包含空格、引号、换行时不执行命令替换，契约环境优先级不变。先提取命令构造，再运行原 `ShellRunnerTests`，不修改旧 runner 的超时与后台子进程策略。
- [ ] 对 `StreamingRedactor(secrets: [String])` 定义 `push(_ bytes: Data) -> Data`、`finish() -> Data`，以字节序列匹配、保留最大密码长度减一的未决后缀，在稳定前缀中进行最长优先替换，分别维护 stdout/stderr 状态。

```swift
func testRedactsSecretAcrossChunks() {
    var filter = StreamingRedactor(secrets: ["secret-123"])
    var output = filter.push(Data("begin secret-".utf8))
    output.append(filter.push(Data("123 end".utf8)))
    output.append(filter.finish())
    let text = String(decoding: output, as: UTF8.self)
    XCTAssertFalse(text.contains("secret-123"))
    XCTAssertTrue(text.contains("begin "))
    XCTAssertTrue(text.contains(" end"))
}
```

- [ ] 覆盖重叠密码、前缀密码、全部字节分块、UTF-8 中文以及 finish 未形成完整密码的尾部；UTF-8 解码层只输出完整码点，非法字节使用替换字符。任务原始累计输出先计数，超过 4 MiB 取消并报告 `outputLimit`。
- [ ] 用临时 shell fixture 测试正常输出、stderr、超时、SIGTERM 后仍运行、父进程退出但子进程持有输出管道、取消与自然完成竞争。句柄内部用串行执行域保证 finished 恰好一次，取消后继续有界排空管道；仅对已验证属于自己的进程组发信号，无法建立受控进程组时拒绝启动 UI 任务。不要在主线程 `waitUntilExit`。
- [ ] Task 7 的宿主为每次任务创建 `0700` 临时目录和 `0600` request.json，注入 `ANYWHERE_REQUEST_FILE`；无 UI 搜索脚本同样使用结构化请求，但保持原脚本队列排序。临时文件直到子进程与管道回收后清除。
- [ ] 运行 `swift test --package-path Core --filter 'ManagedTaskTests|StreamingRedactorTests|ScriptInvocationTests|ShellRunnerTests'`，提交 `feat: run cancellable plugin tasks with redacted output`。

## Task 6：纯会话状态与 Bridge 协议

**Files:** 新增 `PluginSessionState.swift`、`PluginBridgeProtocol.swift`、对应 `PluginSessionStateTests.swift`、`PluginBridgeProtocolTests.swift`。

**Interfaces:** `PluginSessionState` 是值类型，状态为 `.search(query:selectedIndex:)`、`.loading(PluginInvocation)`、`.plugin(PluginInvocation)`、`.ending(reason:)`、`.hidden`；`reduce(_ event: SessionEvent) -> (PluginSessionState, [SessionEffect])`。事件包括 `hotKey`、`queryChanged`、`submit`、`pageReady`、`returnToSearch`、`escape`、`hide`、`show`、`closeApp`、`taskFinished`。效果只包含 `showSearch`、`hideWindow`、`loadPlugin`、`cancelTask`、`recordUse`，不引用 AppKit。

Bridge 定义请求 `{id, method, params}`、回复 `{id, result?, error?}` 和事件 `{sessionID, taskID?, event, data}`。第一版方法固定为 `host.getInvocation`、`config.get`、`storage.get`、`storage.set`、`storage.remove`、`tasks.run`、`tasks.cancel`、`clipboard.writeText`；`tasks.run` 的参数为 JSON object，只有当前 action 的脚本可以被宿主解析。

- [ ] 先写状态转移测试：隐藏后再次热键恢复同一插件；插件态 Escape 返回搜索；返回搜索发出取消；关闭应用结束任务；新调用不会覆盖旧会话；任务完成只作用于相同 sessionID/taskID。
- [ ] 运行 `swift test --package-path Core --filter PluginSessionStateTests` 确认失败，再实现纯状态机并通过。
- [ ] 为协议 Codable 写成功、错误、进度、取消和未知事件测试；解码拒绝超过 1 MiB 的原始消息、缺少 id、重复字段和非 object 参数。错误只携带稳定 code 与可读 message，不携带密钥、绝对包路径或完整输入文本。
- [ ] `PluginBridgeProtocol` 的编码和 API 版本校验保持 WebView 与 App 侧单一来源，提交 `feat: define plugin session and bridge protocol`。

## Task 7：WebView 宿主、资源加载与会话绑定

**Files:** 新增 `App/Plugins/PluginHost.swift`、`PluginBridge.swift`、`PluginWebView.swift`、`PluginSchemeHandler.swift`、`PluginSessionController.swift`；修改 `project.yml`（WebKit 已由 macOS SDK 提供，无第三方依赖）；新增 `AppTests/PluginResourceTests.swift`、`PluginBridgeTests.swift`。

**Interfaces:** `PluginHost.open(_ action: ResolvedPluginAction, invocation: PluginInvocation)`、`PluginHost.returnToSearch()`、`PluginHost.hide()`、`PluginHost.terminateAll()`；`PluginSessionController` 实现 `PluginSessionState` 的 effects，并以 `sessionID` 管理一个 WKWebView、一个任务句柄和一个 PluginDataStore。

- [ ] 为每个会话创建新的非持久 `WKWebsiteDataStore`、`WKWebViewConfiguration` 和 `WKUserContentController`，只注册 `anywhere` 一个 message handler；注入 `window.anywhere` SDK 时将 sessionID 留在原生闭包，不由网页传回。
- [ ] `PluginSchemeHandler` 只服务 `anywhere://plugin/<generation>/<relative-path>`，根目录来自 `ResolvedPluginAction.directory`。拒绝外部 URL、重定向、iframe 跨包资源、非 UTF-8 HTML 和资源越界；响应按 MIME 类型返回，页面策略禁止远程脚本、远程 frame 和网络连接。所有加载失败显示可重载的宿主错误页。
- [ ] `PluginBridge` 验证来源页面仍为当前 generation、请求方法属于 capability、参数大小和 JSON 类型符合协议，再交给主线程 `PluginSessionController`；回复必须异步发送且最多一次。页面导航、刷新、关闭和插件更新立即使旧 sessionID 失效。
- [ ] `config.get` 委托 Task 2 的配置读取；`storage.*` 委托 Task 4 的当前插件 store；`clipboard.writeText` 只在 capability 存在时写入；`tasks.*` 委托 Task 5 并将事件切回 WebView。页面不可读取通用密码、任意路径或其他插件数据。
- [ ] 在 AppTests 中用内嵌 HTML fixture 验证 JS `window.webkit.messageHandlers.anywhere.postMessage` 到回复的闭环、跨会话旧回复丢弃、越界资源、远程导航拒绝、权限拒绝和超过消息限制；使用假的 PluginHost/Task，不依赖真实 Finder。
- [ ] 运行 `xcodegen generate` 后通过测试目标构建并运行 AppTests；提交 `feat: host isolated plugin webview sessions`。

## Task 8：搜索窗口、热键与设置

**Files:** 新增 `App/Plugins/LauncherWindowController.swift`、`LauncherView.swift`、`LauncherHotKey.swift`、`App/UI/PluginHostView.swift`；修改 `App/AnyWhereApp.swift`、`App/AppDelegate.swift`、`App/UI/GeneralTab.swift`、应用中英文 `Localizable.xcstrings`；新增 `AppTests/LauncherTests.swift`、`LauncherHotKeyTests.swift`。

**Interfaces:** `LauncherWindowController.show()`、`hide()`、`toggle()`；`LauncherHotKey.register(key: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws` 和 `unregister()`；`LauncherViewModel` 使用 `PluginSearch.matches`，暴露 `query`、`matches`、`selectedIndex`、`submit()`、`escape()`。

- [ ] 先为 ViewModel 写测试替身：空查询显示最近 10 项，回车生成 `PluginInvocation(source: .launcher)`；候选歧义不启动；输入法 marked text 时回车不提交；Escape 在搜索态隐藏，在插件态交给 session state。
- [ ] 实现 AppKit 全局热键注册，保存 EventHotKeyRef 和 handler；注册失败只显示设置提示，不更换用户指定组合。`AppDelegate` 启动时创建 controller 并在退出时注销；菜单栏添加“打开插件搜索”。默认值和中英文文案加入 General 设置，不与登录启动设置混用。
- [ ] SwiftUI 搜索窗口使用 `.borderless` 外壳但保留系统可访问性；按鼠标屏幕定位一次，`.defaultSize` 由插件 height 约束；搜索态输入获得焦点，插件态只显示宿主顶栏和 `PluginHostView`。关闭按钮执行 hide，不销毁 session。
- [ ] 完成窗口状态测试、热键冲突测试、中文输入法测试、窗口重开和多屏定位测试；人工验证快捷键、失焦保留、返回搜索、重新进入和应用退出。提交 `feat: add global plugin launcher window`。

## Task 9：包导入、更新、右键兼容与示例

**Files:** 修改 `PackManager.swift`、`PackImportSheet.swift`、`PacksScreen.swift`、`ActionDispatcher.swift`、`ActionRunner.swift`、`MenuBuilder.swift`；新增 `examples/ui-tool-pack/manifest.json`、`ui/index.html`、`ui/app.js`、`actions/fixture.zsh`、中英文 README 与扩展包规范章节；测试 `PackManagerTests.swift`、`ActionRunnerTests.swift`、示例包验证脚本。

- [ ] 导入审查显示 UI 入口、搜索关键词、右键入口、capability、HTML 和二进制文件；HTML/JS/CSS 不作为可执行脚本计入脚本列表，未声明资源仍需审阅。默认搜索和右键均禁用，保持现有导入安全闸门。
- [ ] 更新按稳定 `PackAction.id` 保留各入口开关、配置和数据；generation 每次安装目录替换时重新生成。应用更新前结束同包 session；取消更新保留旧页面和旧包。卸载先终止 session/task，再删除可关联配置、密码、PluginData 和 preferences 记录，错误按设计文档报告。
- [ ] 修改 ActionDispatcher：右键只接受 `contextMenu`、文件匹配和启用状态；UI 动作转 `PluginInvocation(source: .finder)`，路径仍经原有存在性和数量闸门；纯脚本与 `.openWith` 输出不变。修改 ActionRunner 接收结构化 request file 仅用于 UI 任务，老动作不改变参数顺序和串行队列。
- [ ] 示例页面完成：显示进入上下文、编辑文本、调用 fixture task、显示流式输出、复制结果和保存一个插件数据键；不使用网络、不包含真实密钥。示例同时演示 UI-only 和 UI+script 两个 action。
- [ ] 运行现有 `swift test --package-path Core`、新增 AppTests、`make test-presets`；执行导入／更新／卸载的临时目录集成测试；提交 `feat: integrate UI plugins with pack lifecycle and Finder actions`。

## Task 10：审查、最终验证和文档发布

**Files:** 修改 `README.md`、`README.zh.md`、`docs/pack-spec.md`、`docs/pack-spec.zh.md`、`CONTRIBUTING.md`、`CONTRIBUTING.zh.md`、`SECURITY.md`、`SECURITY.zh.md`、`examples/example-pack/*`；必要时新增 `docs/plugin-sdk.md`、`docs/plugin-sdk.zh.md`。

- [ ] 文档说明两个入口、清单 4、UI API 1、`window.anywhere` API、会话规则、资源限制、无 Node/Deno 承诺、Go/Rust/Node 后端通过受管任务接入、插件独立数据目录和卸载行为。中文入口链接到中文页面；英文示例与中文示例的机器字段保持一致。
- [ ] 完成代码审查：确认网页不能伪造插件身份、不能访问任意路径或其他插件数据，旧右键动作未改语义，密码未进入页面、快照或日志，旧清单仍能导入。检查所有新增用户文案的中英文键和注释语言。
- [ ] 冻结最终代码树并记录完整树身份；运行 `swift test --package-path Core`、AppTests、`make test-presets`、`git diff --check`，随后用 IDE MCP 的 `build_project`（若当前环境无此能力，记录后使用项目原生 `xcodebuild`）进行一次 Debug 全工程构建。
- [ ] 启动构建产物，手工验证快捷键搜索、中文输入法、插件展开／隐藏／返回、任务取消、错误页、Finder 右键旧动作和 UI 动作；不要使用真实私钥、真实用户日志或外部网络作为测试输入。
- [ ] 汇总未验证边界：跨应用文本服务、独立窗口、多任务并行、常驻后端、Node/Deno 完整兼容和恶意后端的系统级沙盒不属于本计划。完成审查后提交 `docs: document plugin launcher and custom UI SDK`，不自动推送或发布。

## 计划自审

- 设计文档的入口、会话、Bridge、后端、存储、更新和验收各节均有对应任务；右键旧动作的兼容性在 Tasks 2、9、10 重复作为边界检查而非重复实现。
- 本计划没有使用 `TODO`、`TBD` 或未定义的函数名；跨任务接口在所属任务中给出了类型或方法签名。
- `PackAction.script` 变为可选会影响现有 `map`、审查和更新代码，Task 1 明确所有调用点；新 `.openPluginUI` 会影响每个 kind switch，Task 2 和 Task 8 明确覆盖。
- Task 5 保留既有 ShellRunner 的后台进程语义，只对 UI 任务要求可控进程组；因此不会把旧 preset 的退出行为悄然改成杀进程组。
- 当前仓库没有现成 AppTests 目标，Task 7 明确由 XcodeGen 创建；最终验证包含生成、测试、构建和 macOS 原生操作，避免只凭 Core 单测宣称完成。
