import Foundation

public struct ApplicationSearchEntry: Identifiable, Equatable, Sendable {
    public let url: URL
    public let name: String
    public var id: String { url.path }
    public init(url: URL, name: String) { self.url = url; self.name = name }
}

public enum ApplicationSearch {
    public static var directories: [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
         URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    public static func discover(in directories: [URL]) -> [ApplicationSearchEntry] {
        var apps: [ApplicationSearchEntry] = [], seen = Set<URL>()
        for directory in directories {
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in files where url.pathExtension.lowercased() == "app" {
                files.skipDescendants()
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard seen.insert(resolved).inserted, let bundle = Bundle(url: resolved),
                      bundle.bundleIdentifier != nil else { continue }
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                apps.append(ApplicationSearchEntry(url: resolved, name: name))
            }
        }
        return apps
    }

    public static func matches(query: String, apps: [ApplicationSearchEntry]) -> [ApplicationSearchEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        func rank(_ name: String) -> Int? {
            if name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return 0 }
            if name.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil { return 1 }
            return name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil ? nil : 2
        }
        return apps.compactMap { app -> (ApplicationSearchEntry, Int)? in
            let ranks = [app.name, app.url.deletingPathExtension().lastPathComponent].compactMap(rank)
            return ranks.min().map { (app, $0) }
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            let order = $0.0.name.localizedStandardCompare($1.0.name)
            return order == .orderedSame ? $0.0.id < $1.0.id : order == .orderedAscending
        }.map(\.0)
    }
}
