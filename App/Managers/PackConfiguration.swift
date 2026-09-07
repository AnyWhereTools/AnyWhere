import Foundation
import AnyWhereCore

enum PackConfiguration {
    static func store() -> PackConfigurationStore {
        let base = AppPaths.configDirectory()
        return PackConfigurationStore(directory: base.appendingPathComponent("PackConfigurations"),
                                      secrets: LocalEncryptedSecretStore(directory: base.appendingPathComponent("PrivateData")))
    }
}
