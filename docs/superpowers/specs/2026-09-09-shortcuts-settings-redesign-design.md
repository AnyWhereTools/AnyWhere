# 快捷指令设置页重设计

## 目标
将快捷指令页调整为与 AnyWhere 其他设置页一致的 macOS 原生设置风格。

## 范围
保留现有导航、数据模型、保存/启用/删除逻辑及脚本行为，仅调整 `ShortcutsScreen` 及其编辑区的 SwiftUI 视觉层级、间距、分组和控件样式。复用 `DesignSystem.swift` 中已有 token 与组件。

## 视觉结构
- 紧凑标题区：标题、说明、新建按钮统一对齐。
- 左侧列表：轻量选中态、动作图标、关键词和启用状态。
- 右侧编辑区：动作摘要行与名称、关键词、快捷键、执行目标分组；危险操作置于底部。
- 使用系统语义色、原生 Toggle/TextField/Picker 和现有 AWButton/AWColor。

## 验证
执行 `swift build` 或项目现有 macOS 构建命令，并检查 `git diff --check`。
