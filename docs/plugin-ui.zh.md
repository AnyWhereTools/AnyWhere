# 插件搜索与自定义 UI

[English](plugin-ui.md) · [中文首页](../README.zh.md) · [扩展包规范](pack-spec.zh.md)

插件提供本地 HTML/CSS/JavaScript，AnyWhere 在工具面板或普通独立窗口中显示页面。JSON 只声明入口和能力，页面布局由开发者决定。网页使用浏览器 JavaScript；宿主不提供 Node/Deno。需要联网、处理文件或调用 Go/Rust 二进制时，由已审阅的包内脚本启动后端。

## 最小清单

```json
{
  "schemaVersion": 4,
  "uiApiVersion": 1,
  "name": "文本工具",
  "actions": [{
    "id": "text",
    "title": "文本工具",
    "launcher": {"keywords": ["text", "wenben"]},
    "contextMenu": false,
    "ui": {"entry": "ui/index.html", "height": 420},
    "capabilities": ["clipboard.write"]
  }]
}
```

有 UI 时 `script` 可省略。同时声明 UI 和脚本时，进入只加载页面；脚本由 `tasks.run` 显式执行。纯脚本功能也能声明搜索入口，其调用上下文通过任务请求文件传入。`contextMenu` 默认 `true`；设为 `false` 可创建纯搜索功能。每个功能至少有一个用户入口和一个执行入口。

`ui.entry` 必须是包内 HTML 相对路径，不能越过包目录（包括符号链接）。`height` 为正整数，宿主按屏幕可用范围限制。`launcher` 对象开启搜索注册；`keywords` 可省略或为空，标题始终可搜索。功能 `id` 和来源共同决定稳定身份；不要随意改 ID。

## 使用入口

导入后右键与搜索入口均默认禁用。在扩展包详情中分别开启；纯搜索功能也能在这里填写插件配置。通用设置可录制或停用快捷键，默认 `Control+Option+Space`。快捷键冲突会提示并保留旧绑定，菜单栏的「打开插件搜索」仍可用。

搜索收录已启用的工具、自建快捷指令和同包工作流，其后列出匹配的已安装应用；支持名称、全拼和拼音首字母，忽略大小写。工具／动作／工作流先匹配标题，再匹配别名，最后匹配包描述（未填写时用包名）；每组内先按原文完全匹配、前缀、包含排序，再匹配转写结果。原文标题或别名后跟空白时，余下文本作为参数，最长前缀优先；仅通过拼音匹配不会提取参数。方向键选择、回车打开；中文输入法组合输入时回车先确认候选。空查询只显示最近使用，没有历史时显示空态提示。历史不保存查询或参数。

在「快捷指令」中可新建可编辑的本地脚本动作，设置名称、关键词并启用，也可录制独立全局快捷键。新建动作默认停用，与 Finder 右键动作分开。包内快捷指令可设置本地显示名称、关键词和启用状态，实现仍由扩展包提供。工作流在包详情中启停和运行，目前没有清单关键词或单独快捷键字段。

### 工具面板与普通独立窗口

打开 UI 动作后，搜索结果区切换为工具页面。搜索状态失焦隐藏，工具打开后保持可见。返回、关闭或用全局快捷键收起面板会结束当前会话并取消任务；新调用到来时可保留当前操作或切换。Finder UI 动作通过面板打开，携带本次选中文件快照。

「在独立窗口打开」会关闭面板会话，在带关闭、最小化、缩放按钮的普通 macOS 可调整大小窗口中新建会话；不会搬移原 WebView，也不保留页面未保存的输入。不同工具可同时独立打开，同一动作已有独立窗口时再次打开会聚焦原窗口。独立窗口切换到其他应用后仍显示；关闭会结束会话并取消任务。需要跨会话保留的数据应使用宿主存储。

独立窗口的原生工具栏提供「重新加载页面」。重载结束旧会话和任务，从安装副本创建新会话，未保存的页面状态会丢失；工具面板也有自己的重载按钮。两处页面重载都不会复制源目录修改：开发时先用「重新加载本地包…」审阅更新，再打开工具。工作流中的工具步骤不能拆到独立窗口。

## 页面 SDK（API 1）

宿主注入 `window.anywhere`，无需下载 SDK。可复制 [TypeScript 类型声明](sdk/anywhere.d.ts)到编辑器项目。完整可导入示例见[文本工具](../examples/ui-tool-pack/README.zh.md)。

```javascript
anywhere.onEnter(async context => {
  document.querySelector('textarea').value =
    context.argument || await anywhere.storage.get('draft') || '';
});
await anywhere.storage.set('draft', '你好');
await anywhere.clipboard.writeText('你好');
```

| 接口 | 返回与语义 |
|---|---|
| `onEnter(callback)` | 就绪后交付一次上下文，晚订阅仍收到；返回取消订阅函数 |
| `getInvocation()` | Promise，返回同一上下文对象 |
| `workflow.context()` | Promise，返回 `{active, input}`；单独打开为 `{active: false, input: null}` |
| `workflow.complete(output)` | 当前交互工作流步骤提交一次 JSON 结果，宿主决定下一步 |
| `config.get()` | Promise，当前动作的普通配置字典，值为字符串；不返回密码 |
| `storage.get(key)` | Promise，JSON 值；键不存在返回 `null` |
| `storage.set(key, value)` / `remove(key)` | Promise，写入或删除插件级 JSON 数据 |
| `clipboard.writeText(text)` | Promise，需要 `clipboard.write` |
| `tasks.run(input)` | Promise，返回任务句柄，需要 `task.run` 和本动作的 `script` |

上下文包含 `apiVersion`、`invocationID`、`actionID`、`source`（`launcher` / `finder`）、`query`、`argument`、`paths`、`finderPath` 和可选 `variant`。`actionID` 是安装后的动作 UUID，不是清单中的局部动作 ID。搜索调用的 `paths` 为空；Finder 调用的查询和参数为空。`finderPath` 为捕获的 Finder 当前目录，无法获取时回退用户主目录；脚本对应变量为 `ANYWHERE_FINDER_PATH`。一次调用中的上下文不可变。

每个请求由宿主绑定当前页面、会话和插件身份。Promise 失败带 `message` 与稳定 `code`：`invalidArguments`、`denied`、`sessionClosed`、`busy`、`failed`、`timedOut`、`cancelled`、`outputLimit`、`storageLimit`。单次消息及返回值上限 1 MiB，超限报错。会话结束后不得继续使用旧句柄。

## 后端任务

```javascript
const task = await anywhere.tasks.run({text: '你好'});
const unsubscribe = task.onOutput(({stream, text}) => {
  // stream 为 stdout 或 stderr；使用 textContent 展示，不作为 HTML 执行。
  output.textContent += text;
});
// await task.cancel();
const result = await task.result;
unsubscribe();
if (result.error) console.error(result.error.code, result.error.message);
```

任务只执行当前动作声明的脚本，不接受任意命令或程序路径。沿用 `/bin/zsh`、选中文件位置参数和 `ANYWHERE_CONFIG_<KEY>`，工作目录为安装包根目录。`ANYWHERE_REQUEST_FILE` 指向权限 `0600` 的临时 JSON 文件：

```json
{"input":{"text":"你好"},"invocation":{"apiVersion":1,"source":"launcher","query":"text 你好","argument":"你好","paths":[]}}
```

上例省略了上下文的 UUID。后端直接读取并解析文件，不能把其内容拼成 Shell 命令。任务结束后宿主清除临时目录。Go/Rust 程序由脚本通过包内相对位置启动，开发者须提供适合系统与架构的二进制及依赖，并保留执行权限。

一个页面同时运行一个任务；重复运行返回 `busy`。stdout/stderr 增量输出，保留 UTF-8 字符边界，并遮蔽当前配置中的密码（包括跨管道分块的密码）。原始输出总量超过 4 MiB 时结束任务。`result` 包含退出码、每个流最多 32768 个字符的摘要，以及 `error`（成功为 `null`）；完整输出通过事件获取。取消和超时先发送 SIGTERM，最多等待两秒后终止进程组。后端不是常驻服务，不应自行脱离进程组。

## 同包工作流：脚本与交互工具

`workflows[].steps[].action` 只能引用**同一清单**中的动作 ID，详见[扩展包规范](pack-spec.zh.md#same-pack-workflows)。纯 UI 动作打开自己的真实页面并等待用户提交；声明了 `script` 的动作自动执行脚本，包括同时声明 UI 和脚本的动作（单独打开这种动作时仍加载 UI）。工作流可混合脚本与纯 UI 步骤。

需使用包含工作流 Bridge 的宿主构建。旧 schema-4/API-1 构建可能没有 `anywhere.workflow`，调用前应检测其是否存在并处理调用失败；不能仅凭 API 版本判断新方法可用。

首步输入是启动参数字符串，没有参数时为空字符串。每个脚本通过 `ANYWHERE_REQUEST_FILE` 读取 `{input, invocation}`；宿主将完整捕获的 stdout 解码为 JSON，解析失败时作为字符串交给下一步。stdout 只输出一个结果，诊断写 stderr。失败停止后续步骤，「重试」从第一步重新执行，不会回滚已经完成的副作用。

```js
const context = await anywhere.workflow.context();
// 单独打开：active=false、input=null；工作流中：input 是上一步输出。
if (context.active) showInput(context.input);
// 用户点击“下一步”后提交当前工具的结果；宿主负责切换页面。
await anywhere.workflow.complete(output);
```

`active` 区分「工作流传入 null」与「单独打开」。`complete` 只接受当前步骤的一次 JSON 提交（包括 `null`），无需新增能力声明。独立打开时返回 `denied`，重复提交或后台任务未结束时返回 `busy`；输出缺失、无效或请求超限返回 `invalidArguments`。采用现有 1 MiB 请求／响应限制；页面不能指定下一 action、启动工作流或跳过步骤。回复后宿主关闭旧会话并推进，不应再依赖当前页面完成其他操作。

中间 JSON 只保存在当前宿主流程内存中。重载会用同一份上游输入新建当前交互步骤，未提交的编辑会丢失；返回／关闭会取消流程，旧页面不能推进新流程。禁用工作流会结束流程；更新、重载本地包或卸载前先结束所属会话和任务。工作流入口启用即可执行其步骤，不要求工具的独立搜索入口同时启用。工作流定义变化或步骤能力扩大时，更新后需重新审阅启用。

真实脚本组合见[剪贴板 JSON 工作流](../examples/tool-panel-demo/README.zh.md)；交互例子见[接口响应工具链](../examples/tool-chain-demo/README.zh.md)：A 提取 JSON → B 等待人工选择节点 → C 生成 TypeScript，三个工具可各自单独打开，但仍在**同一个包**中。跨开发者、跨扩展包组合属于**规划，尚未实现**，见[开发设计与实施计划](cross-pack-workflows.zh.md)。

## 数据、权限和生命周期

- `storage` 在 `PluginData/<packKey>/data.json` 保存，每包 5 MiB，同包多个功能共享。键是非空字符串，最长 1024 UTF-8 字节。写入原子替换，超限保留旧数据。
- 普通配置继续位于 `PackConfigurations/`，密码沿用本地加密的 `PrivateData/`，由原生配置表单管理。页面不能批量读取密码；宿主启动任务时按配置注入。
- 目录权限 `0700`，插件数据文件 `0600`。WebView 使用非持久数据存储；持久数据请使用 `storage`，不要依赖网页 localStorage。
- 网页只加载包内资源，禁止直接联网、远程脚本和 iframe。HTTP(S) 链接由用户点击后交给系统浏览器。只有原始主页面可以调用 Bridge。
- 能力声明约束网页与宿主接口；脚本和二进制仍具有当前用户权限，不是系统沙盒。请审阅所有附带文件。
- 更新保留身份与数据；增加能力的功能会重新禁用入口。更新或卸载前先结束旧会话和任务，避免旧页面调用新脚本。
- 卸载默认保留数据；可勾选同时清除配置、密码与数据，清理失败会显示错误。同一来源重装可恢复保留的数据，来源路径改变视为新插件。

## 开发与调试

通用设置开启「开发模式」后，新建页面可使用 Web Inspector；本地包增加「重新加载本地包…」，重新复制源文件并展示更新差异，确认后保留数据应用。页面重载按钮只加载已安装副本并建立新会话。JS 错误与任务失败显示在宿主顶部；任务输出由页面订阅。

页面可以用 `event.preventDefault()` 消费 Escape，例如关闭自己的弹层；未处理的 Escape 返回搜索。页面应自行适应窗口尺寸、提供标签与键盘操作，不使用任意原生窗口或 Node API。
