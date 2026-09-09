import Foundation
import AnyWhereCore

struct LauncherWorkflowEntry: Identifiable {
    let pack: InstalledPack
    let definition: PackWorkflow
    let directory: URL
    var id: UUID { PackManager.workflowUUID(packKey: pack.key, workflowID: definition.id) }
}

struct LauncherEntry: Identifiable {
    enum Target {
        case plugin(PluginLauncherEntry), action(MenuAction), workflow(LauncherWorkflowEntry)
        case website(PluginLauncherEntry, PluginLink)
    }
    let search: PluginSearchEntry
    let subtitle: String
    let target: Target
    var id: UUID { search.id }
    var kind: String {
        switch target {
        case .plugin(let entry): return String(localized: entry.definition.ui == nil ? "panel.kind.action" : "panel.kind.tool")
        case .action: return String(localized: "panel.kind.action")
        case .workflow: return String(localized: "panel.kind.workflow")
        case .website: return "网页"
        }
    }
    var icon: String {
        switch target {
        case .plugin(let entry): return entry.definition.icon
        case .action: return "bolt"
        case .workflow: return "arrow.triangle.branch"
        case .website: return "globe"
        }
    }
}

/// Ranking extends the existing keyword/argument matcher; execution references stay with each entry.
struct LauncherCatalog {
    var entries: [LauncherEntry] = []
    struct Match {
        let entry: LauncherEntry
        let argument: String
    }
    func search(_ query: String, recent: [UUID]) -> [Match] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return recent.compactMap { id in entries.first { $0.id == id }.map { Match(entry: $0, argument: "") } }
        }
        // Title matches precede aliases, which precede descriptions. Keep argument extraction unchanged.
        var matches: [Match] = []
        var seen = Set<UUID>()
        for fields in [entries.map { PluginSearchEntry(id: $0.id, title: $0.search.title, keywords: []) },
                       entries.map { PluginSearchEntry(id: $0.id, title: "", keywords: $0.search.keywords) },
                       entries.map { PluginSearchEntry(id: $0.id, title: $0.subtitle, keywords: []) }] {
            for match in PluginSearch.matches(query: query, entries: fields, recent: recent) {
                if seen.insert(match.entry.id).inserted, let entry = entries.first(where: { $0.id == match.entry.id }) {
                    matches.append(Match(entry: entry, argument: match.argument))
                }
            }
        }
        return matches
    }
}
