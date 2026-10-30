import Foundation
import CryptoKit

public struct PackCommand: Codable, Equatable, Sendable {
    public var description: String
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue?
    public var readOnly: Bool
}

public struct PackCommands: Codable, Equatable, Sendable {
    public var entry: String
    public var storageKeys: [String]
    public var operations: [String: PackCommand]
    public var reconcile: String?
    public var notification: String?

    public func validate() throws {
        guard PackManifest.isSafeRelativeScriptPath(entry), ["html", "htm"].contains(URL(fileURLWithPath: entry).pathExtension),
              !operations.isEmpty, operations.count <= 64, Set(storageKeys).count == storageKeys.count,
              storageKeys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.contains("\0") }) else {
            throw PluginError(.invalidArguments, "Invalid command declaration.")
        }
        for (name, command) in operations {
            guard Self.validName(name), !command.description.isEmpty else { throw PluginError(.invalidArguments, "Invalid command name or description.") }
            try PluginJSONSchema.check(command.inputSchema, objectRoot: true)
            if let output = command.outputSchema { try PluginJSONSchema.check(output) }
        }
        for name in [reconcile, notification].compactMap({ $0 }) where operations[name] == nil {
            throw PluginError(.invalidArguments, "Command handler is not declared: \(name)")
        }
    }
    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64 && name.range(of: "^[a-zA-Z][a-zA-Z0-9_-]*$", options: .regularExpression) != nil
    }
}

public struct PackMCP: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var commands: [String]

    public func validate(commands definition: PackCommands?) throws {
        guard PackCommands.validName(name), name != "list", !description.isEmpty, let definition,
              !commands.isEmpty, Set(commands).count == commands.count,
              commands.allSatisfy({ definition.operations[$0] != nil }) else {
            throw PluginError(.invalidArguments, "Invalid MCP export declaration.")
        }
    }
}

extension PackAction {
    /// Approval follows the complete declared surface, including private command changes.
    public var mcpApproval: String? {
        guard let mcp, let commands else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        struct Approval: Encodable { let mcp: PackMCP; let commands: PackCommands; let capabilities: [PluginCapability] }
        guard let data = try? encoder.encode(Approval(mcp: mcp, commands: commands, capabilities: capabilities)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public var mcpInputSchema: JSONValue? {
        guard let mcp, let commands else { return nil }
        return .object(["type": .string("object"), "oneOf": .array(mcp.commands.sorted().compactMap { name in
            guard let command = commands.operations[name] else { return nil }
            return .object(["type": .string("object"), "properties": .object([
                "operation": .object(["const": .string(name), "description": .string(command.description)]),
                "params": command.inputSchema]), "required": .array([.string("operation"), .string("params")]), "additionalProperties": .bool(false)])
        })])
    }
}

/// Deliberately bounded JSON Schema subset; unsupported keywords fail at import, never silently pass.
public enum PluginJSONSchema {
    private static let keywords: Set<String> = ["type", "properties", "required", "additionalProperties", "items", "enum", "const", "oneOf", "anyOf", "description", "title", "minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"]
    private static let types: Set<String> = ["object", "array", "string", "number", "integer", "boolean", "null"]
    public static func check(_ schema: JSONValue, objectRoot: Bool = false, depth: Int = 0) throws {
        guard depth < 20, let s = schema.object, Set(s.keys).isSubset(of: keywords),
              !objectRoot || s["type"] == .string("object") else { throw invalid("Unsupported JSON Schema.") }
        if let type = s["type"] {
            let names = type.string.map { [$0] } ?? type.array?.compactMap(\.string) ?? []
            guard !names.isEmpty, names.allSatisfy({ types.contains($0) }), type.string != nil || type.array?.count == names.count else { throw invalid("Invalid schema type.") }
        }
        if let properties = s["properties"] {
            guard let properties = properties.object else { throw invalid("Invalid properties.") }
            for value in properties.values { try check(value, depth: depth + 1) }
        }
        if let required = s["required"] {
            guard let names = required.array, names.allSatisfy({ $0.string != nil }), Set(names.compactMap(\.string)).count == names.count else { throw invalid("Invalid required fields.") }
        }
        if let additional = s["additionalProperties"], additional != .bool(true), additional != .bool(false) { throw invalid("additionalProperties must be boolean.") }
        if let items = s["items"] { try check(items, depth: depth + 1) }
        if let values = s["enum"], values.array?.isEmpty != false { throw invalid("Invalid enum.") }
        for key in ["oneOf", "anyOf"] {
            if let branch = s[key] {
                guard let branches = branch.array, !branches.isEmpty else { throw invalid("Invalid schema branches.") }
                for value in branches { try check(value, depth: depth + 1) }
            }
        }
        for key in ["minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"] {
            if let value = s[key], value.number == nil { throw invalid("Invalid schema limit.") }
            if let number = s[key]?.number, !["minimum", "maximum"].contains(key), number < 0 || number.rounded() != number { throw invalid("Schema sizes must be non-negative integers.") }
        }
    }
    public static func validate(_ value: JSONValue, schema: JSONValue, depth: Int = 0) throws {
        guard depth < 24, let s = schema.object else { throw invalid("Invalid schema.") }
        if let expected = s["const"], value != expected { throw invalid("Value does not match const.") }
        if let choices = s["enum"]?.array, !choices.contains(value) { throw invalid("Value is not in enum.") }
        if let type = s["type"] {
            let names = type.string.map { [$0] } ?? type.array?.compactMap(\.string) ?? []
            guard names.contains(where: { matches(value, type: $0) }) else { throw invalid("Incorrect value type.") }
        }
        for key in ["oneOf", "anyOf"] {
            if let branches = s[key]?.array {
                let matched = branches.filter { (try? validate(value, schema: $0, depth: depth + 1)) != nil }.count
                guard key == "oneOf" ? matched == 1 : matched > 0 else { throw invalid("Value does not match schema branches.") }
            }
        }
        if let object = value.object {
            let properties = s["properties"]?.object ?? [:]
            for name in s["required"]?.array?.compactMap(\.string) ?? [] where object[name] == nil { throw invalid("Missing field: \(name)") }
            if s["additionalProperties"] == .bool(false), !Set(object.keys).isSubset(of: Set(properties.keys)) { throw invalid("Unexpected field.") }
            for (name, field) in object { if let schema = properties[name] { try validate(field, schema: schema, depth: depth + 1) } }
        }
        if let array = value.array {
            try range(Double(array.count), minimum: s["minItems"]?.number, maximum: s["maxItems"]?.number)
            if let items = s["items"] { for item in array { try validate(item, schema: items, depth: depth + 1) } }
        }
        if let string = value.string { try range(Double(string.unicodeScalars.count), minimum: s["minLength"]?.number, maximum: s["maxLength"]?.number) }
        if let number = value.number { try range(number, minimum: s["minimum"]?.number, maximum: s["maximum"]?.number) }
    }
    private static func range(_ value: Double, minimum: Double?, maximum: Double?) throws {
        guard value.isFinite, minimum.map({ value >= $0 }) ?? true, maximum.map({ value <= $0 }) ?? true else { throw invalid("Value is outside schema limits.") }
    }
    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (value, type) {
        case (.object, "object"), (.array, "array"), (.string, "string"), (.bool, "boolean"), (.null, "null"), (.number, "number"): return true
        case (.number(let n), "integer"): return n.isFinite && n.rounded() == n
        default: return false
        }
    }
    private static func invalid(_ message: String) -> PluginError { PluginError(.invalidArguments, message) }
}

extension JSONValue {
    public var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var number: Double? { if case .number(let value) = self { return value }; return nil }
    public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
