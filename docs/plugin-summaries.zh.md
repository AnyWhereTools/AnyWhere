# 搜索首页摘要

[开发者文档](README.zh.md) · [UI SDK](plugin-ui.zh.md)

插件根目录增加 `summary.html` 即可支持摘要，不需要修改 manifest 或增加构建配置。已有插件不受影响。

用户启用插件后，可以在「扩展包 → 选中插件 → 搜索面板」中开启「固定摘要」，或在搜索结果上右键选择「固定到搜索首页」。默认不固定。取消固定可使用同一入口，也可右键摘要。点击整条摘要打开完整工具。

首页最近使用最多三项；每个插件摘要固定为 64 点高。摘要区最多显示三条的高度，更多已固定插件可滚动查看。输入搜索词时隐藏摘要。每个包只有一条摘要，点击打开该包第一个已启用的 UI 工具。停用会隐藏摘要但保留固定选择，卸载会清除选择。

## 最小示例

```html
<!doctype html>
<meta charset="utf-8">
<p id="text">读取中…</p>
<script>
  (async () => {
    const value = await anywhere.storage.get('message');
    document.getElementById('text').textContent = value || '暂无信息';
  })();
</script>
```

宿主自动注入 `anywhere.storage.get(key)`，键和值与完整插件一致，范围限定当前扩展包。摘要不支持写存储、网络请求、运行任务、剪贴板、通知、弹窗或导航。请使用 `textContent` 显示用户数据。

默认提供透明背景、系统字体、文字颜色、基础间距和明暗主题，以及 CSS 变量 `--text`、`--muted`、`--accent`、`--separator`。可使用普通 HTML/CSS 自行布局，或相对路径引用包内 CSS/JS。插件不需要配置 iframe。单个资源和一次数据读取均限制 1 MiB，勿加载完整编辑器或大型依赖。

每次唤起搜索、返回搜索或通过完整插件的 storage API 修改数据时，宿主重新加载摘要。页面重新读取数据即可，不需要轮询或注册刷新事件。主题变化由 `prefers-color-scheme` 自动适配。读取错误和 JavaScript 错误显示简短提示，不修改原数据。

摘要以静态信息为主：不放输入框、滚动容器或操作按钮，超出 64 点的内容会被裁切。可通过标题、短列表、数字或标签展示最紧要的信息。Todo 示例复用 `logic.js` 的排序和旧数据读取逻辑，展示前三项未完成待办，超过三项提示剩余数量。

## 宿主实现

搜索和最近使用保持原生。一个 WKWebView 内使用不同随机来源的沙箱 iframe 隔离各插件；原生侧根据真实 frame 来源核对包身份，不能由消息指定其他包。隐藏面板或进入完整工具时销毁摘要 WebView。iframe 仍有独立文档开销，不能将一个 WebView 等同于一个 WebContent 进程。
