import Foundation

/// Executes a same-pack workflow in declaration order and stops at the first failure.
public enum WorkflowExecutor {
    public static func run(_ workflow: PackWorkflow, in manifest: PackManifest,
                           step: (PackAction, JSONValue) throws -> JSONValue,
                           input: JSONValue = .null) throws -> JSONValue {
        var value = input
        for ref in workflow.steps {
            guard let action = manifest.actions.first(where: { $0.id == ref.action }) else {
                throw PluginError(.failed, "Workflow action not found: \(ref.action)")
            }
            value = try step(action, value)
        }
        return value
    }
}
