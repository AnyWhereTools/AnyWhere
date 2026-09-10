# AnyWhere 扩展包规范

[English](pack-spec.md) · 简体中文 · [返回首页](../README.zh.md)

**扩展包**是根目录包含 `manifest.json` 及其声明脚本的文件夹。可以从 Git 仓库导入，也可以直接选择本地文件夹，无需 Git。AnyWhere 安装只读副本，展示脚本和附带文件供用户审阅，导入的动作默认**禁用**，由用户逐个启用。

[基础示例包](../examples/example-pack/README.zh.md) 展示 UTI 过滤和子菜单；[Xlog Decoder 包](../examples/xlog-decoder-pack/README.zh.md) 展示本地导入、独立 CLI、后缀匹配和密码配置。

## 目录结构与导入来源

```text
your-pack/
├── manifest.json          # 必须位于包根目录
├── actions/               # 脚本目录，可自行组织，通过清单引用
│   ├── foo.zsh
│   └── bar.zsh
└── bin/                   # 可选的独立 CLI，需保留可执行权限
```

支持以下来源：

- 本地文件夹：在「扩展包 → 导入 → 选择本地文件夹…」中选择包含 `manifest.json` 的目录，不要求它是 Git 仓库。
- `owner/repo`：展开为 `https://github.com/owner/repo.git`。
- 完整的 `https://…` 或 `git@…` Git 地址。

## `manifest.json`

以下示例使用 JSONC 展示注释，实际 `manifest.json` 必须是**不含注释的 JSON**。

```jsonc
{
  "schemaVersion": 3,              // 可选，默认 1；后缀和正则要求版本 3
  "name": "Dev Tools",            // 必填，非空，扩展包显示名称
  "author": "Li Hua",             // 可选，仅用于展示
  "description": "Handy actions", // 可选，扩展包简介
  "icon": "hammer",               // 可选，SF Symbol 名，默认 shippingbox
  "actions": [                     // 必填，至少包含一个动作
    {
      "id": "copy-basename",      // 必填，包内唯一且稳定的动作标识
      "title": "Copy file name",  // 必填，右键菜单标题
      "icon": "doc.on.doc",       // 可选，默认 bolt
      "script": "actions/copy-basename.zsh", // 必填，包内相对路径
      "targets": "files",         // 可选：files / folders / any / container / foldersAndContainer，默认 any
      "utis": ["public.image"],    // 可选，默认 []，按 UTI 类型包含关系匹配
      "extensions": ["xlog"],     // 可选，普通后缀，忽略大小写；与 UTI 为「或」
      "filenamePattern": "device-.*\\.(png|xlog)", // 可选，完整文件名正则，作为额外限制
      "placement": "topLevel",    // 可选：topLevel / submenu，默认 topLevel
      "variants": { "fixed": ["png", "jpeg"] }, // 可选，子菜单项
      "timeoutSeconds": 60        // 可选，默认 60 秒
    }
  ]
}
```

未知字段会被忽略，未填写的可选字段使用默认值。请正确声明版本，避免旧客户端忽略它不认识的新字段。

### `schemaVersion`：功能版本

| 版本 | 支持的功能 |
|------|------------|
| `1` | 基础动作、`targets`、`utis`、菜单位置、子菜单和超时 |
| `2` | 版本 1 的全部功能，加上 `settings` 插件配置 |
| `3` | 版本 2 的全部功能，加上 `extensions` 后缀和 `filenamePattern` 正则 |
| `4` | 版本 3 的全部功能，加上自定义 UI、搜索入口、独立入口开关及页面能力 |

当前版本为 **4**，省略时默认为 **1**。仅配置项需要至少 2，后缀或正则至少 3，自定义 UI 或搜索入口需要 4。已有版本 1–3 的扩展包继续兼容；客户端会拒绝高于自身支持版本的包。

### 自定义 UI 与搜索入口（版本 4）

| 字段 | 说明 |
|---|---|
| 包级 `uiApiVersion` | 存在 UI 时必填，当前为 `1` |
| 动作 `ui` | `{ "entry": "ui/index.html", "height": 420 }`；包内 HTML，高度可省略 |
| 动作 `launcher` | `{ "keywords": ["text"] }`；声明搜索入口，关键词可为空 |
| 动作 `contextMenu` | 默认 `true`；`false` 不出现在 Finder 右键中 |
| 动作 `capabilities` | 页面能力数组，支持 `clipboard.write`、`task.run`；新版[宿主服务](plugin-services.zh.md)增加 `documents`、`launcher.entries`、`notifications` |
| 动作 `script` | 有 UI 时可省略；`task.run` 必须同时声明脚本 |

搜索与右键入口分别启停，导入后都禁用。UI 与脚本同时存在时只加载页面，不隐式执行脚本。页面通过 `window.anywhere` 获取上下文、普通配置、插件独立存储、剪贴板和可取消任务。密码继续由原生配置表单保存及注入后端。

完整清单、SDK、后端协议、配额、更新和卸载语义见[中文 UI 开发文档](plugin-ui.zh.md)及[文本工具示例](../examples/ui-tool-pack/README.zh.md)。旧的纯脚本动作继续使用原有执行方式。

<a id="same-pack-workflows"></a>

### 同包工作流（当前实现）

在 `actions` 同级可添加 `workflows` 数组。示例使用 schema 4，存在页面时使用 API 1，并需安装包含工作流支持的 AnyWhere；仅凭 schema/API 数字无法区分尚不支持此功能的旧 schema-4 构建。

```json
{"workflows":[{"id":"response-types","title":"接口响应 → TypeScript","steps":[
  {"action":"extract"},{"action":"select"},{"action":"types"}
]}]}
```

这是清单片段，需在本包 `actions` 中声明 `extract`、`select`、`types`。工作流 `id` 必须非空且在工作流之间唯一，`steps` 非空，每个 `action` 必须在同一清单内存在。目前没有包 ID 引用、依赖声明、公开入口契约或纯工作流包：`actions` 仍必须非空。Finder／工具／工作流分类由入口自动推导，不需要新增 `type` 字段。

包详情提供独立的工作流开关与「运行」按钮，导入后默认停用。启用后可按名称搜索，即使组成步骤的独立搜索入口未开启也能执行。脚本自动运行，纯 UI 动作等待 `anywhere.workflow.complete`，同时有 UI 和脚本的动作在流程中执行脚本。首步接收启动参数字符串，随后每步接收前一步 JSON 输出，首次失败即停止。桥接、生命周期和限制见[UI 开发文档](plugin-ui.zh.md)，可导入例子见[脚本工作流](../examples/tool-panel-demo/README.zh.md)和[交互工具链](../examples/tool-chain-demo/README.zh.md)。

更新时新增／变更的工作流，或步骤能力扩大的工作流，会被停用以供重新审阅；定义保持不变时保留启用状态。跨开发者、跨扩展包组合**尚未实现**；[开发设计与实施计划](cross-pack-workflows.zh.md)中的未来字段不能用于当前客户端。

### `id`：保持稳定

AnyWhere 按动作 `id` 识别更新前后的同一个动作，并保留启用状态。修改 `id` 会被视为删除旧动作并新增一个默认禁用的动作。建议使用稳定的英文小写短横线名称，例如 `decode-xlog`。

### `script`：包内相对路径

路径必须非空，不得以 `/` 开头，任何路径段都不能是 `..`。脚本必须实际存在于包内该位置，不能通过相对路径跳出包目录。

### `targets`：作用对象

| 值 | 显示条件 |
|----|----------|
| `files` | 选中一个或多个文件，不包含文件夹 |
| `folders` | 选中一个或多个文件夹 |
| `any` | 选中文件、文件夹或两者混合 |
| `container` | 在目录空白处右键，没有选中项 |
| `foldersAndContainer` | 选中一个或多个文件夹，或在目录空白处右键；不包含文件 |

同一动作需要同时出现在文件夹和空白处时，使用 `foldersAndContainer`。选中数量、UTI 和名称筛选仅作用于选中的文件夹；空白处不应用这些筛选，脚本收到当前目录路径。

### `utis`：系统文件类型

UTI 是 macOS 的统一类型标识。这里采用 `UTType` 的类型包含关系匹配，而不是比较字符串是否相等。例如 `public.image` 可以匹配多种图片格式。

常见值包括 `public.image`、`public.movie`、`public.audio`、`com.adobe.pdf`、`public.text`、`public.source-code` 和 `public.archive`。UTI 查询结果可能受本机注册的文件类型影响；只按 `.xlog` 等后缀过滤时，使用 `extensions` 更直接。

### `extensions` 与 `filenamePattern`：后缀和正则

这两个字段要求 **schemaVersion 3**。

- `extensions` 是**普通文件后缀数组**，例如 `["xlog", "tar.gz"]`。忽略大小写，允许前导点，`".XLOG"` 与 `"xlog"` 等价。`tar.gz` 可匹配 `backup.TAR.GZ`；`xlog` 不匹配 `a.xlog.bak` 或没有文件名主体的 `.xlog`。后缀只匹配文件，不匹配文件夹。允许字母、数字、点、`_`、`-`、`+`；不允许通配符、路径、正则语法、空后缀或连续的空分段。
- `filenamePattern` 是 ICU 正则表达式，匹配**完整文件名（包含后缀）**，不包含父目录路径。默认忽略大小写，可用 ICU 内联标志覆盖。例如 `"device-.*\\.xlog"` 匹配 `DEVICE-001.XLOG`。JSON 中的反斜杠必须转义。导入时会拒绝空表达式和非法正则；手工修改运行配置造成非法规则时，动作不会在选中项菜单中显示。
- `targets` 和选中数量限制仍然有效。只要 `utis` 或 `extensions` 中有一个非空，每个选中项就必须**命中至少一个 UTI 或后缀**；两个列表均为空则不限类型。设置了正则时，还必须**额外满足正则**。多选时**所有选中项都须符合**。
- `container` 没有选中文件名，不能声明后缀或文件名正则。

仅允许 `.xlog` 文件的动作字段如下：

```json
{
  "targets": "files",
  "extensions": ["xlog"]
}
```

这是动作字段片段，应放入 `actions` 数组中的某个对象，与 `id`、`title`、`script` 一起使用。

自建动作的编辑界面只提供普通后缀输入，支持逗号或空白分隔并统一大小写。旧 UTI／正则规则只读保留；修改后缀或选择「改用后缀匹配」后才替换旧规则，修改其他字段不影响它们。插件包的匹配规则在详情中只读展示，导入审阅时也会显示。

左侧分类预览近似判断 UTI 和后缀，不验证正则；正则需在 Finder 中用真实文件名验证。

### `variants`：子菜单

将动作展开为子菜单，选中的值通过 `$ANYWHERE_VARIANT` 传给脚本。

- `{ "fixed": ["png", "jpeg", "webp"] }`：固定子菜单列表。
- `{ "directoryListing": "SomeDir" }`：将 `SomeDir` 中的文件列为子菜单项，相对路径基于 AnyWhere 数据目录。目录为空时，整个动作隐藏。

普通动作无需填写 `variants`。

### `settings`：插件配置项

配置项要求 **schemaVersion 2 或更高版本**；同时使用后缀或正则时填写 **3**。没有 `settings` 的动作保持原有行为。下面也是放入单个动作对象的字段片段：

```json
{
  "settings": [
    { "key": "HOST", "title": "Server", "type": "text", "defaultValue": "localhost", "required": true },
    { "key": "TOKEN", "title": "API token", "type": "password", "description": "Encrypted locally" },
    { "key": "VERBOSE", "title": "Verbose output", "type": "toggle", "defaultValue": "false" },
    { "key": "FORMAT", "title": "Format", "type": "select", "options": ["text", "json"], "defaultValue": "text" }
  ]
}
```

| `type` | 界面控件 | 传给脚本的值 |
|--------|----------|--------------|
| `text` | 文本框 | 字符串 |
| `password` | 隐藏内容的密码框 | 从本地加密文件解密得到的字符串，不允许默认值 |
| `toggle` | 开关 | `"true"` 或 `"false"`，默认 `"false"` |
| `select` | 下拉选择 | `options` 中的一个值；非必填且未选择时为空字符串 |

在「右键菜单」选中包内动作，即可在只读脚本上方看到配置表单。「保存配置」会校验并保存，后续执行和应用重启后自动读取；「清除配置」会删除已保存的值并恢复默认值。

字段约束：

- `key` 必须符合 `[A-Z][A-Z0-9_]{0,63}`，在同一个动作内唯一，并保持稳定。
- `title` 必填；`description`、`defaultValue`、`required` 可选。`required` 是布尔值，配置值和 `defaultValue` 使用字符串。
- `select` 必须提供非空且不重复的 `options`。`password` 不允许 `defaultValue`。
- 未保存的值先使用 `defaultValue`；没有默认值时，开关为 `"false"`，其他类型为空字符串。
- 运行时只将当前动作声明的字段注入为 `ANYWHERE_CONFIG_<KEY>`。必填项缺失或值非法时停止执行并提示配置错误。
- 脚本应将配置作为数据使用并加引号，例如 `"$ANYWHERE_CONFIG_HOST"`，不要作为 Shell 代码求值。

### 本地保存、加密与备份

用户配置独立于扩展包保存：

| 数据 | 路径（相对于 `~/Library/Application Support/AnyWhere/`） |
|------|------------------------------------------------------|
| 普通配置 | `PackConfigurations/<动作 UUID>.json` |
| 密码密文 | `PrivateData/secrets.enc` |
| 本地加密密钥 | `PrivateData/key` |

密码使用 AES-256-GCM 加密，首次保存时随机生成 256 位密钥。`PrivateData/` 目录权限为 `0700`，密钥和密文文件为 `0600`。密码不进入菜单快照或普通配置文件；执行输出中原样出现的密码会被遮蔽。脚本执行时仍能使用它声明的密码配置。

包更新时，动作 ID 和字段 key 不变即可保留配置。卸载默认保留配置，从同一来源重新导入可继续使用；也可在卸载确认中同时删除配置、密码和插件数据。不同来源会产生不同的动作身份，不保证继承旧值。

配置读写**不访问钥匙串、不要求输入系统密码**。从旧版升级时，请重新填写并保存一次密码字段；旧钥匙串条目不读取也不删除。本地加密不改变清单格式和脚本环境变量，已有包无需因此提高版本号。

备份必须包含整个 `PrivateData/`，同时保留密钥和密文。密文损坏或密钥缺失、不匹配时会报错，不自动重置原数据。本地加密防止直接查看明文，文件权限限制其他用户访问；以当前用户身份取得密钥和密文的进程仍可解密。应用没有内置固定共享密钥。

Xlog Decoder 的[清单](../examples/xlog-decoder-pack/manifest.json)将 `PRIVATE_KEY` 声明为 `password`，[脚本](../examples/xlog-decoder-pack/actions/decode-xlog.zsh)通过 `"${ANYWHERE_CONFIG_PRIVATE_KEY-}"` 读取。清单只描述字段，不包含真实私钥。用户填写一次后，脚本直接调用包内解码器，不再逐次弹出输入框。

<a id="script-environment-contract"></a>

## 脚本环境契约

扩展包脚本和内置预设一样，由 `/bin/zsh` 执行。

| 变量或参数 | 含义 |
|------------|------|
| `$1 … $n` | 选中项的绝对路径；`container` 动作收到目录路径 |
| `ANYWHERE_PATHS` | 全部路径，以换行分隔 |
| `ANYWHERE_VARIANT` | 选中的子菜单值；没有子菜单时为空 |
| `ANYWHERE_FINDER_PATH` | 当前激活的 Finder 目录；没有目录时为用户主目录 |
| `ANYWHERE_DATA` | AnyWhere 数据目录，可保存脚本状态 |
| `ANYWHERE_TEMPLATES` | 模板目录 |
| `ANYWHERE_TERMINAL` / `ANYWHERE_EDITOR` | 用户已配置的默认终端／编辑器 bundle ID |
| `ANYWHERE_SCRIPT` | 脚本自身绝对路径；`${0:A:h}` 是脚本所在目录 |
| `ANYWHERE_CONFIG_<KEY>` | 当前动作声明的配置项的已保存值或默认值 |
| 工作目录 | 第一个选中项的父目录；若该项本身是文件夹，则使用它自身 |
| 退出码 `0` | 成功，stdout 第一行作为摘要 |
| 非 `0` 退出码 | 失败，stderr 显示在「最近执行」和通知中 |

使用 `"$@"` 或 `ANYWHERE_PATHS` 读取输入，不要把路径拼成 Shell 命令文本。

声明的 zsh 脚本由解释器执行，无需可执行位；脚本直接启动的包内 CLI **需要可执行权限**。对于前文的目录结构，`actions/` 下的脚本可这样找到独立解码器：

```zsh
pack_root="${0:A:h:h}"
decoder="$pack_root/bin/xlog-decoder"
```

这样不依赖工作目录，也无需另外安装包含解码器的 App。

## 导入与审阅流程

1. **准备**：Git 来源执行 `git clone --depth 1`；本地来源复制到临时目录并保留可执行权限。导入过程不执行脚本。
2. **审阅**：逐一打开只读脚本后才能继续。未声明为动作脚本的其他文件也会列出，包括二进制，需要单独确认。每个动作的作用对象、UTI、后缀和正则也会展示。
3. **确认**：包移动到 `~/Library/Application Support/AnyWhere/Packs/<key>/`，动作加入配置并标记包来源，脚本路径解析为安装后的绝对路径。动作默认禁用，由用户逐个启用。

已安装脚本和匹配规则只读。需要修改时，编辑源文件夹或 fork 源仓库，再导入替换版本。用户仍可在设置中修改菜单标题、位置、排序、启用状态及包声明的配置值。

### 更新与重新导入

本地包安装的是独立副本，不检查 Git 更新。移动或编辑原文件夹不会影响已安装的动作。同一来源不能重复导入；开发模式下可点击「重新加载本地包…」审阅并应用源目录的新副本，也可卸载后重装。

Git 包通过「检查更新」比较远端 `HEAD` 与已安装版本的 SHA。更新时克隆新版本，展示清单、脚本及 UI 资源的差异，用户确认后应用。按动作 `id` 保留启用状态，新增动作或增加页面能力的动作默认禁用，远端删除的动作也会移除。替换前结束旧页面与任务；插件数据保留。卸载默认保留数据，可勾选同时删除配置、密码和插件数据。

## 发布与社区发现

符合规范的 Git 仓库仍可直接按 URL 导入，本地文件夹导入也保留。应用内「插件市场」读取 [AnyWhere Bazaar](https://github.com/AnyWhereTools/anywhere-bazaar) 的 `catalog.json`。开发者通过 PR 添加 `registry/<id>.json`，审核合并后进入市场；GitHub topic 不再决定应用内上架。

市场安装及更新使用目录记录的完整 Git commit，并验证实际 checkout 和 manifest，再进入源码审查。安装默认禁用；更新增加权限时仍需重新启用。旧版同源 HTTPS GitHub 安装会按仓库匹配市场条目，保留安装目录、动作标识、启用状态及用户数据；下一次市场更新保存 `catalogID`。已绑定条目下架或更换仓库时会提示错误，保留已安装版本，不自动改用仓库 HEAD。未登记的手动导入包仍按原仓库检查更新。本地包继续从原文件夹重新加载。

目录加载或校验失败会显示错误，可重试；不会自动切回 topic 搜索。目录当前支持 schemaVersion 1、最多 1000 个条目和 2 MiB，拒绝重复 ID/仓库及非完整 commit。用户选择的版本会一直保留到更新差异审查和安装完成。

打开扩展包页会自动检查更新；打开或刷新插件市场也会同步更新状态。有新版本时，已安装列表的折叠行和市场条目均显示「更新…」，点击即下载所选最新版并进入差异审查。取消后保留更新提示，应用成功后两个页面同时清除提示，插件数据继续保留。

官方仓库现归属 `AnyWhereTools`。JSON 编辑器、网页快开、待办和工具链示例保留原有 `appdev.*` 目录 ID；新版宿主兼容这四个已核实迁移的旧地址，保留安装标识、配置和数据目录，更新时从新地址下载。此兼容不适用于其他仓库或任意重定向。请先升级宿主再使用迁移后的集市。

脚本以当前用户权限执行。作者应保持脚本易于审阅、尽量减少依赖；用户应在启用前检查脚本和附带文件，只导入可信来源。更多说明见[安全说明](../SECURITY.zh.md)。
