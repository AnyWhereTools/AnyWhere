import Foundation
import CryptoKit

/// App-local password storage. The random key and authenticated ciphertext must be backed up together.
/// File permissions protect against other users, not processes already running as the current user.
public final class LocalEncryptedSecretStore: PackSecretStore {
    private static let lock = NSLock()
    private static let header = Data("AWSECRETS1".utf8)
    private let directory: URL
    private var keyFile: URL { directory.appendingPathComponent("key") }
    private var vaultFile: URL { directory.appendingPathComponent("secrets.enc") }
    private let fm = FileManager.default

    public init(directory: URL) { self.directory = directory }

    public enum StorageError: LocalizedError {
        case invalidKey, damagedVault, invalidFile

        public var errorDescription: String? {
            switch self {
            case .invalidKey: return String(localized: "localSecrets.invalidKey", bundle: .module)
            case .damagedVault: return String(localized: "localSecrets.damagedVault", bundle: .module)
            case .invalidFile: return String(localized: "localSecrets.invalidFile", bundle: .module)
            }
        }
    }

    public func read(account: String) throws -> String? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try loadValues()[account]
    }

    public func write(_ value: String?, account: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var values = try loadValues()
        if value == nil && values[account] == nil { return }
        values[account] = value
        _ = try prepareDirectory(create: true)
        let key = try encryptionKey(create: true)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(values), using: key,
                                      authenticating: Self.header)
        guard let combined = sealed.combined else { throw StorageError.damagedVault }
        try writePrivate(Self.header + combined, to: vaultFile)
    }

    private func loadValues() throws -> [String: String] {
        guard try prepareDirectory(create: false), let data = try readPrivate(vaultFile) else { return [:] }
        let key = try encryptionKey(create: false)
        guard data.starts(with: Self.header) else { throw StorageError.damagedVault }
        do {
            let sealed = try AES.GCM.SealedBox(combined: Data(data.dropFirst(Self.header.count)))
            let plain = try AES.GCM.open(sealed, using: key, authenticating: Self.header)
            return try JSONDecoder().decode([String: String].self, from: plain)
        } catch {
            throw StorageError.damagedVault
        }
    }

    private func encryptionKey(create: Bool) throws -> SymmetricKey {
        if let data = try readPrivate(keyFile) {
            guard data.count == 32 else { throw StorageError.invalidKey }
            return SymmetricKey(data: data)
        }
        // Missing key beside an existing vault must never silently generate a replacement.
        guard create, try attributes(vaultFile) == nil else { throw StorageError.invalidKey }
        let key = SymmetricKey(size: .bits256)
        try writePrivate(key.withUnsafeBytes { Data($0) }, to: keyFile)
        return key
    }

    private func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try fm.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func prepareDirectory(create: Bool) throws -> Bool {
        if let attrs = try attributes(directory) {
            guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw StorageError.invalidFile }
        } else {
            guard create else { return false }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return true
    }

    private func readPrivate(_ url: URL) throws -> Data? {
        guard let attrs = try attributes(url) else { return nil }
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw StorageError.invalidFile }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try Data(contentsOf: url)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        if let attrs = try attributes(url), attrs[.type] as? FileAttributeType != .typeRegular {
            throw StorageError.invalidFile
        }
        // Atomic replacement keeps the previous complete file on write failure. The enclosing
        // directory is already 0700, including while Foundation creates its temporary file.
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
