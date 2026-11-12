# 插件通知使用指南

[English](plugin-notifications.md) · 简体中文 · [开发者文档](README.zh.md) · [宿主服务](plugin-services.zh.md) · [SDK 类型](sdk/anywhere.d.ts)

## 职责

| AnyWhere 宿主 | 插件（以 Todo 为例） |
| --- | --- |
| 提供可用的通知呈现方式、权限查询、定时调度与取消 | 决定提醒方式和时间；Todo 统一使用悬浮提醒 |
| 展示插件提交的标题、正文和按钮 | 定义“推迟”“确认完成”等按钮及其业务含义 |
| 验证来源，回传被点击的按钮 ID | 选择推迟时间、保存待办状态、同步剩余提醒 |

宿主不认识 Todo 的数据结构，也不会自行修改 `done` 或决定推迟多久。

## 1. 声明能力并检查版本

在 `manifest.json` 的对应 **action** 中声明：

```json
"capabilities": ["notifications"]
```

用户须启用该 action 的搜索入口。UI 页面直接使用宿主注入的 `anywhere`，不需要导入 npm 包。

```js
const supportsActions = anywhere.notifications?.supportsActions === true;
const presentations = anywhere.notifications?.presentations ?? ["system"];
const authorization = await anywhere.notifications.status();
```

旧宿主没有 `supportsActions` 和 `presentations`，不能只凭 `notifications` 存在就假定支持按钮和浮窗。插件应提示升级，或明确保留普通系统通知功能。

## 2. 插件选择呈现方式

| `presentation` | 展示方式 | 运行条件 |
| --- | --- | --- |
| `system`（默认） | macOS 系统通知 | 需要系统通知授权；登记后无需插件页面或 AnyWhere 一直打开 |
| `panel` | AnyWhere 提醒浮窗 | 无需系统通知授权；AnyWhere 必须运行，但插件页面可以关闭 |

系统通知的临时／持续样式由用户在 macOS 通知设置中选择，插件不能强制指定；按钮可能收纳在通知选项中。浮窗显示插件声明的按钮。两者都不保证关机期间提醒。

系统单次提醒的过去时间不会在同步时重新补发。浮窗单次提醒若尚未展示，在宿主下次启动时补发；已经展示并关闭的单次浮窗不会反复弹出。关闭提示不等于完成业务。

## 3. 保存业务数据，再同步全部提醒

下面以 Todo 的 `items` 为例。`items` 是插件已经保存成功的数据，不是 SDK 自带变量：

```js
async function syncReminders(items) {
  const reminders = items.filter(t => !t.done && t.due !== null).map(t => ({
    id: t.id,
    title: t.title,
    body: t.note,
    date: t.due / 1000, // JavaScript 毫秒转 Unix 秒
    recurrence: t.recurrence,
    presentation: "panel", // Todo 固定使用右上角悬浮提醒
    actions: [
      { id: "snooze", title: "推迟", background: true,
        options: [{id: "snooze-5", title: "5 分钟后"}, {id: "snooze-60", title: "1 小时后"}] },
      { id: "complete", title: "确认完成", background: true }
    ]
  }));

  const result = await anywhere.notifications.replace(reminders);
  if (result.errors.length) throw new Error(result.errors.join("；"));
}
```

调用方应捕获同步错误并在页面展示“数据已保存，但提醒同步失败”，提供重试入口。其他插件选择 `system` 时还需检查 `result.authorization === 'authorized'`。不要因通知授权失败回滚已保存的数据，也不要把保存成功说成通知一定能送达。

### 参数与限制

| 字段 | 说明 |
| --- | --- |
| `id` | 稳定的提醒 ID，1–128 字节，仅字母、数字、`-`、`_` |
| `title` | 必填，非空，最多 512 UTF-8 字节 |
| `body` | 正文，可以为空，最多 4096 UTF-8 字节 |
| `date` | Unix **秒**；必须是有效、正数时间，早于公元 3000 年 |
| `recurrence` | `none`、`daily`、`weekly`；重复按本地时刻／星期取下一次匹配，不是任意远期起始日期 |
| `presentation` | 可选，`system` 或 `panel`，省略为 `system` |
| `actions` | 可选，最多两个 `{id,title}`；ID 在当前提醒内唯一，格式同提醒 ID；标题非空且最多 128 UTF-8 字节 |

**`replace` 是当前 action 的全量替换，不是追加。** 每次最多 50 条，ID 不可重复。更新某条提醒时仍须传入其他保留的提醒；插件不能修改其他 action 的通知。

```js
// 唯一一条提醒：5 分钟后通知。
await anywhere.notifications.replace([{
  id: "example-001", title: "提交周报", body: "检查本周完成事项",
  date: Date.now() / 1000 + 5 * 60,
  recurrence: "none", presentation: "system"
}]);

// 仅当确实要取消当前 action 的所有提醒时调用。
await anywhere.notifications.replace([]);
```

## 4. 处理按钮回调

普通按钮（未设置 `background`）会激活插件，通过 `onEnter` 交付事件，可能打开插件窗口。已有窗口也会收到回调，不能只在首次加载时处理。卡片内后台按钮使用下文的 `notifications.onAction`。

```js
anywhere.onEnter(context => {
  if (context.notification) {
    // 这是插件自己的函数，不是宿主 SDK。
    handleNotification(context.notification).catch(showError);
  } else if (context.argument) {
    // 普通点击通知正文：定位提醒对应的条目。
    openItem(context.argument);
  }
});
```

此示例中的 `handleNotification`、`showError`、`openItem` 都由插件实现。按钮事件结构：

```js
{
  id: "稳定的事件ID",   // 用于防止重复处理
  itemID: "todo-001",    // replace 中的提醒 id
  actionID: "complete"  // actions 中的按钮 id
}
```

Todo 的处理顺序：

1. 重读持久数据，确认待办仍存在且未完成；已经处理过该事件 `id` 则忽略。
2. `complete`：设置 `done = true` 和完成时间，不能用“取反”完成状态。
3. `snooze-5` 等菜单项：由 Todo 根据菜单项 ID 计算新的提醒时间，保持未完成；旧版 `snooze` 回调仍兼容插件内时间选择器。
4. 将业务变更和事件 ID 一起保存，然后调用 `replace` 同步全部剩余提醒。

若通知到达时页面正在保存，插件应按顺序处理回调，避免直接丢弃忙碌期间的事件。旧通知已被修改、取消或所属插件停用时，宿主会拒绝执行其过期按钮。

### 卡片内菜单与后台处理

检测 `anywhere.notifications.supportsInlineActions` 后，`panel` 按钮可设置 `options`（1–6 个单层菜单项）和 `background: true`。菜单项 ID 在整条提醒内必须唯一；回调中的 `actionID` 是选中的菜单项 ID，宿主不解释 ID 的业务含义。系统通知不接受这两个扩展字段。

```js
anywhere.notifications.onAction(async event => {
  // 在这里读取最新数据，按 event.id 去重，再保存并同步提醒。
  // 例如由插件把 snooze-5 解释为五分钟后，宿主不会修改 Todo 数据。
  await handleAndPersistNotification(event);
});
```

处理器运行在临时的不可见插件页面，正常初始化及 `onEnter` 仍会执行，但不会打开工具窗口。处理器应在加载数据后注册，20 秒内完成，且不能依赖弹窗输入。成功返回后关闭卡片；抛出错误时卡片显示错误并允许重试。先保存业务状态和事件 ID，再同步提醒；重试已经保存的事件时只重新同步，不能重复推迟。未设置 `background` 的按钮继续通过 `onEnter` 打开插件。

卡片显示在当前屏幕右上角、菜单栏下方，多条提醒向下排列。该布局属于 AnyWhere；菜单文案、推迟时长、完成状态和事件去重属于插件。

浮窗是宿主统一提供的通用通知 UI：固定的 AnyWhere 标识与插件来源、适配浅色／深色的渐变背景和圆角阴影、轻强调操作按钮、系统下拉菜单及处理／错误反馈。插件只提供标题、正文和操作声明，不接管卡片布局，也不需要实现一套浮窗。

## 5. Todo 中的使用和验证

1. 打开 Todo → 新建或编辑待办 → 设置未来的“提醒时间”。
2. 点击保存，检查页面底部的提醒状态。Todo 统一使用悬浮提醒，无需选择样式；AnyWhere 需要保持运行。
3. 到期直接在卡片的“推迟”菜单选 5／15／30 分钟或 1 小时；无需跳转到 Todo，任务仍为未完成，提醒时间更新。
4. 到期点击“确认完成”：进入已完成列表，对应后续提醒取消。关闭通知或取消推迟不改变完成状态。

当前 Todo 对重复提醒的约定：推迟会调整后续重复时刻，不能跨过一个重复周期；选择窗口会显示说明。这属于 Todo 策略，不是宿主给所有插件设定的业务规则。

### 自动化与交互验收

先将 `anywhere-todo` 检出到 AnyWhere 仓库的同级目录。[OfficialPluginTests.swift](../AppTests/OfficialPluginTests.swift) 直接加载真实 WebView，使用隔离的待办存储与通知命名空间，不覆盖用户待办。纯业务检查在 Todo 仓库运行 `node test.cjs`。系统通知送达需要测试机器已有通知授权；测试跳过不能视为已验证送达。

在 AnyWhere 仓库先运行 `make gen`，再执行对应检查：

```sh
xcodebuild -project AnyWhere.xcodeproj -scheme AnyWhere -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  -only-testing:AnyWhereTests/OfficialPluginTests/testTodoSnoozeChoicesAndCancellation \
  -only-testing:AnyWhereTests/OfficialPluginTests/testTodoActualFormPersistsAndSchedulesIndependently test
```

第一个测试覆盖推迟选项、取消、无效时间，以及真实计时器到期 → 原生浮窗按钮 → 宿主路由 → Todo 完成 → 清除提醒。第二个测试覆盖表单保存和页面关闭后的系统通知送达、按钮分类与负载登记。

另需在通知中心实际点击系统通知按钮，检查插件页面关闭时也能重新打开并处理操作。WebView 回调和浮窗按钮测试不能替代该验收。2026-09-11 本地开发版本的上述自动化路径已通过，通知中心实际按钮点击仍未验收；该记录不代表功能已经发布。
