# 本机 MCP 与插件命令

AnyWhere 提供一个本机 stdio MCP 服务，插件通过 schema 5 的 `commands` 和 `mcp` 声明注册能力。宿主不包含 Todo 等插件的业务规则。AnyWhere 需保持运行，辅助程序不直接读写插件数据。

## 使用

构建后的辅助程序位于 `AnyWhere.app/Contents/MacOS/anywhere-mcp`。先在扩展包的功能设置中开启“允许通过 AnyWhere MCP 调用”，再在 MCP 客户端注册一次该程序。例如安装在 `/Applications` 时：

```sh
codex mcp add anywhere -- /Applications/AnyWhere.app/Contents/MacOS/anywhere-mcp
```

`anywhere list`、`anywhere todo` 是逻辑调用名称；MCP 中实际是服务 `anywhere` 下的 `list`、`todo` 工具，显示前缀由客户端决定。

```json
{"name":"list","arguments":{}}
{"name":"list","arguments":{"plugin":"todo"}}
{"name":"todo","arguments":{"operation":"list","params":{"status":"pending"}}}
{"name":"todo","arguments":{"operation":"create","params":{"fields":{"title":"整理会议记录"}}}}
```

`list` 只显示已授权且名称无冲突的插件。指定插件时返回各操作的参数 Schema。关闭授权后，即使客户端缓存着旧工具定义也无法继续调用。辅助程序每两秒检查注册表变化并发送 `notifications/tools/list_changed`；客户端是否立即刷新取决于其实现。

## 插件声明

在 action 上增加以下声明；原有 UI、脚本及 capability 声明继续有效。纯命令 action 可不声明 UI/脚本，但必须关闭 contextMenu，且不能声明 launcher。

```json
{
  "commands": {
    "entry": "commands.html",
    "storageKeys": ["items"],
    "operations": {
      "list": {
        "description": "查询数据",
        "readOnly": true,
        "inputSchema": {"type":"object","properties":{},"additionalProperties":false},
        "outputSchema": {"type":"object"}
      }
    }
  },
  "mcp": {
    "name": "example",
    "description": "示例插件",
    "commands": ["list"]
  }
}
```

在后台 HTML 中加载插件脚本并注册处理器：

```js
anywhere.commands.register({
  list: async params => ({items: await anywhere.storage.get('items') || []})
});
```

交互页面调用同一 action 的命令，并监听数据变化：

```js
const result = await anywhere.commands.invoke('list', {});
const unsubscribe = anywhere.commands.onChanged(() => refresh());
```

宿主根据声明自动生成每插件一个工具的 `operation/params` 分支 Schema。只导出 `mcp.commands` 中的命令。`list` 为宿主保留名；重名插件不导出，启用时提示冲突。授权绑定完整命令/MCP/capability 声明，声明变化后需重新开启。

支持的 JSON Schema 子集：`type`（含类型数组）、`properties`、`required`、布尔 `additionalProperties`、`items`、`enum`、`const`、`oneOf`、`anyOf`、`minimum/maximum`、`minLength/maxLength`、`minItems/maxItems`、`description/title`。不支持的关键字在导入时拒绝，不静默忽略。输入根类型必须是 object；可选 outputSchema 在返回时校验。请求和结果最多 1 MiB。

## 并发、存储与提醒

命令按插件数据命名空间排队，锁定范围跨越读取、保存和所有异步副作用；不是仅将函数放到 MainActor。普通页面不能直接写入 `storageKeys`。后台命令只允许写入声明的键；readOnly 命令不能写存储或替换提醒。不同 action 不能声明相同受管键。这个约束保护宿主存储接口，不是对插件脚本的文件系统沙箱。

`anywhere.commands.fingerprints(values)` 返回规范化 JSON 的 SHA-256 版本。插件应在命令内读取最新数据并比较 expectedVersion；宿主不自动重试冲突。插件负责业务合并，不能用客户端传入的整份旧状态覆盖当前状态。关闭 MCP 不影响内部命令调用。

需要恢复副作用时，`commands.reconcile` 指定一个无参数命令，宿主在启用/启动/定义变更后排队执行。通知插件可用 `commands.notification` 指定内部命令，接收 `{event, reminder}`，继续使用自身业务规则处理。普通页面的通知处理也应调用命令。

数据保存与提醒登记不是一个跨文件事务。Todo 先保存，再用 `Todo.reminders()` 和现有 `notifications.replace()` 同步，分别返回 `saved` 和 `reminderSync`。提醒失败不撤销已保存任务；同步重试和启动恢复均从最新 Todo 数据生成。命令超时关闭后台页面，队列等待已发出的原生调用结束后再执行下一条，避免旧提醒最后到达。

## Todo

Todo 导出 `list/create/update/complete`。create 只需提供 fields.title，Todo 内部生成待办 ID，并在 item.id 中返回。requestId 可省略，仅作为独立的重试去重键；任务仍存在时，相同键跨重启返回现有项，不覆盖内容。旧版以 requestId 为任务 ID 的记录仍识别原请求的重试，已有任务 ID 不迁移。删除后不保证旧创建请求的去重。查询返回 item.version，修改/完成使用返回的 id 和 expectedVersion；冲突返回 `conflict`。complete 设置为完成，重复调用不会切回未完成。

`deadline` 使用本机 `YYYY-MM-DD`；`reminderAt` 使用带时区偏移的 ISO 8601，`null` 清除提醒。内部界面也可使用毫秒 `due`，两者不能同时传入。仅设置截止日期不会开启提醒。保留每日/每周的本机时刻策略。修改时未传字段保持原值。

冲突时保留界面草稿；AI 需重新查询再判断。连接断开或结果为 `outcomeUnknown` 时，修改先按任务 ID 查询；创建若传了 requestId，可使用同一键重试取得原任务，若未传则先查询确认，不自动重发创建。Socket 仅当前用户可访问，任何同用户进程均可调用已授权功能。

## 验证

```sh
cd Core && swift test
```

Todo 仓库运行 `node test.cjs` 和 `node commands.test.cjs`。宿主运行 `PluginCommandRuntimeTests`，包含真实 WebView 并发和打包后的 stdio MCP→Socket→Todo 调用。`scripts/test-mcp.py` 由原生测试启动，使用隔离的 Socket 和插件数据；辅助程序支持 `ANYWHERE_MCP_SOCKET_PATH` 覆盖本地端点用于隔离测试。不需要修改用户 Codex 配置。
