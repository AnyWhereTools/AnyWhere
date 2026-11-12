# AnyWhere

**集快捷启动、插件工具和 Finder 右键管理于一体的 macOS 应用，支持本机 MCP 调用。**

[English](README.md) · 简体中文

[插件集市](https://github.com/AnyWhereTools/anywhere-bazaar) · [开发者文档](docs/README.zh.md) · [本机 MCP](docs/mcp.zh.md) · [版本发布](https://github.com/AnyWhereTools/AnyWhere/releases)

AnyWhere 把应用、脚本和插件工具放进同一个键盘操作入口。按 `Control+Option+Space` 搜索并打开工具，管理 Finder 右键动作，也可以让 MCP 客户端调用你明确授权的插件命令。插件可提供独立界面、本地数据、提醒和搜索首页摘要，无需另做一个原生 App。

项目采用 **MIT** 协议，基于 **SwiftUI + Finder Sync + WebKit**，最低支持 **macOS 13 Ventura**，界面支持 **English / 简体中文**。主 App 非沙盒，Finder 扩展运行在沙盒中。
下文介绍当前源码能力；使用安装包时，请同时查看对应版本的发布说明。

---

## 能做什么

| 入口 | 能力 |
| --- | --- |
| 快捷启动 | 按名称、别名、全拼或首字母搜索应用、插件和本地快捷指令 |
| 插件工具 | HTML/CSS/JS 页面、独立窗口、本地存储和可取消的后端任务 |
| Finder 右键 | 可编辑的 zsh 动作、系统快速操作／服务显隐、第三方扩展开关 |
| 提醒与摘要 | 插件定义的系统通知或提醒浮窗，以及固定在搜索首页的摘要 |
| 自动化 | 同包工作流，以及通过内置 stdio MCP 服务调用已授权的插件命令 |

**脚本优先，按需扩展。** 内置 Finder 动作也是可编辑的 zsh 脚本。插件可从 Git 仓库或本地文件夹导入，审阅后再启用需要的入口。

## 快速开始

1. 按下方[安装／构建说明](#安装--从源码构建)启动 AnyWhere，完成首次引导；需要右键动作时启用 Finder 扩展。
2. 打开「扩展包」，浏览[插件集市](https://github.com/AnyWhereTools/anywhere-bazaar)，或导入 Git URL／本地文件夹，审阅文件后安装。
3. 在包详情中启用所需的「搜索」或「右键」入口；两者独立控制，导入后默认停用。
4. 按 `Control+Option+Space` 搜索工具并回车打开，再按需设置插件配置、固定摘要或开启 MCP 授权。

### 可以先试这些插件

| 插件 | 用途 |
| --- | --- |
| [Todo](https://github.com/AnyWhereTools/anywhere-todo) | 待办列表、截止日期与提醒 |
| [JSON Tools](https://github.com/AnyWhereTools/anywhere-json-tools) | JSON 编辑、格式化与草稿保存 |
| [Quicklinks](https://github.com/AnyWhereTools/anywhere-quicklinks) | 网站搜索与 URL 模板快捷入口 |
| [Tool Chain Demo](https://github.com/AnyWhereTools/anywhere-tool-chain-demo) | 接口响应 → 节点选择 → TypeScript 的交互工具链 |

---

## 功能

### 脚本优先、极致可配置的自定义动作

每个动作都是 zsh 脚本(或内联片段,或「用 App 打开」)。可自定义图标(SF Symbol + 配色,或导入自己的图片)，选择作用对象（文件、文件夹、目录空白处），并限制选中数量。

自建动作通过**普通文件后缀**限定文件类型，例如 `xlog, log, tar.gz`。多个后缀用逗号分隔，允许带前导点，**不区分大小写**；留空不限。此输入框不支持通配符或正则。

已有 UTI 规则继续保留；修改后缀或点击「改用后缀匹配」后替换旧规则，修改标题、图标等其他字段不会改变原有匹配行为。

### 管理「整个」右键菜单,不只是自己的项

一屏预览右键菜单，带「模拟对象」开关（图片/文件/文件夹/空白处）。分类预览近似判断文件类型，文件名正则需在 Finder 中用真实文件验证。按可控程度分区：**●** 自有与扩展包动作（排序、启停；扩展包脚本与匹配规则只读），**◐** 系统快速操作/服务（隐藏），**○** 第三方扩展（开关）。

### 切换终端/编辑器,无需改脚本

在「通用」里选默认终端和编辑器;「在终端/编辑器打开」预设通过注入的环境变量遵从你的选择,不用动脚本。

### 插件搜索与自定义界面

按 `Control+Option+Space` 唤起搜索，输入插件名称或别名，回车在同一窗口打开插件自带的 HTML/CSS/JS 界面。快捷键可在通用设置修改或停用，也可从菜单栏打开。扩展包详情中的「搜索」与「右键」开关独立控制，导入后均默认停用。

插件可保存独立数据、调用剪贴板，并通过可取消任务运行包内脚本或 Go/Rust 二进制，无需内置 Node。详见[自定义 UI 开发文档](docs/plugin-ui.zh.md)和[可导入的文本工具示例](examples/ui-tool-pack/README.zh.md)。UI 页面使用清单版本 4 或更高版本；版本 1–3 的原有包能力继续兼容。

搜索还支持全拼、拼音首字母、已启用的自建快捷指令、同包工作流和已安装应用。「快捷指令」可创建本地脚本，设置名称、关键词和独立全局快捷键，与 Finder 右键动作分开。

工具页面可在普通独立窗口打开，带原生窗口按钮及工具栏重载。独立打开／重载会新建会话，需要保留的草稿应写入宿主存储。关闭工具面板会结束会话；独立窗口在切换其他应用后仍保留。详见[窗口生命周期](docs/plugin-ui.zh.md)。

真实脚本组合见[剪贴板 JSON 工作流](examples/tool-panel-demo/README.zh.md)，交互 A → B → C 见[接口响应转 TypeScript](examples/tool-chain-demo/README.zh.md)。导入审阅后，在包详情中启用所需工具和工作流。目前工作流只能引用**同包工具**；跨开发者、跨扩展包组合的[设计与实施计划](docs/cross-pack-workflows.zh.md)明确标为尚未实现。

### 提醒与搜索首页摘要

插件可调度 macOS 系统通知或 AnyWhere 提醒浮窗，并提供「推迟」「确认完成」等按钮。插件负责保存业务数据和处理按钮，AnyWhere 负责调度与展示。浮窗需要 AnyWhere 保持运行，插件页面可以关闭。详见[通知与操作按钮](docs/plugin-notifications.zh.md)。

提供 `summary.html` 的插件可固定到搜索首页，读取自身已保存的数据展示摘要，点击后打开完整工具。详见[搜索首页摘要](docs/plugin-summaries.zh.md)。

### 本机 MCP 与插件命令

内置 `anywhere-mcp` 辅助程序通过 stdio 向 MCP 客户端提供已明确授权的插件命令。在插件设置中开启「允许通过 AnyWhere MCP 调用」，并将 `/Applications/AnyWhere.app/Contents/MacOS/anywhere-mcp` 注册为客户端的服务程序；安装位置不同时调整路径。**使用期间 AnyWhere 需保持运行。**

`list` 工具可查询已授权插件及其操作参数。插件通过清单版本 5 声明导出的命令，已安装的插件必须包含这些声明才能被调用。关闭授权后，后续调用会被阻止。本机 MCP 不提供远程服务，同一 macOS 用户下的其他进程也能调用已授权功能。完整接入方法与命令契约见[本机 MCP 文档](docs/mcp.zh.md)。

### 扩展包导入

扩展包是根目录包含 `manifest.json` 和配套脚本的文件夹。在「扩展包 → 导入」粘贴 Git URL / `owner/repo`，或点击「选择本地文件夹…」，**本地包无需创建 Git 仓库**。AnyWhere 克隆或复制整个包，展示脚本和附带文件（包括 CLI）供审阅，导入后的动作默认**禁用**，由你逐个启用。

本地导入保留可执行权限，安装的是独立副本；移动或修改原目录不影响已安装动作。本地包不检查 Git 更新，同一来源不可重复导入；可在开发模式下审阅并重新加载本地包，或卸载后重装。

### 插件配置：填写一次，后续自动使用

扩展包可声明**文本、密码、开关、下拉选择**配置项。在「右键菜单」选中包内动作，在右侧「插件配置」填写并点击「保存配置」，后续执行通过 `ANYWHERE_CONFIG_<KEY>` 自动传给脚本，无需每次输入。「清除配置」会删除已保存的值并恢复默认值。

应用数据保存在 `~/Library/Application Support/AnyWhere/`。密码使用 AES-256-GCM 本地加密，普通配置使用本地 JSON 文件；配置读写不访问钥匙串，也不要求输入系统密码。包更新时，动作 ID 和字段 key 不变即可保留配置。卸载默认保留配置，方便从同一来源重新导入；也可勾选同时删除配置、密码和插件数据。

**从钥匙串存储的旧版升级：**请重新填写密码字段并保存一次，应用不读取或删除旧钥匙串条目。备份时请保留整个 `PrivateData/` 目录，包括 `key` 和 `secrets.enc`；只有密文无法恢复。

### 插件匹配：UTI、后缀与文件名正则

包作者可声明 UTI 类型匹配（`utis`）、忽略大小写的普通后缀（`extensions`）和完整文件名正则（`filenamePattern`，默认忽略大小写）。每个选中项须**命中任一 UTI 或后缀**，并额外满足所声明的正则；两个类型列表均为空时不限类型。**多选须全部符合**，作用对象限制仍然生效。

插件配置使用清单 **schemaVersion 2 或更高版本**；后缀、正则使用 **3**。详见[扩展包规范](docs/pack-spec.zh.md)、[基础示例包](examples/example-pack/README.zh.md)和 [Xlog Decoder 包](examples/xlog-decoder-pack/README.zh.md)。

体验 Xlog 解密：本地导入 `examples/xlog-decoder-pack/`，启用「解密 Xlog」，在动作配置中保存私钥（未加密日志留空），再到 Finder 选中 `.xlog` / `.XLOG` 文件执行。日志输出在原文件旁。包内附带 Intel / Apple Silicon 独立 CLI，**无需安装 XlogDecoder.app**。

### 双语 & 不反复弹窗

完整 **English / 简体中文** 界面(String Catalog,加语言只需加一列翻译)。因为扩展零文件访问、无 App Group 容器,AnyWhere 规避了 macOS 14/15「想访问其他 App 数据」的反复弹窗;少量必需权限在引导里**一次性**请求。

---

## 内置预设(6 个可编辑脚本)

刻意精简——只留通用、填补 Finder 空缺、零外部假设、人人受益的动作。全部仅用 macOS 自带 CLI。在 **设置 › 右键菜单** 查看/编辑,**设置 › 通用** 恢复出厂。

| 脚本 | 动作 | 说明 |
|------|------|------|
| `copy-path.sh` | 复制路径 | `pbcopy`,多选每行一个路径 |
| `new-file.sh` | 新建文件 | 子菜单列举模板目录;`cp` + 自动重名编号 |
| `cut.sh` / `paste.sh` | 剪切 / 粘贴到此处 | 经数据目录 cutbuffer 移动 |
| `open-parent.sh` / `open-enclosing.sh` | 前往上一层级目录 | 在当前 Finder 窗口内上一层;浏览器上传框里发 `⌘↑` |

专用能力可通过**可选扩展包**添加。以下是上游参考项目，导入前需将脚本适配为
`ANYWHERE_*` 环境变量；当前 AnyWhere 的插件发现使用 [Bazaar 注册表](https://github.com/AnyWhereTools/anywhere-bazaar)：

- **[Developer Pack](https://github.com/Hibrielle/menumate-dev-pack)** —— 在终端/编辑器打开(遵从你的默认终端/编辑器)。
- **[Image Pack](https://github.com/Hibrielle/menumate-image-pack)** —— 图片转换 ▸ png/jpeg/heic/tiff。
- **[Navigation Pack](https://github.com/Hibrielle/menumate-nav-pack)** —— 前往路径… / 跳到剪贴板路径(Finder 地址栏)。

---

## 安装 / 从源码构建

环境：macOS 13+、Xcode 16.3+（MCP 辅助程序 SDK 需要 Swift 6.1）、Homebrew（安装 `xcodegen`）。

安装包发布后可从 [GitHub Releases](https://github.com/AnyWhereTools/AnyWhere/releases) 获取，安装前请查看对应版本的签名与公证说明。

```bash
make bootstrap   # 安装 xcodegen + 拷贝本地签名配置
make gen         # project.yml → AnyWhere.xcodeproj(已 gitignore)
make test        # 运行 Core 单元测试
make build       # 调试构建
make run         # 构建并启动
```

随后启用 Finder 扩展(引导会带你到系统设置,或 `pluginkit -e use -i com.anywhere.app.FinderExtension`),并完成一次性授权。签名、公证和发布操作见[发布流程](docs/RELEASING.zh.md)。

正式签名、公证需要 Developer ID 凭据；GitHub 发布流程也支持显式选择临时签名构建，该模式不含公证和自动更新。未公证的本地或临时签名构建首次启动可能被 Gatekeeper 阻止，可右键 App 选择「打开」并确认，或对可信构建执行 `xattr -dr com.apple.quarantine /path/to/AnyWhere.app`。

## 脚本环境契约

AnyWhere 使用独立的 `com.anywhere.app` 标识，配置保存在
`~/Library/Application Support/AnyWhere/`。上游应用的既有数据和权限保持原样，
不会自动迁移；导入脚本需使用下方的 `ANYWHERE_*` 环境变量。

每个脚本(预设或扩展包)以 `/bin/zsh` 执行,注入:

| 变量 / 参数 | 含义 |
|----------------|------|
| `$1 … $n` | 选中项的绝对路径(空白处动作传容器路径) |
| `ANYWHERE_PATHS` | 全部路径,换行分隔 |
| `ANYWHERE_VARIANT` | 选中的子菜单值(如 `jpeg`) |
| `ANYWHERE_TEMPLATES` / `ANYWHERE_DATA` | 模板目录 / 数据目录 |
| `ANYWHERE_TERMINAL` / `ANYWHERE_EDITOR` | 你选的默认终端 / 编辑器 bundle id |
| `ANYWHERE_SCRIPT` | 脚本自身绝对路径；`${0:A:h}` 是脚本目录，脚本位于 `actions/` 下时 `${0:A:h:h}` 是包根目录 |
| `ANYWHERE_CONFIG_<KEY>` | 当前包动作声明的配置项的已保存值或默认值；开关为 `"true"` / `"false"` |
| 退出码 `0` | 成功;stdout 首行作为摘要 |
| 退出码非 `0` | 失败;stderr 进「最近执行」+ 通知 |

详见[扩展包规范：脚本环境契约](docs/pack-spec.zh.md#script-environment-contract)。

## 架构

| Target | 形态 | 沙盒 | 职责 |
|--------|------|------|------|
| AnyWhere | SwiftUI 菜单栏 App(`LSUIElement`) | 否 | 搜索启动、插件界面、提醒、动作执行、系统菜单管理、扩展包 |
| FinderExtension | `FIFinderSync` 扩展 | 是 | 画菜单、转发点击 |
| AnyWhereMCP | 内置 `anywhere-mcp` 可执行程序 | 否 | 将 stdio MCP 调用转发给已授权的宿主命令 |
| AnyWhereCore | 本地 Swift Package | — | 模型、配置、规则匹配、命令校验与本机 IPC（单测覆盖） |

扩展**不读任何文件**:菜单数据由主 App 经 `DistributedNotificationCenter` 分块推送,无 App Group 容器——这是消除反复授权弹窗的关键。

## 文档与贡献

- [UI、窗口与工作流 SDK](docs/plugin-ui.zh.md) · [TypeScript 类型声明](docs/sdk/anywhere.d.ts)
- [通知与提醒按钮](docs/plugin-notifications.zh.md) · [宿主服务](docs/plugin-services.zh.md)
- [本机 MCP 与插件命令](docs/mcp.zh.md) · [搜索首页摘要](docs/plugin-summaries.zh.md)
- [脚本工作流 Demo](examples/tool-panel-demo/README.zh.md) · [交互工具链 Demo](examples/tool-chain-demo/README.zh.md)
- [跨包工作流开发设计与实施计划——尚未实现](docs/cross-pack-workflows.zh.md)
- [扩展包规范](docs/pack-spec.zh.md) · [基础示例包](examples/example-pack/README.zh.md) · [Xlog Decoder 包](examples/xlog-decoder-pack/README.zh.md)
- [贡献指南](CONTRIBUTING.zh.md) · [发布流程](docs/RELEASING.zh.md) · [安全说明](SECURITY.zh.md)
- Core 单元测试 + 预设脚本测试 + App/扩展编译检查在推送到 `main` 和提交 Pull Request 时由 CI 运行（`.github/workflows/ci.yml`）。

## 已知限制

- FinderSync 死区:`/Applications`、iCloud / File Provider 目录不触发扩展(系统行为)。
- 注入项固定在右键菜单底部(系统限制)。
- Shortcuts 型快速操作仅支持隐藏(状态在 TCC 保护库)。
- 预设标题随安装语言落盘,之后切系统语言不会自动重翻(恢复出厂可重新落盘)。

## 许可

[MIT](LICENSE) © 2026 Hibrielle
