import AppKit
import Foundation

enum FinderDirectory {
    // ponytail: synchronous capture with a 1 s Apple Event timeout; move off-main if launcher latency becomes noticeable.
    static func currentPath(frontmostBundleID: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                            readTarget: () -> String? = readTarget) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard frontmostBundleID == "com.apple.finder", let value = readTarget(), value.hasPrefix("/") else { return home }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory), isDirectory.boolValue else { return home }
        return URL(fileURLWithPath: value).path
    }

    static func readTarget() -> String? {
        let source = """
        with timeout of 1 second
            tell application "Finder"
                if (count of Finder windows) > 0 then
                    return POSIX path of (target of front Finder window as alias)
                end if
            end tell
        end timeout
        """
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
    }
}
