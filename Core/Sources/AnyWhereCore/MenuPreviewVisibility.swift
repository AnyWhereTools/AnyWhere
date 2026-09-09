import Foundation

/// 模拟右键对象（设置窗「右键菜单 Hub」左栏的预览过滤维度）。
/// 与 RuleMatcher 不同：RuleMatcher 查真实文件系统判可见性，
/// 这是**纯函数**预览逻辑，按 targets/utis/extensions 粗判，不触磁盘。
/// 正则需要真实文件名，分类预览不据此排除动作。
public enum SimContext: String, CaseIterable, Sendable {
    case image    // 图片
    case file     // 普通文件
    case folder   // 文件夹
    case empty    // 目录空白处
}

public enum MenuPreviewVisibility {
    /// 已知图片类 UTI 前缀/标识（粗判用，不做 UTType.conforms 真实判定）。
    private static let imageUTIs: Set<String> = [
        "public.image", "public.png", "public.jpeg", "public.heic",
        "public.heif", "public.tiff", "com.compuserve.gif", "public.camera-raw-image",
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp", "svg", "avif", "ico", "raw",
    ]

    /// 某条动作在给定模拟对象下是否出现于预览菜单。
    ///
    /// - image: targets ∈ {files, any} 且（utis 为空 或 含图片类）
    /// - file:  targets ∈ {files, any} 且（utis 为空 或 不专属图片）
    /// - folder: targets ∈ {folders, any, foldersAndContainer}
    /// - empty: targets ∈ {container, foldersAndContainer}
    public static func isVisible(_ rule: MatchRule, in context: SimContext) -> Bool {
        switch context {
        case .image:
            guard rule.targets == .files || rule.targets == .any else { return false }
            return (rule.utis.isEmpty && rule.extensions.isEmpty) || hasImageUTI(rule.utis)
                || rule.extensions.contains { imageExtensions.contains(MatchRule.normalizedExtension($0)) }
        case .file:
            guard rule.targets == .files || rule.targets == .any else { return false }
            // 限定了 UTI 且**全部**是图片类 → 专属图片，普通文件下不显示。
            let hasFilters = !rule.utis.isEmpty || !rule.extensions.isEmpty
            let onlyImages = rule.utis.allSatisfy { imageUTIs.contains($0.lowercased()) }
                && rule.extensions.allSatisfy { imageExtensions.contains(MatchRule.normalizedExtension($0)) }
            return !hasFilters || !onlyImages
        case .folder:
            return (rule.targets == .folders || rule.targets == .any || rule.targets == .foldersAndContainer)
                && (rule.extensions.isEmpty || !rule.utis.isEmpty)
        case .empty:
            return rule.targets == .container || rule.targets == .foldersAndContainer
        }
    }

    /// 便捷重载：直接传 MenuAction。
    public static func isVisible(_ action: MenuAction, in context: SimContext) -> Bool {
        isVisible(action.matching, in: context)
    }

    /// utis 中是否含至少一个图片类。
    private static func hasImageUTI(_ utis: [String]) -> Bool {
        utis.contains { imageUTIs.contains($0.lowercased()) }
    }

}
