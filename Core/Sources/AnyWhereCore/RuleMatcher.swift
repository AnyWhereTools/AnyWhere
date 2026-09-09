import Foundation
import UniformTypeIdentifiers

public enum MatchContext {
    case items([URL])
    case container(URL)
}

public enum RuleMatcher {
    public static func visibleActions(in config: MenuConfig, context: MatchContext) -> [MenuAction] {
        config.actions
            .filter { $0.isEnabled && matches(rule: $0.matching, context: context) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    public static func matches(rule: MatchRule, context: MatchContext) -> Bool {
        switch context {
        case .container:
            return rule.targets == .container || rule.targets == .foldersAndContainer
        case .items(let urls):
            guard rule.targets != .container, !urls.isEmpty else { return false }
            if let max = rule.maxSelectionCount, urls.count > max { return false }
            if let min = rule.minSelectionCount, urls.count < min { return false }
            guard rule.extensions.allSatisfy(MatchRule.isValidExtension) else { return false }
            let pattern: NSRegularExpression?
            if let source = rule.filenamePattern {
                guard !source.isEmpty, let compiled = try? filenameRegex(source) else { return false }
                pattern = compiled
            } else {
                pattern = nil
            }
            return urls.allSatisfy { matches(rule: rule, url: $0, pattern: pattern) }
        }
    }

    /// Wrap the expression so alternatives and unanchored patterns still match the whole basename.
    static func filenameRegex(_ source: String) throws -> NSRegularExpression {
        try NSRegularExpression(pattern: "\\A(?:" + source + ")\\z", options: [.caseInsensitive])
    }

    private static func matches(rule: MatchRule, url: URL, pattern: NSRegularExpression?) -> Bool {
        var isDirObjC: ObjCBool = false
        // fileExists 在 FinderSync 沙盒内可用：扩展监控 "/"，系统授予被监控路径的 stat 权限。
        // 若失败（实践中不可达）isDir 退化为 false → .folders 规则隐藏该项，安全降级。
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirObjC)
        let isDir = isDirObjC.boolValue
        switch rule.targets {
        case .files: if isDir { return false }
        case .folders, .foldersAndContainer: if !isDir { return false }
        case .any, .container: break  // .container 在上层 guard 已拦截，此处仅为穷举
        }
        if let pattern {
            let name = url.lastPathComponent
            guard pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else { return false }
        }
        guard !rule.utis.isEmpty || !rule.extensions.isEmpty else { return true }
        if !isDir {
            let name = url.lastPathComponent.lowercased()
            if rule.extensions.contains(where: {
                let suffix = "." + MatchRule.normalizedExtension($0)
                return name.count > suffix.count && name.hasSuffix(suffix)
            }) { return true }
        }
        let type: UTType? = isDir ? .folder : UTType(filenameExtension: url.pathExtension)
        guard let type else { return false }
        return rule.utis.contains { uti in UTType(uti).map(type.conforms(to:)) ?? false }
    }
}
