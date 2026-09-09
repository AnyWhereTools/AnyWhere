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
        func forms(_ value: String) -> [String] {
            let source = NSMutableString(string: value) as CFMutableString
            CFStringTransform(source, nil, "Any-Latin; Latin-ASCII" as CFString, false)
            let latin = (source as String).lowercased()
            let initials = latin.split { $0 == " " || $0 == "-" || $0 == "_" }.compactMap(\.first)
            return [value.lowercased(), latin.replacingOccurrences(of: " ", with: ""), String(initials)]
        }
        func rank(_ name: String) -> Int? {
            let query = query.lowercased()
            let values = forms(name)
            if values.contains(where: { $0 == query }) { return 0 }
            if values.contains(where: { $0.hasPrefix(query) }) { return 1 }
            return values.contains(where: { $0.contains(query) }) ? 2 : nil
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
