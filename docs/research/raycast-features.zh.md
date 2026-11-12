# Raycast 功能调研

调研日期：2026-09-28。以官方当前 v2 手册、产品介绍和公开扩展代码为依据，以 macOS 使用场景为主。本机未安装 Raycast，本报告不代表运行、性能或交互验收。

## 1. 产品功能

Raycast 将应用、文件、命令和常用工具集中到一个键盘入口。理解它时，要同时看“找到什么”和“找到后能做什么”：Root Search 找对象，Action Panel 提供对象相关操作，插件和脚本继续扩充能力。[搜索说明](https://manual.raycast.com/search-bar)、[动作面板](https://manual.raycast.com/action-panel)。

| 功能 | 用户实际能做什么 | 官方依据 |
| --- | --- | --- |
| 应用与命令启动 | 模糊搜索应用、内置命令、扩展命令；收藏、别名、独立快捷键；结合使用频率和最近使用情况排序 | [Search Bar](https://manual.raycast.com/search-bar) |
| 上下文动作面板 | 回车执行主动作，`⌘K` 查找更多操作；可以搜索动作、进入子菜单、直接设置命令快捷键和别名 | [Action Panel](https://manual.raycast.com/action-panel) |
| 文件搜索与操作 | 文件和目录进入主搜索；可在专用视图看详情、预览、打开目录到终端、复制文件、存为 Quicklink、送入 AI；可选文件内容搜索 | [File Search](https://manual.raycast.com/file-search) |
| Quicklinks | 给网页、文件、项目目录建立命名入口；指定打开应用；支持带参数的网址搜索、选中文本作为搜索输入 | [Quicklinks](https://www.raycast.com/core-features/quicklinks) |
| 剪贴板历史 | 搜索文本、图片、文件、链接和颜色；按类型筛选、固定、编辑、按原格式或纯文本粘贴；OCR、二维码提取、顺序粘贴 | [Clipboard History](https://manual.raycast.com/clipboard-history) |
| 文本片段 Snippets | 将常用回复、代码和模板保存为片段；输入关键词自动展开；支持标签、动态占位符、导入导出 | [Snippets](https://manual.raycast.com/snippets) |
| 计算器与转换 | 直接输入算式，进行单位、货币、时区和日期计算；复制或直接粘贴结果 | [Calculator](https://manual.raycast.com/calculator) |
| 窗口管理 | 半屏、三分屏、四分屏、居中、最大化、跨显示器移动和恢复位置；可绑定快捷键 | [Window Management](https://www.raycast.com/core-features/window-management) |
| 系统控制 | 搜索执行锁屏、睡眠、调音量、静音、切换外观、显示隐藏文件、退出应用等操作；部分命令因平台不同而异 | [System Commands](https://manual.raycast.com/system-commands) |
| 日历和会议 | 查看日程、创建事件、加入会议、展示菜单栏日程；macOS 通过系统日历账号接入 | [Calendar](https://manual.raycast.com/calendar) |
| 轻量笔记 | 快捷键随手记录；支持 Markdown、任务列表、按标题和内容搜索、固定常用笔记 | [Notes](https://manual.raycast.com/notes) |
| 专注模式 | 设置目标和时长，按列表屏蔽或只允许特定应用及网站；支持暂停、继续和可复用分类 | [Focus](https://manual.raycast.com/focus) |
| 截图检索 | 搜索已有截图和录屏，按名称、时间或 OCR 文字过滤；直接粘贴最新截图 | [Screenshots](https://manual.raycast.com/screenshots) |
| 第三方服务扩展 | 在 Raycast 中操作 Linear、Notion、Todoist、浏览器、Spotify 等服务；功能取决于具体扩展和账号授权 | [官方扩展示例](https://www.raycast.com/) |
| 脚本入口 | 把本地脚本包装成可搜索命令，接收参数并呈现运行结果 | [Script Commands 仓库](https://github.com/raycast/script-commands) |
| AI 与语音输入 | Quick AI、独立聊天、AI Commands、工具调用、屏幕上下文、Agents、Skills、个人化记忆，以及将语音整理成当前应用内的文字 | [v2 功能说明](https://manual.raycast.com/new-in-v2) |

### 容易漏掉的产品细节

- **搜索结果自带后续操作。** 收藏、快捷键、别名和配置入口靠近使用场景；用户不必先学会设置页结构。[动作面板](https://manual.raycast.com/action-panel)。
- **Quicklinks 是轻量参数化工具。** 一个网址模板就能提供站内搜索，还能接收当前选中文本。并非每个简单需求都要开发扩展。[Quicklinks](https://www.raycast.com/core-features/quicklinks)。
- **信息之间可以转用。** 剪贴板条目可保存为 Snippet，文件可保存为 Quicklink；二者也可成为 AI 上下文。[剪贴板](https://manual.raycast.com/clipboard-history)、[文件搜索](https://manual.raycast.com/file-search)。
- **主搜索和专用视图分工。** 主搜索负责快速找到对象；文件、笔记、截图等专用视图提供筛选、预览与管理。[文件搜索](https://manual.raycast.com/file-search)、[笔记](https://manual.raycast.com/notes)、[截图](https://manual.raycast.com/screenshots)。

## 2. AI 功能的实际边界

| 能力 | 可确认的行为 | 来源 |
| --- | --- | --- |
| Quick AI / AI Chat | 从启动器快速问答，或在聊天中持续工作；v2 支持聊天分支和项目组织 | [v2](https://manual.raycast.com/new-in-v2) |
| Agents | 保存角色指令、模型和允许使用的 AI Extensions，便于重复使用；官方说明这是 v1 Presets 的更名，不能仅凭名称推断为多智能体系统 | [Agents](https://manual.raycast.com/ai/agents) |
| MCP | 将外部工具接入 AI Chat、Quick AI、AI Commands；桌面支持本地 stdio 与 HTTP，HTTP 可走 OAuth | [MCP](https://manual.raycast.com/ai/model-context-protocol) |
| Automations | 按计划运行 AI 提示词，结果进入新聊天或已有聊天；可以调用扩展、MCP 和 Skills | [Automations](https://manual.raycast.com/ai/automations) |
| 屏幕上下文与个性化 | 可以携带当前窗口、选择内容和截图；Profile、Memory 为后续聊天提供个人上下文 | [v2](https://manual.raycast.com/new-in-v2) |
| Dictation | 将语音整理成文字并输入当前应用，支持按应用或网站调整风格 | [v2](https://manual.raycast.com/new-in-v2) |

自动化依赖本机唤醒且 Raycast 运行；需要工具批准时会等待用户。它不能被理解为关闭电脑后仍持续运行的云任务。错过多次调度会合并补跑一次。[调度规则](https://manual.raycast.com/ai/automations)。

## 3. 免费与付费

当前价格页将内置基础功能、公开扩展、自定义扩展和开发工具列入免费范围。免费剪贴板保留期最长 3 个月，Notes 为 5 条；Pro 提供更长或无限保留、无限笔记、云同步、自定义主题、自定义窗口命令、翻译、语音输入和 AI。AI 存在套餐额度与模型差异，不应笼统描述成无限使用。此处只记录功能分层，不作购买建议。[当前套餐对照](https://www.raycast.com/pricing)。

Cloud Sync 当前手册标为 Beta，可同步 Quicklinks、Snippets、Notes、聊天等；**剪贴板历史、脚本文件本身、凭据和密码不在同步范围**，扩展在目标设备仍需启用。[同步范围](https://manual.raycast.com/cloud-sync)。

## 4. 公开代码证据

公开扩展与脚本用于验证具体功能实现；内置宿主功能以官方手册为依据。不能将扩展仓库视为整个 Raycast 主应用源码，也不能从扩展代码验证主应用的性能和全部权限实现。

本次源码固定为：`raycast/extensions` 的 `763301ae07cad6dcfed033e213fea1ccdd91fdfd`，以及 `raycast/script-commands` 的 `cf612c22a8ddea40f6d717f513bbb5619a73ad33`。官方扩展仓库定位为 Store 扩展、文档和示例；本次核查不是 Raycast 主应用源码审计。[仓库说明](https://github.com/raycast/extensions)、[官方公开仓库](https://github.com/orgs/raycast/repositories)。

| 实际代码 | 可确认的功能链 | 固定源码 |
| --- | --- | --- |
| GitHub 仓库搜索 | 调用 GitHub 查询，处理分页和筛选，呈现搜索列表；动作面板能克隆、下载 ZIP、收藏，并在 Raycast 内查看 README、Issues、PR 和 Releases | [查询与列表](https://github.com/raycast/extensions/blob/763301ae07cad6dcfed033e213fea1ccdd91fdfd/extensions/github/src/search-repositories.tsx#L36-L106)、[动作](https://github.com/raycast/extensions/blob/763301ae07cad6dcfed033e213fea1ccdd91fdfd/extensions/github/src/components/RepositoryActions.tsx#L127-L207) |
| Linear 创建事项 | 表单收集标题、描述、状态、优先级、负责人等；提交 payload，调用 GraphQL `issueCreate`，给出成功反馈 | [表单字段](https://github.com/raycast/extensions/blob/763301ae07cad6dcfed033e213fea1ccdd91fdfd/extensions/linear/src/components/CreateIssueForm.tsx#L503-L561)、[提交](https://github.com/raycast/extensions/blob/763301ae07cad6dcfed033e213fea1ccdd91fdfd/extensions/linear/src/components/CreateIssueForm.tsx#L119-L165)、[实际请求](https://github.com/raycast/extensions/blob/763301ae07cad6dcfed033e213fea1ccdd91fdfd/extensions/linear/src/api/createIssue.ts#L65-L81) |
| Linear AI tool | `create-issue` 提供结构化参数，通过 `withAccessToken(linear)` 调用同一个 `createIssue`，并提供确认信息；AI 能调用真实业务函数 | [工具实现](https://github.com/raycast/extensions/blob/763301ae07cad6dcfed033e213fea1ccdd91fdfd/extensions/linear/src/tools/create-issue.ts#L8-L79)、[AI Extensions 契约](https://developers.raycast.com/ai/learn-core-concepts-of-ai-extensions) |
| 防休眠脚本 | 声明标题、图标、可选时间参数和 silent 模式，然后调用 macOS `caffeinate`；一个简单脚本即可成为启动器命令 | [脚本全文](https://github.com/raycast/script-commands/blob/cf612c22a8ddea40f6d717f513bbb5619a73ad33/commands/system/caffeinate-enable.sh#L1-L53) |

这些样例证明公开实现中存在“查询 → 结果 → 动作”和“输入 → 授权业务调用 → 反馈”的完整路径；尚不能证明当前账户授权成功、任意自然语言请求都能正确执行，或所有扩展都具备相同能力。防休眠脚本还会停止已有 `caffeinate` 进程，本次仅阅读，未执行。

版本方面也应避免套用旧架构介绍：2026-05-14 官方技术文章描述 v2 使用 macOS/Windows 原生宿主、共享 React/TypeScript UI、Node 后端及 Rust 核心。这是官方实现说明，不能当作已独立审计主应用源码。[v2 技术文章](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast)。

## 5. 与 AnyWhere 当前实现对比

追加核查日期：2026-09-28。AnyWhere 基线为本地 `HEAD f08f8f9` 加当前未提交修改，并检查同级 `anywhere-quicklinks`、`anywhere-json-tools`、`anywhere-todo` 和 `anywhere-bazaar`。下文“已实现”指可沿源码找到执行链，不表示这些改动全部发布、已装入本机应用或经过本轮运行验收。

### 已覆盖及部分覆盖

| 维度 | Raycast | AnyWhere 当前实现 | 判断与本地证据 |
| --- | --- | --- | --- |
| 应用与命令启动 | 应用、命令、文件等统一搜索 | 已搜索应用、插件、本地快捷指令、网页条目、同包工作流 | 核心启动能力已有；[结果与执行分发](../../App/Plugins/PluginLauncher.swift)、[目录生成](../../App/Managers/PackManager.swift) |
| 搜索匹配与排序 | 模糊匹配、别名、收藏、频率与最近使用排序 | 名称、关键词、描述匹配；全拼和首字母；最近使用；当前没有使用频次模型 | 部分具备。插件结果当前排在应用前，最近使用不等于 frecency；[匹配](../../Core/Sources/AnyWhereCore/PluginSearch.swift)、[拼音](../../Core/Sources/AnyWhereCore/SearchText.swift)、[目录排序](../../App/Plugins/LauncherCatalog.swift)、[最近记录](../../Core/Sources/AnyWhereCore/PluginPreferencesStore.swift) |
| 快捷键和参数 | 命令别名、独立快捷键、参数输入 | 插件与自建快捷指令有关键词、全局快捷键；关键词后文本传入 `invocation.argument` | 已有基础；没有证明所有搜索对象均可独立绑键，或具备 Raycast 同等多字段参数栏；[注册与执行](../../App/Plugins/PluginLauncher.swift)、[设置](../../App/UI/ShortcutsScreen.swift) |
| Quicklinks | 网页、文件、目录、指定打开应用、动态参数 | 网页快开已有名称、别名、分组、收藏、导入导出、主搜索索引和 `{query}` 模板 | 核心网页场景已覆盖；目前仅 HTTP(S)、默认浏览器，未接文件目录与选中文本自动输入；[插件实现](../../../anywhere-quicklinks/app.js)、[URL 校验](../../../anywhere-quicklinks/logic.js)、[宿主目的地址](../../Core/Sources/AnyWhereCore/PluginServices.swift) |
| 脚本命令 | 本地 Script Commands | 自建脚本、包内脚本、可取消任务、输入输出和错误反馈；脚本可调用随包 CLI | 已覆盖核心方向；[快捷指令执行](../../App/Plugins/PluginLauncher.swift)、[任务运行](../../Core/Sources/AnyWhereCore/PluginTask.swift) |
| 插件界面 | React/TypeScript 的 List、Grid、Detail、Form、ActionPanel 等组件 API | WKWebView 承载自由 HTML/CSS/JS，可制作完整编辑器和复杂工具页 | 能力形态不同。我们自由度高，也需要插件自行处理布局与交互一致性；页面禁止直连网络，不能等同无限制网页；[宿主与 CSP](../../App/Plugins/PluginSession.swift) |
| 独立工具窗口与状态 | 部分独立功能窗口；可设置返回主搜索的延迟，表单支持草稿 | 工具可独立打开、调整大小；失焦不会关独立窗口；启动器内插件失焦隐藏，默认 180 秒后退出 | 不能把“保留状态”视为我方独有；[独立窗口](../../App/Plugins/ToolWorkspaceController.swift)、[失焦逻辑](../../App/Plugins/PluginLauncher.swift) |
| 首页摘要 | Root Search 有收藏、最近文件和日历事件等信息 | 支持包内 `summary.html` 固定到首页，读取插件数据；Todo 展示未完成项 | 已有插件摘要机制，但不是任意命令通用收藏；[摘要宿主](../../App/Plugins/PluginSummaryHost.swift)、[固定入口](../../App/Managers/PackManager.swift) |
| Todo 与提醒 | Apple Reminders、Todoist 等扩展接入已有任务系统 | 本地 Todo：清单、截止日期、优先级、单次/每日/每周提醒；悬浮卡片内推迟、完成，首页摘要 | 已有独立本地待办；当前 Todo 固定使用悬浮提醒，宿主仍向其他插件提供系统通知；[业务与提醒映射](../../../anywhere-todo/logic.js)、[界面与保存](../../../anywhere-todo/app.js)、[宿主调度](../../App/Plugins/PluginServices.swift) |
| JSON 工具 | 生态提供 JSON 处理扩展，如格式化粘贴 | 正式 JSON 插件已有 CodeMirror 编辑、格式化/压缩、节点树、文件打开/另存、持久草稿 | 我们已有完整工具，不能列为缺失；也未横评全部 Raycast JSON 插件；[编辑器实现](../../../anywhere-json-tools/src/app.js)、[插件说明及大文件边界](../../../anywhere-json-tools/README.zh.md) |
| 工作流组合 | API 可启动同/跨扩展命令，AI 可调用工具；未据此确认通用确定性编排引擎 | 已支持同包有序步骤、JSON 输入输出、脚本和真实 UI 步骤混合；失败停止；跨包仍是规划 | 有可用基础，但不能标记跨插件工作流已完成；[调度](../../App/Plugins/PluginLauncher.swift)、[同包约束](../../Core/Sources/AnyWhereCore/Workflow.swift)、[跨包规划](../cross-pack-workflows.zh.md) |
| 插件发现和更新 | 大规模公开扩展 Store | 已有 Bazaar 拉取、筛选、导入审阅、固定 revision 和更新检查 | 不是“没有商店”；主要差距是生态覆盖。本地目录快照有 JSON、网页快开、Todo、工具链示例 4 项，不代表在线数量；[发现](../../App/Managers/PackDiscovery.swift)、[界面](../../App/UI/DiscoverPacksSheet.swift)、[更新](../../App/Managers/PackManager.swift)、[目录快照](../../../anywhere-bazaar/catalog.json) |

Raycast 对照来源：[搜索](https://manual.raycast.com/search-bar)、[Quicklinks](https://www.raycast.com/core-features/quicklinks)、[脚本](https://github.com/raycast/script-commands)、[UI API](https://developers.raycast.com/api-reference/user-interface)、[扩展 API FAQ](https://developers.raycast.com/misc/faq)、[设置](https://manual.raycast.com/settings)、[表单草稿](https://developers.raycast.com/api-reference/user-interface/form)、[Apple Reminders](https://www.raycast.com/raycast/apple-reminders)、[JSON 格式化粘贴示例](https://www.raycast.com/koinzhang/paste-as-plain-text)、[跨命令启动 API](https://developers.raycast.com/api-reference/command)、[扩展 Store](https://www.raycast.com/store)。

### AnyWhere 当前缺少或只有零散基础的部分

| 维度 | 当前差距 | 判断依据 |
| --- | --- | --- |
| 全局文件检索 | 没有 Raycast 式文件索引和搜索结果；插件打开文件和 Finder 上下文不等于文件搜索 | 主搜索结果类型只有插件目录和应用；[结果类型](../../App/Plugins/PluginLauncher.swift)、[应用发现范围](../../Core/Sources/AnyWhereCore/ApplicationSearch.swift)；Raycast 见 [File Search](https://manual.raycast.com/file-search) |
| 统一动作面板 | 没有 `⌘K` 式可搜索、多动作面板；当前结果行主要执行单个入口，特定插件可右键固定摘要 | [resultRow](../../App/Plugins/PluginLauncher.swift)；Raycast 见 [Action Panel](https://manual.raycast.com/action-panel) |
| 剪贴板历史、OCR | 有剪贴板写入 API，也有脚本读取当前剪贴板的示例；未发现持续历史采集、历史搜索、OCR 功能 | [桥接](../../App/Plugins/PluginSession.swift)、[现有示例](../../examples/tool-panel-demo/README.zh.md)；Raycast 见 [Clipboard History](https://manual.raycast.com/clipboard-history) |
| Snippets、计算器、窗口管理 | 当前生产入口和目录未见相应完整工具；能编写脚本实现某动作不等于已提供现成功能 | 核查 App、Core/Sources、示例清单与本地 Bazaar；Raycast 见 [Snippets](https://manual.raycast.com/snippets)、[Calculator](https://manual.raycast.com/calculator)、[窗口管理](https://www.raycast.com/core-features/window-management) |
| 正式笔记、日历、专注与截图搜索 | 仓库有临时便笺 Demo，但关闭后清空，不等于多篇持久笔记；未发现正式日历整合、专注屏蔽或截图检索 | [便笺 Demo](../../examples/tool-panel-demo/notes.html)；Raycast 见 [Notes](https://manual.raycast.com/notes)、[Calendar](https://manual.raycast.com/calendar)、[Focus](https://manual.raycast.com/focus)、[Screenshots](https://manual.raycast.com/screenshots) |
| AI / MCP / 语音 | 未发现统一 AI Chat、工具调用、MCP 客户端或语音输入；源码里允许 AI/CLI 修改配置的注释不构成内置 AI 功能 | 核查 App、Core/Sources 和公开 SDK；Raycast 见 [v2](https://manual.raycast.com/new-in-v2)、[MCP](https://manual.raycast.com/ai/model-context-protocol) |
| 云同步与团队共享 | 当前插件数据保存在本机；网页快开导入导出是手动搬运，没有账号云同步与团队私有商店 | [存储](../../Core/Sources/AnyWhereCore/PluginDataStore.swift)、[网页备份](../../../anywhere-quicklinks/app.js)；Raycast 见 [Cloud Sync](https://manual.raycast.com/cloud-sync)、[套餐](https://www.raycast.com/pricing) |

“未发现”只针对本次检查的主工程、三个正式插件和示例，不推断用户是否装有其他未纳入检查的私有扩展。

### 我们明确不同的方向

- **Finder 右键工作流**：按文件/文件夹/空白处、扩展名、UTI、正则和选中数量决定动作；还管理系统服务和第三方 Finder 扩展开关。Raycast 本次官方核查未发现相同的核心菜单管理界面，不能扩大为它无法通过脚本或扩展实现。[Finder 入口](../../FinderExtension/FinderSync.swift)、[匹配规则](../../Core/Sources/AnyWhereCore/RuleMatcher.swift)、[系统服务](../../App/Managers/ServicesManager.swift)、[扩展开关](../../App/Managers/ExtensionManager.swift)。
- **自由工具页面**：我们的 HTML/CSS 适合 JSON 编辑器、复杂表单和多区域工具；Raycast 的公开组件接口更强调统一结构。两者各有取舍，不能据此判断性能或安全谁更好。
- **本地工具组合**：已有确定性同包链路和交互步骤，可以继续围绕文件处理、开发工具、个人任务组织打磨；这属于产品方向判断，不构成新增功能承诺。

建议顺序：先完善现有搜索结果的动作入口与排序一致性，再按明确需求扩展网页快开的路径/应用能力或文件检索。AI、云同步、完整剪贴板和窗口管理需独立取舍，不因竞品具备就全部进入开发范围。

## 6. 验证范围

- 已查：官方功能页面、v2 手册、套餐与同步边界；公开代码样例；AnyWhere 当前搜索、执行、插件服务、同包工作流、Finder 管理及三个正式插件源码。
- 未做：安装 Raycast、运行扩展、账号授权、中文输入体验、响应速度、内存占用、系统权限和 macOS/Windows 功能一致性测试。
- 本次仅新增并补充调研文档；未修改 AnyWhere 生产实现，未提交或推送。文档通过空白检查；没有为只读对比触发编译、安装或回归测试。
