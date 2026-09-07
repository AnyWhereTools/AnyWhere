# AnyWhere 基础示例包

[English](README.md) · 简体中文 · [返回首页](../../README.zh.md)

这是符合 [AnyWhere 扩展包规范](../../docs/pack-spec.zh.md) 的参考包。可以复制此目录或 fork 仓库作为模板。它使用版本 1 清单演示基础功能，当前版本 3 客户端仍可导入。

| 动作 | `targets` / `utis` | 展示的能力 |
|------|--------------------|------------|
| 复制文件名（无扩展名） | `files` | 位置参数、`pbcopy`、stdout 摘要 |
| 统计所选大小 | `any` | 读取 `$@`、调用系统命令、首行摘要 |
| 转换图片为… | `files`、`public.image` | 通过 `variants.fixed` 和 `$ANYWHERE_VARIANT` 展开子菜单 |

## 使用

1. 在 AnyWhere →「扩展包 → 导入 → 选择本地文件夹…」中选择本目录，确认目录内有 `manifest.json`，无需创建 Git 仓库。
2. 也可以把此目录推送到独立的 Git 仓库，确保 `manifest.json` 位于根目录，再通过 URL 或 `owner/repo` 导入。
3. 逐个审阅脚本、确认导入，随后启用所需动作。

本地导入复制的是独立副本。源文件改动不会自动影响已安装动作；需要替换时先卸载，再从同一目录导入。相同来源不能重复导入。

## 增加配置和匹配规则

- **插件配置：**版本 2 或更高版本支持 `settings`，可声明文本、密码、开关和下拉选择。用户在动作详情保存配置，脚本读取 `ANYWHERE_CONFIG_<KEY>`。密码加密保存在应用本地目录，不访问钥匙串。
- **后缀与正则：**版本 3 支持普通后缀 `extensions`（忽略大小写）和完整文件名正则 `filenamePattern`（默认忽略大小写）。每个选中项须命中任一 UTI 或后缀，并额外满足正则；多选须全部符合。两个类型列表均为空则不限类型。
- **完整示例：**[Xlog Decoder 包](../xlog-decoder-pack/README.zh.md) 使用后缀匹配、可保存的私钥字段和包内独立 CLI，无需安装 XlogDecoder.app。

字段定义、版本要求和代码示例见[扩展包规范](../../docs/pack-spec.zh.md)。

## 社区发现

为 GitHub 仓库添加 topic **`anywhere-pack`**，即可通过 AnyWhere 的社区扩展包入口发现。
