# Text Toolbox example pack

[简体中文](README.zh.md) · [UI developer guide](../../docs/plugin-ui.md)

Import this folder, review its page, script and additional files, then enable the **Search** switch for “文本工具”. Press `Control+Option+Space`, enter `text hello`, and press Return. The page receives `hello` as its argument.

The page demonstrates uppercase conversion, clipboard writes, a persistent draft and a cancellable five-second backend task with output events. The task prints demo input; production plugins should not log request contents by default. No Node.js or external dependency is required.

A second action, “查看调用上下文”, has only a UI and no script. Enable its `context` search entry and/or its `.txt` Finder context-menu entry independently to inspect the invocation snapshot.

Set the output prefix in the pack's configuration form. Enable developer mode in General settings to review and reload the source folder. Reload Page only recreates the installed page's session; it does not copy source changes. Web Inspector is available in developer mode.
