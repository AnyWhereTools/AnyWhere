import Foundation
import AnyWhereCore

/// Bazaar describes existing extension packs; it does not grant execution permission.
struct CatalogPack: Identifiable, Decodable, Equatable {
    let id: String
    let repository: String
    let revision: String
    let name: String
    let description: String?
    let author: String?
    let icon: String
    let manifestSchemaVersion: Int
    let types: [String]

    var repo: String { String(repository.dropFirst("https://github.com/".count)) }

    func validate() throws {
        guard id.count <= 100, id.range(of: "^[a-z0-9]+([.-][a-z0-9]+)*$", options: .regularExpression) != nil,
              PackCatalog.canonicalRepository(repository) == repository.lowercased(),
              revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512,
              (description?.utf8.count ?? 0) <= 8192, (author?.utf8.count ?? 0) <= 512,
              icon.utf8.count <= 256, (1...4).contains(manifestSchemaVersion),
              !types.isEmpty, Set(types).count == types.count,
              Set(types).isSubset(of: ["finder", "tool", "workflow"]) else {
            throw PackCatalog.Failure("Invalid Bazaar entry: \(id.prefix(100))")
        }
    }

    func validate(manifest: PackManifest) throws {
        let actual = Set(manifest.types.map(\.rawValue))
        guard manifest.schemaVersion == manifestSchemaVersion, manifest.name == name, actual == Set(types) else {
            throw PackCatalog.Failure("The package manifest does not match the selected Bazaar entry.")
        }
    }
}

struct PackCatalog: Decodable {
    let schemaVersion: Int
    let packages: [CatalogPack]
    static let byteLimit = 2 * 1024 * 1024

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func decode(_ data: Data) throws -> PackCatalog {
        guard data.count <= byteLimit else { throw Failure("Bazaar catalog exceeds 2 MiB.") }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1, catalog.packages.count <= 1000 else {
            throw Failure("Unsupported Bazaar catalog version or package count.")
        }
        var ids = Set<String>(), repositories = Set<String>()
        for pack in catalog.packages {
            try pack.validate()
            guard ids.insert(pack.id).inserted, repositories.insert(pack.repository.lowercased()).inserted else {
                throw Failure("Duplicate Bazaar package identity or repository.")
            }
        }
        return catalog
    }

    /// Only canonical GitHub HTTPS sources can adopt a registry identity.
    static func canonicalRepository(_ source: String) -> String? {
        guard source.range(of: "^https://github\\.com/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { return nil }
        var value = source.lowercased()
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        let repo = value.split(separator: "/").last ?? ""
        guard repo != ".", repo != "..", !repo.isEmpty else { return nil }
        return value
    }

    /// These four repository transfers were verified by GitHub repository ID.
    /// Keep their original identity so installed keys and plugin data survive the move.
    static func repositoryIdentity(_ source: String) -> String? {
        guard let canonical = canonicalRepository(source) else { return nil }
        let prefix = "https://github.com/anywheretools/"
        let transferred = ["anywhere-json-tools", "anywhere-quicklinks", "anywhere-todo", "anywhere-tool-chain-demo"]
        if canonical.hasPrefix(prefix), transferred.contains(String(canonical.dropFirst(prefix.count))) {
            return "https://github.com/appdev/" + canonical.dropFirst(prefix.count)
        }
        return canonical
    }

    func entry(repository: String, catalogID: String?) throws -> CatalogPack? {
        let source = Self.repositoryIdentity(repository)
        if let catalogID {
            guard let entry = packages.first(where: { $0.id == catalogID }) else {
                throw Failure("This package is no longer listed in Bazaar. Its installed copy is unchanged.")
            }
            guard source == Self.repositoryIdentity(entry.repository) else {
                throw Failure("The Bazaar repository has changed. Import the new source separately after review.")
            }
            return entry
        }
        return packages.first { Self.repositoryIdentity($0.repository) == source }
    }
}

enum PackDiscovery {
    static let website = URL(string: "https://github.com/AnyWhereTools/anywhere-bazaar")!
    static let endpoint = URL(string: "https://raw.githubusercontent.com/AnyWhereTools/anywhere-bazaar/main/catalog.json")!

    static func catalog() async throws -> PackCatalog {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == endpoint else {
            throw PackCatalog.Failure("Unable to load Bazaar catalog (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        guard response.expectedContentLength <= PackCatalog.byteLimit else { throw PackCatalog.Failure("Bazaar catalog exceeds 2 MiB.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < PackCatalog.byteLimit else { throw PackCatalog.Failure("Bazaar catalog exceeds 2 MiB.") }
            data.append(byte)
        }
        return try PackCatalog.decode(data)
    }
}
