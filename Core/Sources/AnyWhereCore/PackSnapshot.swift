import Foundation

/// The files shown during review are the same files later moved into the installed pack.
public struct PackSnapshot: Sendable {
    public let directory: URL
    public let manifest: PackManifest
    public let scripts: [String: String]

    public enum ReadError: Error {
        case noManifest
        case invalidManifest(String)
    }

    public static func read(in directory: URL) throws -> PackSnapshot {
        guard PackInspector.resolvesInside(directory: directory, relativePath: "manifest.json") else {
            throw ReadError.invalidManifest("manifest.json escapes pack")
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else {
            throw ReadError.noManifest
        }
        let manifest: PackManifest
        do {
            manifest = try PackManifest.decode(data)
            try manifest.validate()
        } catch {
            throw ReadError.invalidManifest("\(error)")
        }
        var scripts: [String: String] = [:]
        for action in manifest.actions {
            if let ui = action.ui {
                do {
                    let url = try PluginResourceResolver.resolve(root: directory, relativePath: ui.entry)
                    guard ["html", "htm"].contains(url.pathExtension.lowercased()) else { throw ReadError.invalidManifest("UI entry must be HTML") }
                    _ = try String(contentsOf: url, encoding: .utf8)
                } catch { throw ReadError.invalidManifest("UI entry is missing, invalid or outside pack") }
            }
            guard let script = action.script else { continue }
            guard PackInspector.resolvesInside(directory: directory, relativePath: script) else {
                throw ReadError.invalidManifest("script path escapes pack: \(script)")
            }
            guard let text = try? String(contentsOf: directory.appendingPathComponent(script), encoding: .utf8) else {
                throw ReadError.invalidManifest("script is missing or unreadable: \(script)")
            }
            scripts[action.id] = text
        }
        return PackSnapshot(directory: directory, manifest: manifest, scripts: scripts)
    }

    /// Copy, rather than execute or Git-clone, a local folder. Preserve executable permissions.
    public static func copyLocalDirectory(_ source: URL) throws -> PackSnapshot {
        // Reject a wrong folder before copying potentially large unrelated contents.
        _ = try read(in: source)
        let fm = FileManager.default
        let destination = fm.temporaryDirectory.appendingPathComponent("anywhere-pack-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.copyItem(at: source, to: destination)
            // Local imports must remain self-contained after the source folder is moved/deleted.
            if let files = fm.enumerator(atPath: destination.path) {
                for case let relative as String in files {
                    let file = destination.appendingPathComponent(relative)
                    if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                        guard PackInspector.resolvesInside(directory: destination, relativePath: relative) else {
                            throw ReadError.invalidManifest("symlink escapes pack: \(relative)")
                        }
                    }
                }
            }
            return try read(in: destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }
}
