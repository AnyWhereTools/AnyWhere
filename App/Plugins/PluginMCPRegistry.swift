import Foundation
import AnyWhereCore

@MainActor
final class PluginMCPRegistry {
    static let shared = PluginMCPRegistry()
    private var entries: [PluginLauncherEntry] = []
    private var preferences = PluginPreferencesStore(directory: AppPaths.configDirectory())
    private let server: LocalCommandServer
    init(socketPath: String = LocalCommandSocket.path) { server = LocalCommandServer(path: socketPath) }
    func start() {
        do { try server.start { request in await self.handle(request) } }
        catch { NSLog("[AnyWhere] MCP unavailable: %@", error.localizedDescription) }
    }
    func stop() { server.stop() }
    func reconcile(_ entries: [PluginLauncherEntry], preferences: PluginPreferencesStore) {
        self.entries = entries; self.preferences = preferences
    }
    private func exported() -> [PluginLauncherEntry] {
        let authorized = entries.filter { (try? preferences.isMCPEnabled(actionID: $0.id, approval: $0.definition.mcpApproval)) == true }
        let names = Dictionary(grouping: authorized, by: { $0.definition.mcp!.name })
        return authorized.filter { names[$0.definition.mcp!.name]?.count == 1 }.sorted { $0.definition.mcp!.name < $1.definition.mcp!.name }
    }
    private func authorize(_ entry: PluginLauncherEntry) throws {
        guard exported().contains(where: { $0.id == entry.id && $0.definition == entry.definition }) else {
            throw PluginError(.denied, "Plugin MCP access was revoked, changed or has a naming conflict.")
        }
    }
    func handle(_ request: JSONValue) async -> JSONValue {
        do {
            guard let body = request.object, let method = body["method"]?.string else { throw PluginError(.invalidArguments, "Expected method.") }
            switch method {
            case "tools":
                let tools = exported().map { entry -> JSONValue in
                    .object(["name": .string(entry.definition.mcp!.name), "description": .string(entry.definition.mcp!.description),
                             "inputSchema": entry.definition.mcpInputSchema!,
                             "readOnly": .bool(entry.definition.mcp!.commands.allSatisfy { entry.definition.commands!.operations[$0]!.readOnly })])
                }
                return .object(["result": .array(tools)])
            case "call":
                guard let name = body["name"]?.string, let arguments = body["arguments"]?.object else { throw PluginError(.invalidArguments, "Expected tool and arguments.") }
                if name == "list" {
                    guard Set(arguments.keys).isSubset(of: ["plugin"]), arguments["plugin"] == nil || arguments["plugin"]?.string != nil else { throw PluginError(.invalidArguments, "Expected optional plugin name.") }
                    let selected = exported().filter { arguments["plugin"] == nil || $0.definition.mcp?.name == arguments["plugin"]?.string }
                    if arguments["plugin"] != nil && selected.isEmpty { throw PluginError(.notFound, "Plugin is not registered or authorized.") }
                    let result = selected.map { entry -> JSONValue in
                        let definition = entry.definition
                        var item: [String: JSONValue] = ["name": .string(definition.mcp!.name), "description": .string(definition.mcp!.description)]
                        item["operations"] = .array(definition.mcp!.commands.map { operation in
                            let command = definition.commands!.operations[operation]!
                            var info: [String: JSONValue] = ["name": .string(operation), "description": .string(command.description), "readOnly": .bool(command.readOnly)]
                            if arguments["plugin"] != nil { info["inputSchema"] = command.inputSchema; info["outputSchema"] = command.outputSchema }
                            return .object(info)
                        })
                        return .object(item)
                    }
                    return .object(["result": .object(["plugins": .array(result)])])
                }
                guard let entry = exported().first(where: { $0.definition.mcp?.name == name }) else { throw PluginError(.notFound, "Plugin is not registered or authorized.") }
                try PluginJSONSchema.validate(.object(arguments), schema: entry.definition.mcpInputSchema!)
                let operation = arguments["operation"]!.string!
                let result = try await PluginCommandRuntime.shared.invoke(entry: entry, operation: operation, params: arguments["params"]!) { try self.authorize(entry) }
                return .object(["result": result])
            default: throw PluginError(.invalidArguments, "Unknown IPC method.")
            }
        } catch {
            let failure = error as? PluginError ?? PluginError(.failed, error.localizedDescription)
            return .object(["error": .object(["code": .string(failure.code.rawValue), "message": .string(failure.message)])])
        }
    }
}
