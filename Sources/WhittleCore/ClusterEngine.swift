import Foundation

/// A minimal item for temporal grouping: an identifier plus capture date.
public struct TimedItem: Equatable {
    public let id: String
    public let date: Date?

    public init(id: String, date: Date?) {
        self.id = id
        self.date = date
    }
}

/// Pure clustering logic, kept free of PhotoKit/Vision so it is unit-testable.
public enum ClusterEngine {

    /// Groups items whose consecutive capture times are within `maxGap` seconds.
    /// Items without a date are excluded. Input order does not matter.
    public static func temporalGroups(_ items: [TimedItem], maxGap: TimeInterval) -> [[TimedItem]] {
        let dated = items.filter { $0.date != nil }.sorted { $0.date! < $1.date! }
        guard !dated.isEmpty else { return [] }

        var groups: [[TimedItem]] = []
        var current: [TimedItem] = [dated[0]]
        for item in dated.dropFirst() {
            if item.date!.timeIntervalSince(current.last!.date!) <= maxGap {
                current.append(item)
            } else {
                groups.append(current)
                current = [item]
            }
        }
        groups.append(current)
        return groups
    }

    /// Splits into groups of at most `maxSize`, as evenly as possible
    /// (7 → 3,2,2 — never a lone element unless the input is a single item).
    /// Used to batch tournament rounds for the judge.
    public static func balancedChunks<T>(_ items: [T], maxSize: Int) -> [[T]] {
        guard !items.isEmpty, maxSize > 0 else { return [] }
        let groupCount = Int((Double(items.count) / Double(maxSize)).rounded(.up))
        let base = items.count / groupCount
        var remainder = items.count % groupCount
        var chunks: [[T]] = []
        var cursor = 0
        for _ in 0..<groupCount {
            let size = base + (remainder > 0 ? 1 : 0)
            if remainder > 0 { remainder -= 1 }
            chunks.append(Array(items[cursor..<cursor + size]))
            cursor += size
        }
        return chunks
    }

    /// Splits a temporal group into visually coherent subclusters using
    /// single-linkage: an item joins a subcluster if its distance to ANY member
    /// is within `threshold`. `distance` returns nil when unavailable
    /// (treated as not similar).
    public static func visualSubclusters(
        _ ids: [String],
        threshold: Double,
        distance: (String, String) -> Double?
    ) -> [[String]] {
        var subclusters: [[String]] = []
        for id in ids {
            var joined = false
            for i in subclusters.indices {
                let isClose = subclusters[i].contains { member in
                    if let d = distance(id, member) { return d <= threshold }
                    return false
                }
                if isClose {
                    subclusters[i].append(id)
                    joined = true
                    break
                }
            }
            if !joined {
                subclusters.append([id])
            }
        }
        return subclusters
    }
}
