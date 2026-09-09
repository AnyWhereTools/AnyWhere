# 工具面板与剪贴板 JSON 工作流

[English](README.md) · [UI 开发文档](../../docs/plugin-ui.zh.md) · [清单](manifest.json)

这是一个可实际使用的本地扩展包：便笺用于临时记录，JSON 面板用于手动编辑；两条工作流用于在任意应用复制 JSON 后，一键整理并写回剪贴板。仅依赖 macOS 自带的 zsh、osascript/JXA 和系统框架，无需 Node.js、Python 或网络。

## 安装与更新

在扩展包页导入本目录，审阅脚本与 `json-workflow.js`，再启用需要的入口。已安装旧 Demo 时，点击“重新加载本地包…”并重新审阅；旧的“Demo 工作流”和“Demo 失败工作流”会被替换为下面两条，新工作流需要单独启用。

启用“便笺”和“JSON”面板，以及两条工作流即可。带“工作流步骤”的四个动作是复用单元，保持单独快捷指令关闭；工作流执行不要求它们单独启用。

## 实际使用

| 入口 | 操作与结果 |
| --- | --- |
| 剪贴板 JSON 格式化 | 复制 JSON → 搜索此名称并回车（或点击扩展包详情的“运行”）→ 得到两空格缩进的 JSON，同时写回剪贴板 → 在编辑器粘贴 |
| 剪贴板 JSON 压缩 | 复制多行 JSON → 运行 → 去除格式空白，生成单行 JSON 并写回剪贴板，方便粘贴到请求参数或配置中 |

可先复制这一行：

```json
{"name":"AnyWhere","items":[1,true,null]}
```

运行“剪贴板 JSON 格式化”后，面板和粘贴结果应为：

```json
{
  "name": "AnyWhere",
  "items": [
    1,
    true,
    null
  ]
}
```

再运行“剪贴板 JSON 压缩”，结果恢复成单行。复制 `{broken` 再运行，会出现真实校验错误，原剪贴板不变；修正 JSON 并重新复制后，可点击面板里的“重试”。不再提供故意报错的演示入口。

两个面板也可配合使用：在 JSON 面板编辑并点击“复制内容”，返回搜索运行上述工作流，再粘贴到便笺或外部编辑器。面板内容由 HTML/CSS/JS 实现，点击“在独立窗口打开”会结束原面板会话，创建普通独立窗口；便笺与 JSON 可同时独立打开。同一工具再次独立打开会聚焦已有窗口。原生工具栏可重载页面；页面输入仅保留在当前会话内，独立打开、重新加载或关闭后会清空，不承诺原型中的 WebView 搬移行为。

## 开发者参考：步骤与数据契约

```text
read-clipboard ──→ format-json  ──→ write-clipboard
               └→ compact-json ──→ write-clipboard
```

两个流程共用读写步骤，只替换中间转换步骤。`manifest.json` 中定义动作脚本，再用 `workflows[].steps[].action` 引用动作 ID：

```json
{
  "id": "format-clipboard-json",
  "title": "剪贴板 JSON 格式化",
  "steps": [
    {"action": "read-clipboard"},
    {"action": "format-json"},
    {"action": "write-clipboard"}
  ]
}
```

| 步骤 | 输入 | 输出与副作用 |
| --- | --- | --- |
| read-clipboard | 首步不使用工作流输入 | 从系统剪贴板读取文本，输出 `{text, changeCount}`；无文本时停止 |
| format-json / compact-json | 请求文件的 `input` 字段 | 解析 JSON 后输出新的 `{text, changeCount}`；不改剪贴板 |
| write-clipboard | 转换后的 `{text, changeCount}` | 检查剪贴板版本未变后写回，输出一个 JSON 字符串，面板显示其原始文本 |

- 每个脚本通过环境变量 `ANYWHERE_REQUEST_FILE` 获取宿主生成的请求文件，结构为 `{input, invocation}`。前一步 stdout 中的 JSON 会解码为下一步的 `input`。不要用 stdout 打调试日志；stderr 留给诊断。
- 本例的 zsh 入口将操作名和请求文件路径传给同一个 `json-workflow.js`，其中 `run(argv)` 是 JXA 入口。传路径，不把剪贴板内容插入 Shell 命令。
- 抛出的错误使脚本非零退出，宿主停止后续步骤并显示错误；重试会从第一步重新读取剪贴板。
- `changeCount` 用于发现运行期间的新复制操作，发现变化便停止写回。JSON 数值遵循 JavaScript Number 语义；超出安全范围的整数会被拒绝，大整数 ID 请用字符串表示。
- `capabilities` 限制的是 WebView 的 `anywhere` 桥接接口，例如面板使用的 `clipboard.write`。当前脚本执行不受这些桥接权限沙盒限制，本例脚本通过 AppKit 读写剪贴板，安装时应审阅完整源码。没有虚构 `clipboard.read` 权限。
- 页面入口看 `json.html` / `notes.html`，视觉样式看 `style.css`。本例工作流只串联同包脚本，当前没有“直接运行工作流”的页面 SDK，示例通过剪贴板衔接面板和工作流。真实交互步骤用 `workflow.context/complete`，见[接口响应工具链](../tool-chain-demo/README.zh.md)；跨包组合[尚未实现](../../docs/cross-pack-workflows.zh.md)。

## 可运行验证

在 AnyWhere 仓库根目录执行：

```sh
xcodebuild -project AnyWhere.xcodeproj -scheme AnyWhere -configuration Debug \
  -derivedDataPath build \
  -only-testing:AnyWhereTests/LauncherWorkflowTests/testClipboardJSONWorkflowsPreserveInputOnFailure test
```

测试实际执行扩展包脚本和宿主工作流，覆盖格式化、压缩、非法 JSON、空文本、大整数，以及执行期间剪贴板变化。测试通过 `ANYWHERE_DEMO_PASTEBOARD` 指定临时命名剪贴板，不读取或覆盖系统剪贴板。正常使用无需设置此变量。
