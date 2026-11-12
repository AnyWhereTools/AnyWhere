# AnyWhere 开发者文档

[English](README.md) · 简体中文 · [项目首页](../README.zh.md)

这里面向插件作者和 AnyWhere 主工程贡献者，按当前源码介绍开发、调试和测试方法。发布版本可能落后于源码；新能力需要对应宿主构建，并按各指南检查方法是否可用。`schemaVersion: 4` / `uiApiVersion: 1` 本身不保证所有新增接口都存在。

## 从哪里开始

| 你要做什么 | 阅读路径 |
| --- | --- |
| 开发带界面的插件 | 下方入门 → [UI SDK 与生命周期](plugin-ui.zh.md) → [类型声明](sdk/anywhere.d.ts) |
| 增加 Finder 右键脚本 | [扩展包规范](pack-spec.zh.md) → [基础示例](../examples/example-pack/README.zh.md) |
| 给插件增加提醒 | [通知指南](plugin-notifications.zh.md)：能力声明、呈现选择、按钮回调、推迟和完成 |
| 在搜索首页展示摘要 | [摘要指南](plugin-summaries.zh.md)：`summary.html` 与只读存储 |
| 组合多个工具 | [同包工作流](plugin-ui.zh.md#同包工作流脚本与交互工具) → [工具链示例](../examples/tool-chain-demo/README.zh.md) |
| 修改宿主或贡献代码 | 下方主工程导航 → [贡献指南](../CONTRIBUTING.zh.md) → [发布指南](RELEASING.zh.md) |

## 跑通第一个 UI 插件

插件页面只需 HTML/CSS/JavaScript。使用已安装的 AnyWhere 即可开发，不必先编译主工程，也不需要 Node 运行时。

1. 复制仓库中的 [examples/ui-tool-pack](../examples/ui-tool-pack/) 到固定的开发目录。根目录是 `manifest.json`，页面是 `ui/index.html`，演示后端是 `actions/demo.zsh`。
2. 在 AnyWhere「扩展包 → 导入 → 选择本地文件夹…」选择复制后的目录，审阅并导入。在包详情中开启「文本工具」的搜索入口；搜索与 Finder 右键入口分别启用。
3. 按默认快捷键 `Control+Option+Space`，输入 `text hello` 后回车。页面应显示参数 `hello`；尝试大写转换、复制、保存草稿和取消后端任务。
4. 在通用设置开启开发模式，修改源目录的页面，再用「重新加载本地包…」审阅并应用修改，然后重新打开工具。Web Inspector 可检查新建页面。

**重新加载本地包**把源文件复制到安装副本；**重新加载页面**只重建已安装页面的会话。关闭、重载或转为独立窗口会结束旧会话，需要保留的内容先用 `anywhere.storage` 保存。保持来源目录和 action ID 稳定，避免产生新的插件身份。

宿主直接注入 `window.anywhere`，不要从网络加载 SDK。最小 manifest 见 [UI 指南](plugin-ui.zh.md#最小清单)，编辑器补全使用 [anywhere.d.ts](sdk/anywhere.d.ts)。

## 能力与 API 导航

| 能力 | 页面接口 | 声明与参考 |
| --- | --- | --- |
| 插件命令与本机 MCP | `commands.register/invoke/onChanged` | schema 5；见[本机 MCP 接入](mcp.zh.md) |
| 启动参数、再次激活 | `onEnter`、`getInvocation` | [UI SDK](plugin-ui.zh.md#页面-sdkapi-1)，无需额外能力 |
| 普通配置、插件数据 | `config.get`、`storage.get/set/remove` | [数据与权限](plugin-ui.zh.md#数据权限和生命周期)，无需额外能力；配置不返回密码 |
| 剪贴板 | `clipboard.writeText` | action 声明 `clipboard.write` |
| 脚本或 Go/Rust 后端 | `tasks.run` | action 声明 `task.run` 和 `script`；见[后端任务](plugin-ui.zh.md#后端任务) |
| 大文本文件与草稿 | `documents.*` | action 声明 `documents`；见[宿主服务](plugin-services.zh.md) |
| 动态搜索条目 | `launcher.setEntries/open` | action 声明 `launcher.entries`；见[宿主服务](plugin-services.zh.md) |
| 通知与操作按钮 | `notifications.status/replace` | action 声明 `notifications`，启用搜索入口；见[通知指南](plugin-notifications.zh.md) |
| 工作流输入和结果 | `workflow.context/complete` | [当前同包步骤](plugin-ui.zh.md#同包工作流脚本与交互工具)，无需额外能力 |

`capabilities` 声明在 manifest 的对应 action 上。宿主根据真实页面和安装来源校验调用；不要把包内脚本拥有的系统访问权限等同于页面 SDK 权限。页面不能直接联网，需通过已审阅的后端任务完成相关操作。

### 通知的职责划分

**AnyWhere 提供通知能力，插件决定如何使用通知。** 宿主提供 `system` 系统通知和 `panel` 提醒浮窗，负责调度、权限、展示、取消和按钮事件路由。插件提供提醒方式选择界面、标题和按钮，并保存业务状态。

例如 Todo 定义“推迟”和“确认完成”：点击推迟后，Todo 选择 5 分钟或 1 小时并保存新时间；点击完成后，Todo 保存 `done = true`。两者都由插件调用 `replace` 同步**当前 action 的全部剩余提醒**。宿主不理解待办状态，也不决定推迟多久。

完整示例、秒与毫秒转换、全量替换、事件去重、失败处理和测试步骤集中在[通知指南](plugin-notifications.zh.md)。系统通知样式由 macOS 控制；浮窗需要 AnyWhere 运行，插件页面可以关闭。

## 可导入示例

| 示例 | 适合学习 |
| --- | --- |
| [基础扩展包](../examples/example-pack/README.zh.md) | 脚本、文件匹配、子菜单 |
| [文本工具](../examples/ui-tool-pack/README.zh.md) | UI、启动上下文、存储、剪贴板、可取消任务 |
| [独立窗口](../examples/detached-panel-demo/README.zh.md) | 独立窗口与页面状态 |
| [剪贴板 JSON 工作流](../examples/tool-panel-demo/README.zh.md) | 同包脚本组合 |
| [接口响应 → TypeScript](../examples/tool-chain-demo/README.zh.md) | 同包交互式工具串联 |
| [Xlog Decoder](../examples/xlog-decoder-pack/README.zh.md) | 包内 CLI、后缀匹配、密码配置 |

Todo 位于独立的 `anywhere-todo` 仓库；主工程的 [OfficialPluginTests.swift](../AppTests/OfficialPluginTests.swift) 加载它的真实页面进行集成测试。通知指南包含目录要求和选定测试命令。

## 主工程开发与测试

构建环境、签名配置、国际化和提交方法见[贡献指南](../CONTRIBUTING.zh.md)。从源码运行的基本命令：

```sh
make gen           # 安装所需的 xcodegen，生成本地工程及配置
make test          # Core 单元测试
make test-presets  # 预设脚本测试
make run           # 构建 Debug 并启动 AnyWhere
```

| 修改区域 | 源码入口 |
| --- | --- |
| manifest、能力、数据和校验 | [AnyWhereCore](../Core/Sources/AnyWhereCore/) |
| 导入、安装和更新审阅 | [PackManager.swift](../App/Managers/PackManager.swift) |
| WebView 与注入 SDK | [PluginSession.swift](../App/Plugins/PluginSession.swift) |
| 通知调度与按钮路由 | [PluginServices.swift](../App/Plugins/PluginServices.swift)、[PluginReminderPanel.swift](../App/Plugins/PluginReminderPanel.swift) |
| 搜索、窗口和工作流 | [App/Plugins](../App/Plugins/) |
| 搜索首页摘要 | [PluginSummaryHost.swift](../App/Plugins/PluginSummaryHost.swift) |
| Finder 菜单扩展 | [FinderExtension](../FinderExtension/) |
| 宿主集成测试 | [AppTests](../AppTests/) |

当前 [CI](../.github/workflows/ci.yml) 运行 Core 测试、预设脚本测试，以及 App/FinderExtension 编译检查，不执行宿主 WebView 测试。`make test` 也不包含 `AppTests`。宿主测试需要先 `make gen`，再按[贡献指南](../CONTRIBUTING.zh.md#测试)运行 Xcode 测试；正式插件测试还需要相应插件源码。构建通过不能替代 Finder 菜单、窗口或通知中心按钮的交互验收。

## 常见开发问题

| 现象 | 先检查 |
| --- | --- |
| 导入后搜索不到 | 对应 action 的搜索开关是否启用；Finder 开关独立 |
| 改了页面却不生效 | 是否先重新加载本地包，再重开页面 |
| 重开后输入丢失 | 是否已用宿主存储保存；不要依赖 WebView 的 localStorage |
| API 不存在或返回 `denied` | 宿主构建是否支持、action 是否声明能力、会话是否有效 |
| 待办保存成功却不提醒 | `replace` 的 `errors` 和系统授权；浮窗还需宿主运行，详见[通知指南](plugin-notifications.zh.md) |

## 方案与实施记录

以下文档用于理解设计背景，不作为已发布 API 的依据：

- [跨扩展包工作流设计](cross-pack-workflows.zh.md)：规划，尚未实现；当前只能组合同包动作。
- [三个正式插件实施记录](three-plugins-plan.zh.md)：实施过程记录，调用契约以各开发指南为准。
- [插件市场调研](research/siyuan-plugin-marketplace.zh.md)：调研参考。

文档维护时同时更新相关指南和 [SDK 类型声明](sdk/anywhere.d.ts)，在本目录添加入口。开发指南描述当前行为；计划、实验和测试记录须标明状态，避免被当成已发布能力。
