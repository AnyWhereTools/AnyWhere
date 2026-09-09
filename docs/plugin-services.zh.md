# 插件宿主服务：文件、动态搜索与提醒

[English](plugin-services.md) · [完整类型](sdk/anywhere.d.ts) · [UI SDK](plugin-ui.zh.md)

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

单次过去时间不重新补发；重复按本地时刻/星期取下一次匹配。每条系统请求用宿主来源身份隔离，修改同 ID 替换，完成/删除移除。相同提醒同步不会清除用户尚未处理的已送达通知。插件不能取消其他来源的提醒。停用入口、删除动作、权限移除或卸载会撤销对应系统通知；保留数据后重新启用会恢复仍有效的调度。

首次有提醒且尚未确定授权时调用系统授权；禁止时返回状态，界面必须说明任务已保存但没有通知。检查 `replace` 的 `{authorization,errors}`，不要把持久化成功误认为送达成功。通知由 macOS 调度，关闭 WebView 无需保持脚本或页面计时器。

点击通知时宿主验证来源仍安装且启用，然后打开动作，并将待办 ID 放入 `invocation.argument`。冷启动等待扩展包加载；已有面板通过 `onEnter` 再次接收上下文，独立窗口直接聚焦。不要只在页面初始化时读取一次上下文。

## 数据与检查

服务元数据及文档位于 `PluginData/<packKey>/HostServices/<actionUUID>/`；不和页面普通 `storage` 键混用。保留数据卸载保留文件，明确清除数据才移除。已有 Finder 菜单和插件数据结构不迁移。

`OfficialPluginTests` 覆盖 UTF-8 跨块、取消保留旧草稿、越权拒绝、持久索引、安全 URL、真实 JSON 编辑器和 Todo 表单、关闭页面后的系统送达。通知测试用独立命名空间且不自动更改系统设置。三包逻辑另有可运行 Node 检查；JSON 包使用 lockfile 和预构建产物，普通导入不需要 npm。
