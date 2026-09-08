import Foundation

public enum PluginResourceResolver {
    public static func resolve(root: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.contains("\0"), !relativePath.contains("\\"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw PluginError(.denied, "Invalid plugin resource path.")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard url.pathComponents.count > base.pathComponents.count,
              url.pathComponents.starts(with: base.pathComponents),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw PluginError(.denied, "Plugin resource is unavailable.")
        }
        return url
    }
}
