# 接口响应工具链：A → B → C

[English](README.md) · [UI 开发文档](../../docs/plugin-ui.zh.md) · [清单](manifest.json)

这个可导入的示例演示**同包**独立工具间的数据交接。三个页面既能单独使用，也能由宿主按 manifest 串联；工作流没有重新实现工具逻辑，也不依赖剪贴板传递中间结果。它不是三个独立扩展包；跨开发者组合见[尚未实现的设计与实施计划](../../docs/cross-pack-workflows.zh.md)。

| 工具 | 单独使用 | 工作流中 |
| --- | --- | --- |
| A：JSON 提取器 | 粘贴日志/说明，提取 JSON，选择候选并复制 | 将选中的 JSON 对象/数组交给 B |
| B：JSON 节点选择器 | 粘贴 JSON，选择所需节点并复制 | 自动接收 A 的输出，等待选择后交给 C |
| C：JSON 转 TypeScript | 粘贴 JSON，设置类型名并生成代码 | 自动接收 B 所选数据并生成代码，可编辑、复制、完成流程 |

## 一分钟体验

1. 在扩展包页导入本目录，审阅 HTML/JS/CSS，启用三个工具入口和“接口响应 → TypeScript”工作流。
2. 搜索“接口响应”，回车。顶部显示三个步骤，当前进入 A。
3. 点击“填入示例”，再点“提取 JSON”“交给 B”。无需复制。
4. B 已自动载入响应。从“数据节点”中选择 `$/data/items`，预览两条用户记录，然后点“交给 C”。无需粘贴。
5. C 自动生成 `Response` 类型。结果包含用户字段，缺失的 email/active 标为可选；没有响应外层的 status/data。
6. 修改类型名称后点“生成类型”，可继续编辑代码或复制。点击“完成工作流”进入最终结果。

只体验串联时，仅启用工作流即可；三个独立工具开关不控制流程步骤。已导入旧副本时，开发模式下「重新加载本地包…」并审阅更新，再重新启用有变更的工作流；页面重载不复制源文件修改。

对比单独使用：分别搜索“JSON 提取器”“JSON 节点选择器”“JSON 转 TypeScript”，页面没有“交给下一工具”按钮，输入由用户粘贴，结果可复制。它们与流程中的页面、算法完全相同。

示例数据全部虚构；默认不读取剪贴板、不联网、不写用户文件。点击复制才写剪贴板。

## 为什么这是工具串联

工具只处理输入并产出结果，不知道下一个工具在哪里。串联关系只在 manifest 中：

```json
{"id":"response-types","title":"接口响应 → TypeScript","steps":[
  {"action":"extract"},
  {"action":"select"},
  {"action":"types"}
]}
```

宿主负责打开当前工具的真实 WebView、注入上一份 JSON、等待提交、销毁旧会话和打开下一工具。B 的等待是正常交互状态，不是假装后台步骤已经自动完成。

## 开发者契约

```js
const {active, input} = await anywhere.workflow.context();
if (active) renderInput(input);
// 用户完成工具操作后：
await anywhere.workflow.complete(output);
```

- 独立使用时 `active=false`、`input=null`，隐藏“下一步”，继续提供原有粘贴/复制入口。
- A 输出 JSON 对象或数组；B 输出被选中的任意 JSON 节点；C 输出 TypeScript 字符串。中间数据仅保存在当前宿主流程内存中。
- `complete` 回复后宿主切换页面，不要再依赖当前页面继续工作；一次步骤只能提交一次。独立调用返回 denied，重复提交返回 busy。
- 未调用 `complete` 就不会进入下一步。工具应在自己的页面展示输入错误并允许修正；工具无法自行指定下一个 action。
- 返回/关闭取消整个流程，重载当前步骤恢复上游输入。运行中的流程禁止拆成第二个独立窗口，避免双重提交。
- 单独使用时可以拆到普通独立窗口；这会新建页面会话，丢失未保存输入。独立窗口原生工具栏可重载，关闭结束会话；本 Demo 未使用宿主持久存储。
- 清单仍是 schemaVersion 4、uiApiVersion 1，需使用包含 workflow SDK 的新版 AnyWhere。纯 UI action 支持上述交互；声明 script 的动作仍执行脚本以兼容旧流程。

## 文件分工与边界

- `extract.html`、`select.html`、`types.html`：三个独立工具页面。
- `tools.js`：无宿主依赖的提取、节点定位、类型推断函数；节点使用 key 路径数组，支持键名中的点号和斜杠，未使用 eval。
- `ui.js`：统一接收输入、处理按钮、交出结果。页面内容都通过文本/表单 API 渲染，不把日志作为 HTML 执行。
- `style.css`：与现有面板接近的系统字体、圆角、浅深色和键盘焦点样式。

提取器识别对象/数组，多个候选让用户选择；输入上限 128 KiB，最多 64 层和 2000 个数据节点。大整数超出 JavaScript 安全范围时拒绝处理。TypeScript 检查所有数组样本，合并字段和联合类型，缺失字段标为可选；空数组生成 `Array<unknown>`。字段排序保证单独使用和流程传值结果一致。生成结果是样本推断，不推断日期、枚举或业务上的必填约束，需要开发者确认。

## 验证

在仓库根目录运行：

```sh
xcodebuild -project AnyWhere.xcodeproj -scheme AnyWhere -configuration Debug \
  -derivedDataPath build -only-testing:AnyWhereTests/ToolChainTests test
```

覆盖纯算法、真实 WebView 的 A→B→C、B 等待选择、重载保留上游输入、独立 C 与工作流 C 结果一致、独立提交拒绝、重复提交拒绝，以及返回取消会话。测试不写系统剪贴板。
