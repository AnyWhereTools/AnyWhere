import Foundation

public struct PluginSearchEntry: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let keywords: [String]
    public init(id: UUID, title: String, keywords: [String]) { self.id = id; self.title = title; self.keywords = keywords }
}
public struct PluginSearchMatch: Equatable, Sendable {
    public let entry: PluginSearchEntry
    public let argument: String
}

public enum PluginSearch {
    public static func matches(query: String, entries: [PluginSearchEntry], recent: [UUID], keywordsOnly: Bool = false) -> [PluginSearchMatch] {
        let query = String(query.drop(while: { $0.isWhitespace }))
        if keywordsOnly && query.isEmpty { return [] }
        struct Candidate {
            let match: PluginSearchMatch
            let rank: Int
            let prefixLength: Int
        }
        let candidates: [Candidate] = entries.compactMap { entry in
            if query.isEmpty { return Candidate(match: .init(entry: entry, argument: ""), rank: 0, prefixLength: 0) }
            return ((keywordsOnly ? [] : [entry.title]) + entry.keywords).compactMap { key -> Candidate? in
                let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                if query.compare(key, options: .caseInsensitive) == .orderedSame {
                    return Candidate(match: .init(entry: entry, argument: ""), rank: 0, prefixLength: key.count)
                }
                if let range = query.range(of: key, options: [.anchored, .caseInsensitive]),
                   range.upperBound < query.endIndex, query[range.upperBound].isWhitespace {
                    return Candidate(match: .init(entry: entry, argument: String(query[range.upperBound...].drop(while: { $0.isWhitespace }))),
                                     rank: 0, prefixLength: key.count)
                }
                if keywordsOnly { return nil }
                if key.range(of: query, options: [.anchored, .caseInsensitive]) != nil {
                    return Candidate(match: .init(entry: entry, argument: ""), rank: 1, prefixLength: 0)
                }
                if key.range(of: query, options: .caseInsensitive) != nil {
                    return Candidate(match: .init(entry: entry, argument: ""), rank: 2, prefixLength: 0)
                }
                return nil
            }.sorted { $0.rank == $1.rank ? $0.prefixLength > $1.prefixLength : $0.rank < $1.rank }.first
        }
        let sorted = candidates.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.prefixLength != $1.prefixLength { return $0.prefixLength > $1.prefixLength }
            let a = recent.firstIndex(of: $0.match.entry.id) ?? Int.max
            let b = recent.firstIndex(of: $1.match.entry.id) ?? Int.max
            if a != b { return a < b }
            if query.isEmpty, $0.match.entry.title != $1.match.entry.title {
                return $0.match.entry.title.localizedCaseInsensitiveCompare($1.match.entry.title) == .orderedAscending
            }
            return $0.match.entry.id.uuidString < $1.match.entry.id.uuidString
        }.map(\.match)
        if query.isEmpty {
            let used = sorted.filter { recent.contains($0.entry.id) }
            if !used.isEmpty { return Array(used.prefix(10)) }
        }
        return sorted
    }
}
