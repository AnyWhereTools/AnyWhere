import Foundation

/// Market categories are derived from the entries in a pack so legacy manifests remain valid.
public enum PackType: String, Codable, CaseIterable, Sendable { case finder, tool, workflow }

/// 扩展包清单(`manifest.json`,位于仓库根)。
///
/// 解析策略:
/// - 未知字段一律忽略(向后兼容,允许仓库声明未来字段)。
/// - 缺省值在 decode 阶段填充:pack icon → "shippingbox";action icon → "bolt";
///   author/description nil;utis nil → [];timeoutSeconds nil → 60;placement 缺省 topLevel。
/// - `decode` 只解析不校验;`validate()` 做语义校验(schemaVersion 不超前、name/actions 非空、
///   每个 action 字段合法、脚本路径限定仓库内相对路径)。
public struct PackManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 4

    public var schemaVersion: Int
    public var name: String          // 包名(显示)
    public var author: String?
    public var description: String?
    public var icon: String          // SF Symbol 名,默认 shippingbox
    public var actions: [PackAction]
    public var uiApiVersion: Int?

    /// Composable market categories. Workflow is reserved for the workflow declaration added later.
    public var types: Set<PackType> {
        var result = Set<PackType>()
        if actions.contains(where: { $0.contextMenu }) { result.insert(.finder) }
        if actions.contains(where: { $0.launcher != nil || $0.ui != nil }) { result.insert(.tool) }
        return result
    }

    public init(schemaVersion: Int, name: String, author: String? = nil,
                description: String? = nil, icon: String = "shippingbox",
                actions: [PackAction], uiApiVersion: Int? = nil) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.author = author
        self.description = description
        self.icon = icon
        self.actions = actions
        self.uiApiVersion = uiApiVersion
    }

    // MARK: Codable (custom: fill defaults, ignore unknown keys)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, name, author, description, icon, actions, uiApiVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.author = try c.decodeIfPresent(String.self, forKey: .author)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "shippingbox"
        self.actions = try c.decodeIfPresent([PackAction].self, forKey: .actions) ?? []
        self.uiApiVersion = try c.decodeIfPresent(Int.self, forKey: .uiApiVersion)
    }

    // MARK: Decode entry point

    public enum DecodeError: Error, Sendable { case notJSON(String) }

    public static func decode(_ data: Data) throws -> PackManifest {
        do {
            return try JSONDecoder().decode(PackManifest.self, from: data)
        } catch let e as DecodingError {
            throw DecodeError.notJSON("\(e)")
        }
    }

    // MARK: Validation

    public enum ValidationError: Error, Equatable, Sendable {
        case incompatibleSchema(found: Int)
        case emptyName
        case emptyActions
        case duplicateActionID(String)
        case emptyActionID
        case emptyActionTitle(id: String)
        case invalidScriptPath(id: String, path: String)
        case matchingRequiresSchema3(id: String)
        case invalidExtension(id: String, value: String)
        case invalidFilenamePattern(id: String)
        case fileFilterOnContainer(id: String)
        case invalidUI(id: String)
    }

    public func validate() throws {
        if schemaVersion > Self.currentSchemaVersion {
            throw ValidationError.incompatibleSchema(found: schemaVersion)
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.emptyName
        }
        if actions.isEmpty { throw ValidationError.emptyActions }

        var seen = Set<String>()
        for action in actions {
            let id = action.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { throw ValidationError.emptyActionID }
            if !seen.insert(id).inserted { throw ValidationError.duplicateActionID(id) }
            if action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError.emptyActionTitle(id: id)
            }
            if let script = action.script {
                guard Self.isSafeRelativeScriptPath(script) else {
                    throw ValidationError.invalidScriptPath(id: id, path: script)
                }
            } else if action.ui == nil {
                throw ValidationError.invalidScriptPath(id: id, path: "")
            }
            if action.ui != nil || action.launcher != nil || !action.contextMenu || !action.capabilities.isEmpty || uiApiVersion != nil {
                guard schemaVersion >= 4 else { throw ValidationError.invalidUI(id: id) }
            }
            if let ui = action.ui {
                guard uiApiVersion == 1, Self.isSafeRelativeScriptPath(ui.entry),
                      ui.height.map({ $0 > 0 }) ?? true else { throw ValidationError.invalidUI(id: id) }
            }
            guard (uiApiVersion == nil || uiApiVersion == 1),
                  action.contextMenu || action.launcher != nil,
                  !action.capabilities.contains(.runTask) || action.script != nil else {
                throw ValidationError.invalidUI(id: id)
            }
            if let keywords = action.launcher?.keywords {
                let normalized = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                guard normalized.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
                      Set(normalized).count == keywords.count else { throw ValidationError.invalidUI(id: id) }
            }
            try PackSettings.validate(action.settings)
            if !action.extensions.isEmpty || action.filenamePattern != nil {
                guard schemaVersion >= 3 else { throw ValidationError.matchingRequiresSchema3(id: id) }
                guard action.targets != .container else { throw ValidationError.fileFilterOnContainer(id: id) }
            }
            for suffix in action.extensions where !MatchRule.isValidExtension(suffix) {
                throw ValidationError.invalidExtension(id: id, value: suffix)
            }
            if let pattern = action.filenamePattern {
                guard !pattern.isEmpty, (try? RuleMatcher.filenameRegex(pattern)) != nil else {
                    throw ValidationError.invalidFilenamePattern(id: id)
                }
            }
        }
    }

    /// 仅允许仓库内相对路径:非空、不以 `/` 开头(绝对路径)、任何路径段都不是 `..`。
    /// 单独的 `.` 段无害(stdlib 解析时折叠),但 `..` 一律拒绝以防越界。
    static func isSafeRelativeScriptPath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        guard !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        for seg in segments where seg == ".." { return false }
        return true
    }
}

/// 包内单个动作声明。`targets`/`placement`/`variants` 复用 Models 里既有的 Codable 类型。
public struct PackAction: Codable, Equatable, Sendable {
    public var id: String            // 包内稳定标识(更新时按它匹配)
    public var title: String
    public var icon: String          // SF Symbol,默认 bolt
    public var script: String?       // 纯 UI 动作无需脚本
    public var ui: PackUI?
    public var launcher: PackLauncher?
    public var contextMenu: Bool
    public var capabilities: [PluginCapability]
    public var targets: TargetKind
    public var utis: [String]        // nil → []
    public var extensions: [String]
    public var filenamePattern: String?
    public var matching: MatchRule {
        MatchRule(targets: targets, utis: utis, extensions: extensions, filenamePattern: filenamePattern)
    }
    public var placement: Placement  // 缺省 topLevel
    public var variants: VariantSource?
    public var timeoutSeconds: Int   // nil → 60
    public var settings: [PackSetting]

    public init(id: String, title: String, icon: String = "bolt", script: String? = nil,
                targets: TargetKind = .any, utis: [String] = [],
                extensions: [String] = [], filenamePattern: String? = nil,
                placement: Placement = .topLevel, variants: VariantSource? = nil,
                timeoutSeconds: Int = 60, settings: [PackSetting] = [],
                ui: PackUI? = nil, launcher: PackLauncher? = nil, contextMenu: Bool = true,
                capabilities: [PluginCapability] = []) {
        self.id = id
        self.title = title
        self.icon = icon
        self.script = script
        self.ui = ui; self.launcher = launcher; self.contextMenu = contextMenu; self.capabilities = capabilities
        self.targets = targets
        self.utis = utis
        self.extensions = extensions
        self.filenamePattern = filenamePattern
        self.placement = placement
        self.variants = variants
        self.timeoutSeconds = timeoutSeconds
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, icon, script, targets, utis, extensions, filenamePattern, placement, variants, timeoutSeconds, settings
        case ui, launcher, contextMenu, capabilities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "bolt"
        self.script = try c.decodeIfPresent(String.self, forKey: .script)
        self.ui = try c.decodeIfPresent(PackUI.self, forKey: .ui)
        self.launcher = try c.decodeIfPresent(PackLauncher.self, forKey: .launcher)
        self.contextMenu = try c.decodeIfPresent(Bool.self, forKey: .contextMenu) ?? true
        self.capabilities = try c.decodeIfPresent([PluginCapability].self, forKey: .capabilities) ?? []
        self.targets = try c.decodeIfPresent(TargetKind.self, forKey: .targets) ?? .any
        self.utis = try c.decodeIfPresent([String].self, forKey: .utis) ?? []
        self.extensions = try c.decodeIfPresent([String].self, forKey: .extensions) ?? []
        self.filenamePattern = try c.decodeIfPresent(String.self, forKey: .filenamePattern)
        self.placement = try c.decodeIfPresent(Placement.self, forKey: .placement) ?? .topLevel
        self.variants = try c.decodeIfPresent(ManifestVariant.self, forKey: .variants)?.source
        self.timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60
        self.settings = try c.decodeIfPresent([PackSetting].self, forKey: .settings) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(icon, forKey: .icon)
        try c.encodeIfPresent(script, forKey: .script)
        try c.encodeIfPresent(ui, forKey: .ui)
        try c.encodeIfPresent(launcher, forKey: .launcher)
        if !contextMenu { try c.encode(contextMenu, forKey: .contextMenu) }
        if !capabilities.isEmpty { try c.encode(capabilities, forKey: .capabilities) }
        try c.encode(targets, forKey: .targets)
        try c.encode(utis, forKey: .utis)
        if !extensions.isEmpty { try c.encode(extensions, forKey: .extensions) }
        try c.encodeIfPresent(filenamePattern, forKey: .filenamePattern)
        try c.encode(placement, forKey: .placement)
        try c.encodeIfPresent(variants.map(ManifestVariant.init), forKey: .variants)
        try c.encode(timeoutSeconds, forKey: .timeoutSeconds)
        if !settings.isEmpty { try c.encode(settings, forKey: .settings) }
    }
}

/// Human-authored variant shape in `manifest.json`:
///   `"variants": { "fixed": ["png", "jpeg"] }`
///   `"variants": { "directoryListing": "templates" }`
/// This bridges to Models' `VariantSource` (whose synthesized Codable uses an
/// `_0` wrapper that we deliberately do NOT expose in the manifest format).
struct ManifestVariant: Codable, Equatable {
    let source: VariantSource

    init(_ source: VariantSource) { self.source = source }

    private enum CodingKeys: String, CodingKey { case fixed, directoryListing }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try c.decodeIfPresent([String].self, forKey: .fixed) {
            source = .fixed(list)
        } else if let dir = try c.decodeIfPresent(String.self, forKey: .directoryListing) {
            source = .directoryListing(dir)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "variants must be {fixed:[...]} or {directoryListing:\"...\"}"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch source {
        case .fixed(let list): try c.encode(list, forKey: .fixed)
        case .directoryListing(let dir): try c.encode(dir, forKey: .directoryListing)
        }
    }
}
