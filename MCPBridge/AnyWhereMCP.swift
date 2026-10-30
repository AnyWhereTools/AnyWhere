import Foundation
import MCP
import AnyWhereCore

private actor ToolCatalog {
    private var signature: Data?
    func observe(_ tools: [Tool]) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let next = try? encoder.encode(tools)
        let changed = signature != nil && signature != next
        signature = next
        return changed
    }
}

@main
struct AnyWhereMCP {
    static func request(_ value: JSONValue) async throws -> JSONValue {
        let path = ProcessInfo.processInfo.environment["ANYWHERE_MCP_SOCKET_PATH"] ?? LocalCommandSocket.path
        return try await Task.detached { try LocalCommandSocket.request(value, path: path) }.value
    }
    static func convert<T: Encodable>(_ value: T) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
    static let listTool = Tool(name: "list", description: "List registered and authorized AnyWhere plugins. Supply plugin to get its operation schemas.",
        inputSchema: .object(["type": .string("object"), "properties": .object(["plugin": .object(["type": .string("string")])]), "additionalProperties": .bool(false)]),
        annotations: .init(readOnlyHint: true))

    static func tools() async throws -> [Tool] {
        let response = try await request(.object(["method": .string("tools")]))
        guard let definitions = response.object?["result"]?.array else { throw PluginError(.failed, "AnyWhere tool registry is unavailable.") }
        return try [listTool] + definitions.map { value in
            guard let object = value.object, let name = object["name"]?.string,
                  let description = object["description"]?.string, let schema = object["inputSchema"] else {
                throw PluginError(.failed, "Invalid tool registry response.")
            }
            return Tool(name: name, description: description, inputSchema: try convert(schema),
                        annotations: .init(readOnlyHint: object["readOnly"] == .bool(true)))
        }
    }
    static func main() async throws {
        let server = Server(name: "anywhere", version: "1.0.0", capabilities: .init(tools: .init(listChanged: true)))
        let catalog = ToolCatalog()
        await server.withMethodHandler(ListTools.self) { _ in
            let snapshot = (try? await tools()) ?? [listTool]
            _ = await catalog.observe(snapshot)
            return .init(tools: snapshot)
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let arguments = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(params.arguments ?? [:]))
                let reply = try await request(.object(["method": .string("call"), "name": .string(params.name), "arguments": arguments]))
                let failed = reply.object?["error"] != nil
                let value = reply.object?[failed ? "error" : "result"] ?? .null
                let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                let structured: JSONValue = value.object == nil ? .object(["result": value]) : value
                return try .init(content: [.text(text: text)], structuredContent: convert(structured), isError: failed)
            } catch {
                return .init(content: [.text(text: error.localizedDescription)], isError: true)
            }
        }
        try await server.start(transport: StdioTransport())
        let monitor = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let snapshot = (try? await tools()) ?? [listTool]
                if await catalog.observe(snapshot) { try? await server.notify(ToolListChangedNotification.message()) }
            }
        }
        await server.waitUntilCompleted()
        monitor.cancel()
    }
}
