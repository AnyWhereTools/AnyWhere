# 参与 AnyWhere 开发

[English](CONTRIBUTING.md) · 简体中文 · [返回首页](README.zh.md)

AnyWhere 由 SwiftUI 菜单栏应用、Finder Sync 扩展和共享的 Swift Package 组成。

## 开发环境

要求 macOS 13+、Xcode 15+（支持 String Catalog）以及 Homebrew（用于安装 `xcodegen`）。

```bash
make bootstrap   # 安装 xcodegen，从模板创建 Local.xcconfig
make gen         # 从 project.yml 生成 AnyWhere.xcodeproj
make test        # 运行 AnyWhereCore 单元测试
make build       # 使用 xcodebuild 构建 Debug 版本
make run         # 构建并启动应用
```

`Local.xcconfig` 保存本机签名配置，已被 Git 忽略，不要提交。生成的 `AnyWhere.xcodeproj` 和 `build/` 同样不提交；工程配置应修改 `project.yml`。

## 架构

| Target | 形态 | 沙盒 | 职责 |
|--------|------|------|------|
| **AnyWhere** | SwiftUI 菜单栏应用（`LSUIElement`）及设置窗口 | 否 | 配置编辑、动作执行、系统菜单管理、心跳 |
| **FinderExtension** | `FIFinderSync` 扩展 | 是 | 绘制右键菜单、转发点击 |
| **AnyWhereCore** | 本地 Swift Package | — | 数据模型、配置编解码、规则匹配与存储，通过单元测试验证 |

扩展不读取应用配置和脚本文件，主应用通过 `DistributedNotificationCenter` 分块推送菜单快照；没有 App Group 容器。把共享逻辑和测试放在 **AnyWhereCore**，让扩展保持精简。

## 测试

提交前确保 `make test` 通过，Core 测试放在 `Core/Tests/AnyWhereCoreTests/`。测试不应依赖用户语言，应按 `presetKey` 查找预设，不要按本地化标题查找。

预设脚本修改可运行 `make test-presets`。只有 Core 测试无法发现 App 或扩展的编译问题，因此提交 PR 前还应运行 `make build`。存储测试使用临时目录，不使用用户真实密码或数据。

## 国际化

界面使用 **String Catalog** 和**抽象 key**，源语言是英语：

- 代码中使用 `String(localized: "general.launchAtLogin")`。自定义组件接收 `String` 时要显式本地化，SwiftUI 不会自动翻译普通 `String` 值。插值采用 `String(format: String(localized: "key"), args…)`。
- 翻译分别位于主应用的 `App/Localizable.xcstrings`、共享模块的 `Core/Sources/AnyWhereCore/Localizable.xcstrings` 和扩展的 `FinderExtension/Localizable.xcstrings`。
- 新增语言时，在 Xcode 中打开对应 `.xcstrings`，添加语言并翻译 key。不要新增直接以英文句子为 key 的条目，也不要硬编码界面文案。

用户文档也按语言配对维护：默认 `.md` 为英文，`.zh.md` 为简体中文；中文页面的站内文档链接应指向中文版，顶部提供语言切换。更新扩展包功能时，同步[扩展包规范](docs/pack-spec.zh.md)和示例说明。

## 新增内置预设

开发自定义插件时，从[文本工具示例](examples/ui-tool-pack/README.zh.md)开始；API、资源限制和调试方式见[中文 UI 文档](docs/plugin-ui.zh.md)。宿主集成测试由 XcodeGen 的 `AnyWhereTests` 目标提供，可运行 `xcodebuild -project AnyWhere.xcodeproj -scheme AnyWhere -destination 'platform=macOS' test`；首次先运行 `make gen`。Core 单测与现有预设测试仍分别使用 `make test`、`make test-presets`。

1. 在 `App/PresetScripts/` 添加 zsh 脚本，遵循[脚本环境契约](docs/pack-spec.zh.md#script-environment-contract)。
2. 在 `Core/Sources/AnyWhereCore/Models.swift` 的 `MenuConfig.defaultSeed()` 中注册，使用稳定的 `presetKey` 和抽象标题 key，并补齐 Core 中英文翻译。
3. 按需更新 `ModelsTests`、`IPCTests` 中与预设数量有关的断言。

初始化逻辑会升级未修改过的预设脚本、补入新预设，同时保留用户编辑。已删除的预设通过 `UserDefaults` 中的删除标记保持删除状态。

## 提交与 Pull Request

- 从 `main` 创建分支，每次提交保持聚焦，标题清楚描述改动。
- 打开 PR 前运行 `make test` 和 `make build`。
- 说明改了什么、如何验证；界面改动可附截图。

提交贡献即表示同意按项目的 [MIT 许可证](LICENSE) 授权这些贡献。
