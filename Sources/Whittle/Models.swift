import Foundation
import Photos

struct PhotoItem: Identifiable, Equatable {
    let id: String          // PHAsset.localIdentifier
    let creationDate: Date?

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool { lhs.id == rhs.id }
}

struct PhotoCluster: Identifiable {
    let id: String          // first asset's identifier
    var items: [PhotoItem]
    var dateLabel: String {
        guard let d = items.first?.creationDate else { return "Unknown date" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

enum Decision {
    case undecided
    case keep
    case discard
}

struct ClusterVerdict {
    let keepIndex: Int      // 0-based index into cluster items
    let reasons: [String]   // one per photo (padded/trimmed to match)
    let model: String
}

enum JudgeState {
    case idle
    case loading(stage: String, startedAt: Date)
    case failed(String)
    case done
}

enum ScanRange: String, CaseIterable, Identifiable {
    case week = "Last 7 days"
    case month = "Last 30 days"
    case days60 = "Last 60 days"
    case days90 = "Last 90 days"
    case sixMonths = "Last 6 months"
    case year = "Last year"
    case all = "All photos"
    case custom = "Custom range…"

    var id: String { rawValue }

    /// nil = no bound on that side (also for .custom — the UI supplies dates).
    var startDate: Date? {
        let cal = Calendar.current
        switch self {
        case .week: return cal.date(byAdding: .day, value: -7, to: Date())
        case .month: return cal.date(byAdding: .day, value: -30, to: Date())
        case .days60: return cal.date(byAdding: .day, value: -60, to: Date())
        case .days90: return cal.date(byAdding: .day, value: -90, to: Date())
        case .sixMonths: return cal.date(byAdding: .month, value: -6, to: Date())
        case .year: return cal.date(byAdding: .year, value: -1, to: Date())
        case .all, .custom: return nil
        }
    }
}

enum ScanState: Equatable {
    case idle
    case scanning(done: Int, total: Int)
    case finished(clusters: Int, photosScanned: Int)
    case failed(String)
}
