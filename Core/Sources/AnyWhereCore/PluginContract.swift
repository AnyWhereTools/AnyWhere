import Foundation

public struct PackUI: Codable, Equatable, Sendable {
    public var entry: String
    public var height: Int?
    public init(entry: String, height: Int? = nil) { self.entry = entry; self.height = height }
}

public struct PackLauncher: Codable, Equatable, Sendable {
    public var keywords: [String]
    public init(keywords: [String] = []) { self.keywords = keywords }
    private enum CodingKeys: CodingKey { case keywords }
    public init(from decoder: Decoder) throws {
        keywords = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([String].self, forKey: .keywords) ?? []
    }
}

public enum PluginCapability: String, Codable, Sendable {
    case runTask = "task.run", writeClipboard = "clipboard.write"
}

public enum PluginActionIdentity {
    public static func uuid(packKey: String, actionID: String) -> UUID {
        UUID.deterministic("pack.\(packKey).\(actionID)")
    }
}

public struct PluginInvocation: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case launcher, finder }
    public let apiVersion: Int
    public let invocationID: UUID
    public let actionID: UUID
    public let source: Source
    public let query: String
    public let argument: String
    public let paths: [String]
    public let variant: String?
    public let finderPath: String
    private enum CodingKeys: String, CodingKey { case apiVersion, invocationID, actionID, source, query, argument, paths, variant, finderPath }
    public init(actionID: UUID, source: Source, query: String = "", argument: String = "",
                paths: [String] = [], variant: String? = nil,
                finderPath: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        apiVersion = 1; invocationID = UUID(); self.actionID = actionID; self.source = source
        self.query = query; self.argument = argument; self.paths = paths; self.variant = variant; self.finderPath = finderPath
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try c.decode(Int.self, forKey: .apiVersion)
        invocationID = try c.decode(UUID.self, forKey: .invocationID)
        actionID = try c.decode(UUID.self, forKey: .actionID)
        source = try c.decode(Source.self, forKey: .source)
        query = try c.decode(String.self, forKey: .query)
        argument = try c.decode(String.self, forKey: .argument)
        paths = try c.decode([String].self, forKey: .paths)
        variant = try c.decodeIfPresent(String.self, forKey: .variant)
        finderPath = try c.decodeIfPresent(String.self, forKey: .finderPath)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
}

public struct PluginError: Error, LocalizedError, Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case invalidArguments, denied, sessionClosed, busy, failed, timedOut, cancelled, outputLimit, storageLimit
    }
    public let code: Code
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
}
