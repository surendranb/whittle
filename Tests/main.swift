// Plain test runner (SwiftPM manifest compilation is broken in this CLT install,
// so tests run via swiftc directly — see test.sh).
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name): expected \(expected), got \(actual)")
    }
}

func date(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

// MARK: - Temporal grouping

expectEqual(
    ClusterEngine.temporalGroups([
        TimedItem(id: "a", date: date(0)),
        TimedItem(id: "b", date: date(3)),
        TimedItem(id: "c", date: date(8)),
    ], maxGap: 10).map { $0.map(\.id) },
    [["a", "b", "c"]],
    "groups shots within gap"
)

expectEqual(
    ClusterEngine.temporalGroups([
        TimedItem(id: "a", date: date(0)),
        TimedItem(id: "b", date: date(5)),
        TimedItem(id: "c", date: date(100)),
        TimedItem(id: "d", date: date(104)),
    ], maxGap: 10).map { $0.map(\.id) },
    [["a", "b"], ["c", "d"]],
    "splits when gap exceeded"
)

expectEqual(
    ClusterEngine.temporalGroups([
        TimedItem(id: "a", date: date(0)),
        TimedItem(id: "b", date: date(8)),
        TimedItem(id: "c", date: date(16)),
    ], maxGap: 10).count,
    1,
    "chained gaps stay together"
)

expectEqual(
    ClusterEngine.temporalGroups([
        TimedItem(id: "b", date: date(5)),
        TimedItem(id: "a", date: date(0)),
    ], maxGap: 10).map { $0.map(\.id) },
    [["a", "b"]],
    "unsorted input is sorted by date"
)

expectEqual(
    ClusterEngine.temporalGroups([
        TimedItem(id: "a", date: date(0)),
        TimedItem(id: "x", date: nil),
        TimedItem(id: "b", date: date(2)),
    ], maxGap: 10).map { $0.map(\.id) },
    [["a", "b"]],
    "items without date are excluded"
)

expectEqual(
    ClusterEngine.temporalGroups([], maxGap: 10).count,
    0,
    "empty input yields no groups"
)

// MARK: - Visual subclustering

expectEqual(
    ClusterEngine.visualSubclusters(["a", "b", "c"], threshold: 0.6) { _, _ in 0.2 },
    [["a", "b", "c"]],
    "keeps visually similar together"
)

expectEqual(
    ClusterEngine.visualSubclusters(["a", "b", "c"], threshold: 0.6) { x, y in
        Set([x, y]).contains("c") ? 1.5 : 0.2
    },
    [["a", "b"], ["c"]],
    "splits visually distinct"
)

expectEqual(
    ClusterEngine.visualSubclusters(["a", "b", "c"], threshold: 0.6) { x, y in
        Set([x, y]) == Set(["a", "c"]) ? 1.5 : 0.3
    },
    [["a", "b", "c"]],
    "single linkage joins via intermediate"
)

expectEqual(
    ClusterEngine.visualSubclusters(["a", "b"], threshold: 0.6) { _, _ in nil },
    [["a"], ["b"]],
    "missing distance starts new subcluster"
)

// MARK: - Balanced chunks (tournament rounds)

expectEqual(
    ClusterEngine.balancedChunks(Array(0..<7), maxSize: 3).map(\.count),
    [3, 2, 2],
    "7 items chunk into 3,2,2 — no lone photo"
)

expectEqual(
    ClusterEngine.balancedChunks(Array(0..<9), maxSize: 3).map(\.count),
    [3, 3, 3],
    "9 items chunk into 3,3,3"
)

expectEqual(
    ClusterEngine.balancedChunks(Array(0..<4), maxSize: 3).map(\.count),
    [2, 2],
    "4 items chunk into 2,2"
)

expectEqual(
    ClusterEngine.balancedChunks(Array(0..<3), maxSize: 3),
    [[0, 1, 2]],
    "3 items stay one group"
)

expectEqual(
    ClusterEngine.balancedChunks(Array(0..<10), maxSize: 3).map(\.count),
    [3, 3, 2, 2],
    "10 items chunk into 3,3,2,2"
)

expectEqual(
    (2...20).allSatisfy { n in
        ClusterEngine.balancedChunks(Array(0..<n), maxSize: 3)
            .allSatisfy { $0.count >= 2 && $0.count <= 3 }
    },
    true,
    "every chunk of 2-20 items has size 2 or 3 — never a lone photo"
)

// order is preserved and all items covered
expectEqual(
    ClusterEngine.balancedChunks(Array(0..<7), maxSize: 3).flatMap { $0 },
    Array(0..<7),
    "chunking preserves order and covers all items"
)

// MARK: - End-to-end filter

expectEqual(
    ClusterEngine.temporalGroups([
        TimedItem(id: "a", date: date(0)),
        TimedItem(id: "b", date: date(2)),
        TimedItem(id: "lone", date: date(500)),
    ], maxGap: 10).filter { $0.count >= 2 }.map { $0.map(\.id) },
    [["a", "b"]],
    "only multi-photo clusters survive"
)

if failures > 0 {
    print("\n\(failures) FAILURE(S)")
    exit(1)
}
print("\nAll tests passed.")
