# 插件宿主服务：文件、动态搜索与提醒

[English](plugin-services.md) · [开发者文档](README.zh.md) · [完整类型](sdk/anywhere.d.ts) · [UI SDK](plugin-ui.zh.md)

这些服务扩展现有 schema 4 / UI API 1，分别声明 `documents`、`launcher.entries`、`notifications` 能力。未知能力在旧宿主会被拒绝；请升级到含本服务实现的构建。新增权限仍触发现有更新审阅与停用机制。

## 文档

`documents.open()` 打开原生选择器，返回 `{name,text}` 或取消时的 null；`saveAs(text,name)` 通过保存面板写入，不接收任意路径。UTF-8、普通文件、最多 50 MiB。文件传输内部使用 192 KiB 二进制块和会话级不透明句柄，单次桥接继续保持 1 MiB 限制。

编辑时调用 `markDirty(version)`；调用 `saveDraft(text,version)` 后，仅匹配当前版本才解除未保存状态。`draft()` 恢复动作隔离的最新完整草稿。临时写入完成后原子替换；取消或失败不覆盖旧草稿。会话关闭释放句柄和未完成临时写入，未保存文档关闭时提示。`copyText(text)` 支持大文本且额外要求 `clipboard.write`。

`documents` 允许页面创建 Blob Worker 进行离线计算，网络连接仍被 CSP 禁止。JSON 编辑器使用此机制；不能为了传大文件提高普通配置、通知或脚本桥接限制。

## 动态搜索

`launcher.setEntries([{id,title,keywords,url}])` 替换本动作的整份索引。最多 1000 条，ID 仅允许字母、数字、下划线与短横线且最多 128 字节。网址限定不含凭据的 HTTP(S)；`{query}` 在宿主按查询参数编码后替换。

宿主按来源动作派生搜索身份、复用名称/拼音/首字母/别名匹配。索引持久化于该动作的宿主服务目录，页面关闭后仍可用，停用或卸载后不出现在主搜索。`launcher.open(id,argument)` 只打开已登记的条目；主搜索执行时重新核对安装、启用和条目状态。

插件先保存自己的完整模型，再登记可搜索子集；失败需展示并重试，不能把索引当成唯一数据。网页快开是使用范例。

## 定时通知

`notifications.status()` 返回 `authorized`、`denied`、`notDetermined`。`replace(reminders)` 持久化本动作的整份提醒意图并同步系统，每条 `{id,title,body,date,recurrence}`：`date` 为 Unix 秒，`recurrence` 为 `none`、`daily`、`weekly`。每动作最多 50 条；系统自身的数量/授权限制会作为错误返回。空数组取消该动作的提醒。

系统通知的单次过去时间不重新补发；重复按本地时刻/星期取下一次匹配。每条系统请求用宿主来源身份隔离，修改同 ID 替换，完成/删除移除。相同提醒同步不会清除用户尚未处理的已送达通知。插件不能取消其他来源的提醒。停用入口、删除动作、权限移除或卸载会撤销对应通知；保留数据后重新启用会恢复仍有效的调度。

页面同步系统通知时申请横幅与声音权限，兼容此前仅申请横幅的安装；系统已记录授权选择后不会重复弹出首次授权提示，也不会覆盖用户关闭通知的选择。禁止时返回状态，界面必须说明任务已保存但没有系统通知。检查 `replace` 的 `{authorization,errors}`，不要把持久化成功误认为送达成功。系统通知由 macOS 调度；浮窗由运行中的 AnyWhere 调度，关闭 WebView 均无需保持脚本或页面计时器。

点击通知时宿主验证来源仍安装且启用，然后打开动作，并将待办 ID 放入 `invocation.argument`。冷启动等待扩展包加载；已有面板通过 `onEnter` 再次接收上下文，独立窗口直接聚焦。不要只在页面初始化时读取一次上下文。

### 通知呈现和操作按钮

完整调用示例、参数限制和 Todo 操作步骤见[插件通知使用指南](plugin-notifications.zh.md)。

插件通过每条提醒的 `presentation: "system" | "panel"` 选择系统通知或宿主提醒浮窗，默认 `system`。`notifications.presentations` 列出当前宿主支持的方式，`supportsActions` 表示支持按钮；旧宿主没有这两个字段，插件应提示升级。

`actions: [{id,title}]` 声明最多两个按钮，ID 在本条提醒内唯一。宿主展示内容、调度提醒、校验来源，并把按钮事件通过 `onEnter` 的 `invocation.notification = {id,itemID,actionID}` 交给插件。插件持久化事件 ID 防止重复处理；业务状态和后续 `replace` 均由插件完成。宿主不解释“推迟”“完成”等业务含义。普通点击仍用 `argument`；关闭通知/浮窗不产生业务操作，已取消或已更新提醒的旧按钮不会执行。

系统通知的临时／持续样式、操作按钮是否收纳及专注模式由 macOS 控制。浮窗不依赖系统通知授权，但需要 AnyWhere 运行；关闭插件页面不影响调度。浮窗的单次过期提醒会在下次启动补发，已展示的单次提醒不会在刷新或重启后重复弹出；关闭浮窗不等于完成。重复浮窗恢复时最多补发一条，然后恢复下一次时刻。关闭 AnyWhere 期间不能显示浮窗。

Todo 示例在插件中选择方式、定义按钮和时间选择对话框：确认完成后保存 `done` 并移除提醒；推迟后保存新时间再登记，保持未完成。重复提醒的推迟会调整后续重复时刻，且不能跨过一个重复周期；插件在选择窗口明确说明。授权状态只影响 `system` 请求，`panel` 请求也须检查 `errors`。

## 数据与检查

服务元数据及文档位于 `PluginData/<packKey>/HostServices/<actionUUID>/`；不和页面普通 `storage` 键混用。保留数据卸载保留文件，明确清除数据才移除。已有 Finder 菜单和插件数据结构不迁移。

`OfficialPluginTests` 覆盖 UTF-8 跨块、取消保留旧草稿、越权拒绝、持久索引、安全 URL、真实 JSON 编辑器和 Todo 表单、关闭页面后的系统送达。通知测试用独立命名空间且不自动更改系统设置。三包逻辑另有可运行 Node 检查；JSON 包使用 lockfile 和预构建产物，普通导入不需要 npm。
