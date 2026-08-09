import AppKit
import Photos
import SwiftUI
import UserNotifications
import Vision

@MainActor
final class AppModel: ObservableObject {

    // Tunables
    static let temporalGapSeconds: TimeInterval = 10
    static let visualDistanceThreshold: Double = 0.6
    static let featurePrintSize: CGFloat = 512
    static let judgeImageSize: CGFloat = 768
    static let visionTimeoutSeconds: TimeInterval = 15

    @Published var authStatus: PHAuthorizationStatus = PhotoLibraryService.currentAuthorization()
    @Published var scanRange: ScanRange = ScanRange(
        rawValue: UserDefaults.standard.string(forKey: "scanRange") ?? "") ?? .month {
        didSet { UserDefaults.standard.set(scanRange.rawValue, forKey: "scanRange") }
    }
    @Published var customStart: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @Published var customEnd: Date = Date()
    @Published var scanState: ScanState = .idle
    @Published var clusters: [PhotoCluster] = []
    @Published var selectedClusterID: String?

    @Published var decisions: [String: Decision] = [:]        // asset id → decision
    @Published var verdicts: [String: ClusterVerdict] = [:]   // cluster id → verdict
    @Published var judgeStates: [String: JudgeState] = [:]    // cluster id → state

    @Published var backends: [JudgeBackend] = []
    @Published var selectedBackendID: String =
        UserDefaults.standard.string(forKey: "selectedBackendID") ?? "" {
        didSet { UserDefaults.standard.set(selectedBackendID, forKey: "selectedBackendID") }
    }
    @Published var localServerReachable = true   // LM Studio or Ollama
    @Published var hasAIStudioKey = KeychainStore.exists(account: aiStudioKeyAccount)

    @Published var deleteError: String?

    // Running outcome tally, persisted across sessions.
    @Published var totalDeleted: Int = UserDefaults.standard.integer(forKey: "tally.deleted")
    @Published var totalBytesFreed: Int64 = Int64(UserDefaults.standard.integer(forKey: "tally.bytes"))

    // Suggest-all queue state
    @Published var suggestAllDone = 0
    @Published var suggestAllTotal = 0
    private var suggestAllTask: Task<Void, Never>?

    // Native quality signals cached per asset (computed during scan).
    private var signalsByID: [String: NativeSignals] = [:]

    private static let aiStudioKeyAccount = "aistudio-api-key"

    private var scanTask: Task<Void, Never>?

    init() {
        // Re-discover servers whenever the user returns to the app — the
        // natural moment after they've started LM Studio/Ollama.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshModels() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            Telemetry.flushBeforeQuit()
        }
        Telemetry.boot()
    }

    var selectedCluster: PhotoCluster? {
        clusters.first { $0.id == selectedClusterID }
    }

    var discardedIDs: [String] {
        decisions.filter { $0.value == .discard }.map(\.key)
    }

    // MARK: - Triage progress

    /// A cluster is resolved when every photo has a decision.
    func isResolved(_ cluster: PhotoCluster) -> Bool {
        cluster.items.allSatisfy { (decisions[$0.id] ?? .undecided) != .undecided }
    }

    var reviewedCount: Int {
        clusters.filter { isResolved($0) }.count
    }

    /// Applies the model's suggestion (keep the pick, discard the rest) and
    /// moves selection to the next unresolved cluster.
    func acceptSuggestion(cluster: PhotoCluster) {
        guard let verdict = verdicts[cluster.id] else { return }
        for (index, item) in cluster.items.enumerated() {
            decisions[item.id] = index == verdict.keepIndex ? .keep : .discard
        }
        telemetryReportedClusters.insert(cluster.id)
        var props: [String: Any] = ["decision": "accepted"]
        if let backend = selectedBackend {
            props["backend_kind"] = backend.kind.rawValue
            props["model_name"] = backend.shortModelName
        }
        Telemetry.send("suggestion_decided", props)
        // Let the keep/discard marks visibly land before moving on.
        let id = cluster.id
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if self.selectedClusterID == id {
                self.advanceToNextUnresolved(after: id)
            }
        }
    }

    func advanceToNextUnresolved(after clusterID: String) {
        guard let current = clusters.firstIndex(where: { $0.id == clusterID }) else { return }
        let ordered = clusters[(current + 1)...] + clusters[...current]
        if let next = ordered.first(where: { !isResolved($0) }) {
            selectedClusterID = next.id
        }
    }

    // MARK: - Authorization

    func requestAccess() async {
        authStatus = await PhotoLibraryService.requestAuthorization()
    }

    // MARK: - Backends

    var selectedBackend: JudgeBackend? {
        backends.first { $0.id == selectedBackendID }
    }

    var aiStudioKey: String? {
        KeychainStore.load(account: Self.aiStudioKeyAccount)
    }

    func setAIStudioKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(account: Self.aiStudioKeyAccount)
            UserDefaults.standard.removeObject(forKey: "aistudio.models")
            hasAIStudioKey = false
        } else {
            KeychainStore.save(trimmed, account: Self.aiStudioKeyAccount)
            hasAIStudioKey = true
            Task { await refreshCloudModels(key: trimmed) }
        }
    }

    /// Fetches the account's Gemma/Gemini models and caches them (model IDs
    /// are not secrets). Called with the key already in hand so saving a key
    /// doesn't immediately re-read the Keychain.
    func refreshCloudModels(key: String) async {
        guard let models = try? await JudgeService.aiStudioModelList(apiKey: key),
              !models.isEmpty else { return }
        UserDefaults.standard.set(models, forKey: "aistudio.models")
        await refreshModels()
    }

    /// The backend we suggest by default: a local qwen-VL model led our
    /// accuracy/speed evals; local also means private, free, and offline.
    var recommendedBackendID: String? {
        let locals = backends.filter(\.isLocal)
        if let qwen = locals.first(where: {
            $0.modelID.localizedCaseInsensitiveContains("qwen")
                && $0.modelID.localizedCaseInsensitiveContains("vl")
        }) { return qwen.id }
        return (locals.first ?? backends.first)?.id
    }

    func refreshModels() async {
        var list: [JudgeBackend] = []
        if let models = try? await JudgeService.lmStudioVisionModels() {
            list += models.map { JudgeBackend(kind: .lmStudio, modelID: $0) }
        }
        if let models = try? await JudgeService.ollamaVisionModels() {
            list += models.map { JudgeBackend(kind: .ollama, modelID: $0) }
        }
        localServerReachable = !list.isEmpty
        // Cloud model list comes from cache — never read the Keychain here
        // (launch/activation must not trigger the macOS keychain prompt).
        // refreshCloudModels() updates the cache on key save / cloud use.
        var aiModels = UserDefaults.standard.stringArray(forKey: "aistudio.models") ?? []
        if aiModels.isEmpty { aiModels = JudgeBackend.aiStudioModels }
        list += aiModels.map { JudgeBackend(kind: .aiStudio, modelID: $0) }
        backends = list
        if selectedBackend == nil {
            selectedBackendID = recommendedBackendID ?? list.first?.id ?? ""
        }
    }

    // MARK: - Scanning

    func startScan() {
        scanTask?.cancel()
        clusters = []
        decisions = [:]
        verdicts = [:]
        judgeStates = [:]
        selectedClusterID = nil

        let start: Date?
        let end: Date?
        if scanRange == .custom {
            start = Calendar.current.startOfDay(for: customStart)
            // include the whole end day
            end = Calendar.current.date(
                byAdding: .day, value: 1,
                to: Calendar.current.startOfDay(for: customEnd))
        } else {
            start = scanRange.startDate
            end = nil
        }
        scanTask = Task {
            await self.scan(start: start, end: end)
        }
    }

    private func scan(start: Date?, end: Date?) async {
        let scanStarted = Date()
        let assets = PhotoLibraryService.fetchImageAssets(since: start, until: end)
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })

        let timed = assets.map { TimedItem(id: $0.localIdentifier, date: $0.creationDate) }
        let candidateGroups = ClusterEngine.temporalGroups(timed, maxGap: Self.temporalGapSeconds)
            .filter { $0.count >= 2 }

        scanState = .scanning(done: 0, total: candidateGroups.count)

        var found: [PhotoCluster] = []
        // Publish sidebar updates at most ~2x/second. Reassigning `clusters`
        // per group (231 sorted top-inserts in seconds) floods SwiftUI's List
        // diffing on the main thread and freezes the UI if the user interacts
        // mid-scan.
        var lastPublish = Date.distantPast
        for (index, group) in candidateGroups.enumerated() {
            if Task.isCancelled { return }

            // Feature prints for every photo in the temporal group.
            var prints: [String: VNFeaturePrintObservation] = [:]
            await withTaskGroup(of: (String, VNFeaturePrintObservation?, NativeSignals?).self) { taskGroup in
                for item in group {
                    guard let asset = byID[item.id] else { continue }
                    taskGroup.addTask {
                        let image = await PhotoLibraryService.loadImage(
                            for: asset, maxDimension: Self.featurePrintSize)
                        guard let cg = image?.cgImageForVision else { return (item.id, nil, nil) }
                        // Vision can hang forever on a pathological photo; one
                        // bad image must never stall the whole scan.
                        return await Self.withVisionTimeout(photoID: item.id) {
                            (item.id, VisionSimilarity.featurePrint(for: cg),
                             NativeSignals.compute(for: cg))
                        } ?? (item.id, nil, nil)
                    }
                }
                for await (id, print, signals) in taskGroup {
                    prints[id] = print
                    if let signals { signalsByID[id] = signals }
                }
            }

            // Split the temporal group into visually coherent subclusters.
            let ids = group.map(\.id)
            let subclusters = ClusterEngine.visualSubclusters(
                ids, threshold: Self.visualDistanceThreshold
            ) { a, b in
                guard let fa = prints[a], let fb = prints[b] else { return nil }
                return VisionSimilarity.distance(fa, fb)
            }

            for sub in subclusters where sub.count >= 2 {
                let items = sub.compactMap { id -> PhotoItem? in
                    guard let asset = byID[id] else { return nil }
                    return PhotoItem(id: id, creationDate: asset.creationDate)
                }
                guard items.count >= 2 else { continue }
                found.append(PhotoCluster(id: items[0].id, items: items))
            }

            scanState = .scanning(done: index + 1, total: candidateGroups.count)
            if Date().timeIntervalSince(lastPublish) > 0.5 {
                clusters = Self.newestFirst(found)
                lastPublish = Date()
                await Task.yield()   // let the UI breathe between batches
            }
        }

        clusters = Self.newestFirst(found)
        scanState = .finished(clusters: found.count, photosScanned: assets.count)
        Telemetry.send("scan_completed", [
            "photos_scanned_bucket": Buckets.photos(assets.count),
            "groups_found_bucket": Buckets.groups(found.count),
            "library_size_bucket": Buckets.library(PhotoLibraryService.libraryImageCount()),
            "duration_bucket": Buckets.seconds(Date().timeIntervalSince(scanStarted)),
        ])
    }

    /// Runs Vision work with a hard deadline. A pathological photo can hang
    /// VNImageRequestHandler forever; the scan must survive that. On timeout
    /// the photo is skipped (no feature print, no signals) and logged. The
    /// wedged thread stays parked in the cooperative pool — bounded, one per
    /// bad photo, and Vision usually errors out eventually.
    private static func withVisionTimeout(
        photoID: String,
        seconds: TimeInterval = visionTimeoutSeconds,
        _ work: @escaping () -> (String, VNFeaturePrintObservation?, NativeSignals?)
    ) async -> (String, VNFeaturePrintObservation?, NativeSignals?)? {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "whittle.vision-timeout")
            var finished = false
            DispatchQueue.global(qos: .userInitiated).async {
                let result = work()
                queue.sync {
                    guard !finished else { return }
                    finished = true
                    continuation.resume(returning: result)
                }
            }
            queue.asyncAfter(deadline: .now() + seconds) {
                guard !finished else { return }
                finished = true
                Log.info("Vision hung on photo \(photoID) — skipping it")
                continuation.resume(returning: nil)
            }
        }
    }

    private static func newestFirst(_ clusters: [PhotoCluster]) -> [PhotoCluster] {
        clusters.sorted {
            ($0.items.first?.creationDate ?? .distantPast) >
            ($1.items.first?.creationDate ?? .distantPast)
        }
    }

    // MARK: - Judging

    private var judgeTasks: [String: Task<Void, Never>] = [:]

    func judge(cluster: PhotoCluster) {
        if case .loading = judgeStates[cluster.id] ?? .idle { return }
        judgeNow(cluster: cluster)
    }

    func cancelJudge(cluster: PhotoCluster) {
        judgeTasks[cluster.id]?.cancel()
        judgeTasks[cluster.id] = nil
        judgeStates[cluster.id] = .idle
    }

    /// Loads judge-sized JPEGs for a cluster, reporting per-photo progress.
    private func loadJPEGs(
        for cluster: PhotoCluster,
        onProgress: (Int, Int) -> Void
    ) async throws -> [Data] {
        let assets = PhotoLibraryService.fetchAssets(withIdentifiers: cluster.items.map(\.id))
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        var jpegs: [Data] = []
        for (i, item) in cluster.items.enumerated() {
            onProgress(i + 1, cluster.items.count)
            guard let asset = assetsByID[item.id],
                  let image = await PhotoLibraryService.loadImage(
                      for: asset, maxDimension: Self.judgeImageSize),
                  let jpeg = await Self.encodeJPEG(image) else {
                throw JudgeService.JudgeError.server("Could not load photo \(i + 1) for judging.")
            }
            jpegs.append(jpeg)
        }
        return jpegs
    }

    /// JPEG encoding is CPU-bound; running it on the main actor stalls the UI
    /// mid-scan (the old 31/90 freeze pattern). Encode on a worker thread.
    private nonisolated static func encodeJPEG(_ image: NSImage) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            image.jpegData(quality: 0.7)
        }.value
    }

    private func judgeNow(cluster: PhotoCluster) {
        judgeTasks[cluster.id] = Task {
            defer { self.judgeTasks[cluster.id] = nil }
            await self.performJudge(cluster: cluster)
        }
    }

    /// Awaitable judge for one cluster; used by the button and the queue.
    private func performJudge(cluster: PhotoCluster) async {
        guard let backend = selectedBackend else {
            judgeStates[cluster.id] = .failed("No model selected — pick one in the dropdown.")
            return
        }
        let started = Date()
        judgeStates[cluster.id] = .loading(stage: "Preparing photos…", startedAt: started)
        let apiKey = backend.isLocal ? nil : aiStudioKey
        if let apiKey, !apiKey.isEmpty,
           UserDefaults.standard.stringArray(forKey: "aistudio.models") == nil {
            Task { await self.refreshCloudModels(key: apiKey) }
        }
        do {
            let jpegs = try await loadJPEGs(for: cluster) { done, total in
                self.judgeStates[cluster.id] = .loading(
                    stage: "Loading photo \(done) of \(total)…", startedAt: started)
            }
            let signals = cluster.items.compactMap { signalsByID[$0.id] }
            self.judgeStates[cluster.id] = .loading(
                stage: "\(backend.shortModelName) (\(backend.localityLabel)) is looking at \(jpegs.count) photos…",
                startedAt: started)
            let verdict = try await JudgeService.judgeCluster(
                jpegs: jpegs,
                signals: signals.count == jpegs.count ? signals : [],
                backend: backend, apiKey: apiKey
            ) { stage in
                await MainActor.run {
                    self.judgeStates[cluster.id] = .loading(stage: stage, startedAt: started)
                }
            }
            self.verdicts[cluster.id] = verdict
            self.judgeStates[cluster.id] = .done
            Telemetry.send("suggest_used", [
                "backend_kind": backend.kind.rawValue,
                "model_name": backend.shortModelName,
                "group_size": cluster.items.count,
                "outcome": "ok",
                "duration_bucket": Buckets.seconds(Date().timeIntervalSince(started)),
            ])
        } catch is CancellationError {
            // cancelJudge already reset the state
        } catch let error as URLError where error.code == .cancelled {
            // ditto
        } catch {
            let source = backend.isLocal ? "Local (\(backend.sourceLabel))" : "Cloud (AI Studio)"
            self.judgeStates[cluster.id] = .failed("\(source): \(error.localizedDescription)")
            let ns = error as NSError
            let errorClass = "\(ns.domain).\(ns.code)"
            Telemetry.send("suggest_used", [
                "backend_kind": backend.kind.rawValue,
                "model_name": backend.shortModelName,
                "group_size": cluster.items.count,
                "outcome": error is DecodingError ? "parse_error" : "http_error",
            ])
            Telemetry.send("telemetry_error", [
                "component": "judge",
                "error_class": errorClass,
            ])
        }
    }

    // MARK: - Suggest all

    var suggestAllRunning: Bool { suggestAllTask != nil && suggestAllTotal > 0 }

    /// Judges every cluster without a verdict, one at a time (kind to RAM),
    /// then posts a notification.
    func suggestAll() {
        guard suggestAllTask == nil else { return }
        let pending = clusters.filter { verdicts[$0.id] == nil }
        guard !pending.isEmpty else { return }
        suggestAllDone = 0
        suggestAllTotal = pending.count
        suggestAllTask = Task {
            defer {
                self.suggestAllTask = nil
                self.suggestAllTotal = 0
            }
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            for cluster in pending {
                if Task.isCancelled { return }
                if self.verdicts[cluster.id] == nil {
                    await self.performJudge(cluster: cluster)
                }
                self.suggestAllDone += 1
            }
            let content = UNMutableNotificationContent()
            content.title = "Suggestions ready"
            content.body = "Reviewed \(self.suggestAllDone) photo groups — open the app to decide."
            content.sound = .default
            try? await center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
            Log.info("suggest-all finished: \(self.suggestAllDone) clusters")
        }
    }

    func cancelSuggestAll() {
        suggestAllTask?.cancel()
        suggestAllTask = nil
        suggestAllTotal = 0
    }


    // MARK: - Decisions & deletion

    /// Clusters already reported as decided, so accept/override fires once.
    private var telemetryReportedClusters: Set<String> = []

    func setDecision(_ decision: Decision, for itemID: String) {
        decisions[itemID] = decision
        // Manual decisions: report "overridden" the moment a judged cluster
        // becomes fully resolved (acceptSuggestion reports "accepted" itself).
        guard decision != .undecided,
              let cluster = selectedCluster,
              cluster.items.contains(where: { $0.id == itemID }),
              isResolved(cluster),
              verdicts[cluster.id] != nil,
              !telemetryReportedClusters.contains(cluster.id)
        else { return }
        telemetryReportedClusters.insert(cluster.id)
        var props: [String: Any] = ["decision": "overridden"]
        if let backend = selectedBackend {
            props["backend_kind"] = backend.kind.rawValue
            props["model_name"] = backend.shortModelName
        }
        Telemetry.send("suggestion_decided", props)
    }

    func clearDiscards() {
        for (id, decision) in decisions where decision == .discard {
            decisions[id] = .undecided
        }
    }

    /// Deletes all photos the user marked Discard. macOS shows a system
    /// confirmation dialog before anything is removed.
    func deleteDiscarded() async {
        let ids = discardedIDs
        guard !ids.isEmpty else { return }
        let bytes = PhotoLibraryService.totalFileSize(ofAssetsWithIdentifiers: ids)
        do {
            try await PhotoLibraryService.deleteAssets(withIdentifiers: ids)
            let removed = Set(ids)
            for id in removed {
                decisions.removeValue(forKey: id)
                signalsByID.removeValue(forKey: id)
            }
            let survivingClusterIDs = Set(clusters.compactMap { cluster -> String? in
                var c = cluster
                c.items.removeAll { removed.contains($0.id) }
                return c.items.count >= 2 ? c.id : nil
            })
            clusters = clusters.compactMap { cluster in
                var c = cluster
                c.items.removeAll { removed.contains($0.id) }
                return c.items.count >= 2 ? c : nil
            }
            for staleID in verdicts.keys where !survivingClusterIDs.contains(staleID) {
                verdicts.removeValue(forKey: staleID)
                judgeStates.removeValue(forKey: staleID)
            }
            if let selected = selectedClusterID, !clusters.contains(where: { $0.id == selected }) {
                selectedClusterID = nil
            }
            totalDeleted += ids.count
            totalBytesFreed += bytes
            UserDefaults.standard.set(totalDeleted, forKey: "tally.deleted")
            UserDefaults.standard.set(Int(totalBytesFreed), forKey: "tally.bytes")
            Telemetry.send("photos_deleted", [
                "count": ids.count,
                "bytes_freed": bytes,
                "running_total_count": totalDeleted,
                "running_total_bytes": totalBytesFreed,
            ])
        } catch {
            let ns = error as NSError
            // User canceling the system dialog is not an error worth showing.
            if ns.domain == PHPhotosErrorDomain,
               ns.code == PHPhotosError.userCancelled.rawValue { return }
            deleteError = error.localizedDescription
        }
    }
}
