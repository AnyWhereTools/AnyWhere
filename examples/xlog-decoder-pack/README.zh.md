# AnyWhere Xlog 解码扩展包

[English](README.md) · 简体中文 · [返回首页](../../README.zh.md)

符合 [AnyWhere 扩展包规范](../../docs/pack-spec.zh.md) 的 Finder 右键脚本。
附带独立 Rust 解码器 `bin/xlog-decoder`，无需安装 `XlogDecoder.app`，不附带私钥。
脚本按自身位置查找 CLI，移动时请保留 `actions/` 与 `bin/` 的目录结构。

CLI 从 XlogDecoder 1.3.1 提取，包含 Intel (`x86_64`) 和 Apple Silicon (`arm64`) 两种架构，
动态链接仅依赖 macOS 系统库，不依赖 Flutter 或 App 内的 Framework。

## 使用

1. 将整个扩展包目录保存到本机，保留 `bin/xlog-decoder` 的可执行权限。
2. 在 AnyWhere → **扩展包 → 导入 → 选择本地文件夹…** 中选择本目录（包含 `manifest.json`），审阅脚本及附带的 CLI，确认导入后启用「解密 Xlog」。无需创建 Git 仓库。
3. 在「右键菜单」中选中「解密 Xlog」，在右侧「插件配置」填写解密私钥并点击「保存配置」；未加密日志留空。之后在 Finder 选择 `.xlog` 文件执行，运行时不再弹出输入框。
4. 输出保存在各输入文件旁边：`sample.xlog` → `sample.log`；同名文件存在时生成 `sample 2.log`、`sample 3.log` 等。

也可以将本目录作为独立 Git 仓库发布（`manifest.json` 必须位于仓库根），
再按项目的扩展包流程通过仓库 URL 导入、审阅并启用动作。

本地导入会复制整个包，导入后移动原目录不影响执行；本地包不检查 Git 更新。
同一来源目录已安装时会拒绝重复导入，如需替换版本，请先卸载旧包再重新导入。

终端直接调用脚本时，需要自行提供配置环境变量（AnyWhere 运行时会自动注入）：

```sh
ANYWHERE_CONFIG_PRIVATE_KEY="<私钥>" /bin/zsh actions/decode-xlog.zsh "/absolute/path/sample.xlog"
```

也可以直接调用 CLI，不弹出输入框（未加密日志省略 `-p`）：

```sh
./bin/xlog-decoder decode -i "/absolute/path/sample.xlog" -o "/absolute/path/sample.log" -p "<私钥>"
```

直接调用 CLI 时不包含脚本提供的重名编号和输出检查。

更换私钥：在动作详情页的「插件配置」修改后保存，或使用「清除配置」。
从旧版升级时，请重新填写并保存一次私钥；新版不读取或删除原钥匙串条目，不触发钥匙串授权。
本包使用 schemaVersion 3，需要支持插件配置和后缀匹配的 AnyWhere 版本。

## 清单与配置

- `targets: "files"`、`extensions: ["xlog"]`：仅匹配文件，大小写不敏感，无需查询或填写动态 UTI。
- `settings` 中的 `PRIVATE_KEY` 使用 `password` 类型：界面显示为密码框，保存一次后自动读取；未加密日志可留空。
- 本包未设置 `filenamePattern`，因此不限制文件名前缀。若只处理特定命名，可在源清单的动作中增加
  `"filenamePattern": "device-.*\\.xlog"`，再重新导入；正则匹配完整文件名，默认忽略大小写。
- 配置与包文件独立保存。卸载后从同一来源重新导入可复用配置；若希望删除私钥，请先点击「清除配置」再卸载。

字段的组合关系、版本兼容和四种配置控件详见[扩展包规范](../../docs/pack-spec.zh.md)。

## 行为与边界

- 使用 `"$@"` 接收文件，支持空格、中文和多选；`.xlog` 扩展名不区分大小写。
- 菜单通过 `targets: files` 与 `extensions: ["xlog"]` 过滤，只有全部选中项均为 `.xlog` 文件时才显示，不依赖各台 Mac 的 UTI 注册情况。脚本执行前仍会校验整批输入是否可读。
- 私钥由 AnyWhere 使用 AES-256-GCM 加密到应用本地 `PrivateData/` 目录，按动作隔离，不使用钥匙串；脚本通过 `ANYWHERE_CONFIG_PRIVATE_KEY` 读取。私钥不写入扩展包或普通配置文件，执行输出中的原始私钥会被遮蔽。CLI 解码时仍通过 `-p` 参数传递。
- 本地备份须同时保留 `PrivateData/key` 和 `PrivateData/secrets.enc`；密文缺少密钥无法恢复。
- 临时目录和输出默认仅当前用户可读写；先写临时文件，非空且解码器退出成功后才保存为 `.log`，原始文件保持不变。
- 失败返回非零并写 stderr，批量中已成功的输出保留；成功时 stdout 首行提供结果摘要，整批处理超时为 600 秒。
- 不解析或重新实现解密算法，也不验证日志完整性；部分损坏日志能否恢复取决于包内解码器，非空输出不代表全部记录恢复成功。
