import Foundation

enum SearchText {
    static func forms(_ value: String) -> [String] {
        let source = NSMutableString(string: value) as CFMutableString
        CFStringTransform(source, nil, "Any-Latin; Latin-ASCII" as CFString, false)
        let latin = (source as String).lowercased()
        let initials = latin.split { $0 == " " || $0 == "-" || $0 == "_" }.compactMap(\.first)
        return [value.lowercased(), latin.replacingOccurrences(of: " ", with: ""), String(initials)]
    }
}
