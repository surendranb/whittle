import Photos
import SwiftUI

/// The one owned accent: everything suggestion-related is amber.
/// Decisions stay semantic green/red; system blue is not used.
let whittleAmber = Color(red: 1.0, green: 0.75, blue: 0.20)

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showWelcome = Telemetry.consent == .undecided

    var body: some View {
        Group {
            switch model.authStatus {
            case .authorized, .limited:
                MainView()
            case .notDetermined:
                PermissionRequestView()
            default:
                PermissionDeniedView()
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .task { await model.refreshModels() }
        .sheet(isPresented: $showWelcome) {
            WelcomeSheet { optedIn in
                if optedIn { Telemetry.optIn() } else { Telemetry.optOut() }
                showWelcome = false
            }
        }
    }
}

/// First-run consent for anonymous usage telemetry. Shows once; dismissing
/// is impossible, so "Start using Whittle" always resolves consent — the
/// footer toggle is the permanent control from then on.
struct WelcomeSheet: View {
    @State private var telemetryOn = true
    let onDone: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Whittle")
                    .font(.title.bold())
                    .foregroundStyle(ink)
                Text("Whittle helps you find bursts of near-identical photos and suggests the best one to keep. Works with local or cloud-based models.")
                    .font(.callout)
                    .foregroundStyle(ink.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                onDone(telemetryOn)
            } label: {
                Text("Get Started")
                    .font(.body.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ink)
            .background(whittleAmber, in: RoundedRectangle(cornerRadius: 12))
            .keyboardShortcut(.defaultAction)

            Divider()

            HStack(alignment: .center, spacing: 8) {
                Text("We collect anonymous telemetry to improve the product.")
                Link("Read more", destination: URL(string: "https://whittle.builditwithai.xyz/privacy")!)
                Spacer()
                Toggle("Anonymous usage stats", isOn: $telemetryOn)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Anonymous usage stats (pre-checked; off anytime)")
            }
            .font(.caption2)
            .foregroundStyle(ink.opacity(0.65))
        }
        .padding(28)
        .frame(width: 460)
        .background(cream)
        .interactiveDismissDisabled()
    }
}

/// Happy Hues #17: warm cream surface + ink text.
let cream = Color(red: 0.996, green: 0.965, blue: 0.894)
let ink = Color(red: 0.0, green: 0.094, blue: 0.345)

struct PermissionRequestView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Access to your Photos library")
                .font(.title2.bold())
            Text("Needed to find bursts of similar shots. Nothing is deleted without your click and a macOS confirmation.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Grant Access…") {
                Task { await model.requestAccess() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }
}

struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Photos access is denied")
                .font(.title2.bold())
            Text("Enable it in System Settings → Privacy & Security → Photos, then relaunch.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(40)
    }
}

// MARK: - Main split view

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            if let cluster = model.selectedCluster {
                ClusterDetailView(cluster: cluster)
                    .id(cluster.id)
            } else {
                EmptyDetailView()
            }
        }
        .safeAreaInset(edge: .top) { FirstRunBanner() }
        .alert("Couldn't delete photos", isPresented: Binding(
            get: { model.deleteError != nil },
            set: { if !$0 { model.deleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.deleteError ?? "")
        }
    }
}

/// Shown until the user has at least one way to get suggestions.
/// Scanning and manual review work fine without any model.
struct FirstRunBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if !model.localServerReachable && !model.hasAIStudioKey {
            HStack(spacing: 10) {
                Image(systemName: "lightbulb")
                Text("For AI suggestions, run a local vision model in **LM Studio** or **Ollama** (try qwen3-vl-4b), or add a free **Google AI Studio** key — everything else works without one.")
                    .font(.callout)
                Spacer()
                Link("Get LM Studio", destination: URL(string: "https://lmstudio.ai")!)
                Link("Get a key", destination: URL(string: "https://aistudio.google.com/apikey")!)
                Button("Re-check") { Task { await model.refreshModels() } }
                    .controlSize(.small)
            }
            .padding(10)
            .background(whittleAmber.opacity(0.12))
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScanControls()
            Divider()
            if model.clusters.isEmpty {
                Spacer()
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List(model.clusters, selection: $model.selectedClusterID) { cluster in
                        ClusterRow(cluster: cluster)
                            .tag(cluster.id)
                            .id(cluster.id)
                    }
                    .listStyle(.sidebar)
                    .onChange(of: model.selectedClusterID) { _, newID in
                        if let newID {
                            withAnimation { proxy.scrollTo(newID) }
                        }
                    }
                }
            }
            StagingFooter()
            if model.totalDeleted > 0 {
                Divider()
                Label(
                    "\(model.totalDeleted) photos cleared · \(ByteCountFormatter.string(fromByteCount: model.totalBytesFreed, countStyle: .file)) freed",
                    systemImage: "sparkle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .help("All-time tally of photos you've deleted through this app")
            }
            AboutFooter()
        }
    }

    private var emptyMessage: String {
        switch model.scanState {
        case .idle: return "Pick a range and press Scan\nto find burst photos."
        case .scanning: return "Scanning…"
        case .finished: return "No burst photos found\nin this range. 🎉"
        case .failed(let msg): return "Scan failed: \(msg)"
        }
    }
}

/// The whole range selection in one control: a menu of presets plus
/// "Custom range…", whose dates then become the menu's own label.
struct RangeMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var showDates = false

    var body: some View {
        Menu {
            ForEach(ScanRange.allCases.filter { $0 != .custom }) { range in
                Button(range.rawValue) { model.scanRange = range }
            }
            Divider()
            Button(model.scanRange == .custom ? "Edit custom dates…" : "Custom range…") {
                model.scanRange = .custom
                showDates = true
            }
        } label: {
            HStack {
                Image(systemName: "calendar")
                Text(currentLabel)
                    .lineLimit(1)
                Spacer()
            }
        }
        .help(model.scanRange == .custom
              ? "Scanning \(currentLabel) — use the menu to change"
              : "Choose how far back to scan")
        .popover(isPresented: $showDates, arrowEdge: .trailing) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("From").font(.headline)
                    DatePicker("From", selection: $model.customStart,
                               in: ...model.customEnd, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .frame(width: 220)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("To").font(.headline)
                    DatePicker("To", selection: $model.customEnd,
                               in: model.customStart...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .frame(width: 220)
                }
            }
            .padding(16)
        }
    }

    private var currentLabel: String {
        guard model.scanRange == .custom else { return model.scanRange.rawValue }
        let fmt = Date.FormatStyle().month(.abbreviated).day().year()
        return "\(model.customStart.formatted(fmt)) – \(model.customEnd.formatted(fmt))"
    }
}

/// Always-visible sidebar footer: how-it-works explainer + attribution.
struct AboutFooter: View {
    @State private var showInfo = false
    @State private var telemetryOn = Telemetry.consent == .enabled

    var body: some View {
        Divider()
        HStack {
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("How Whittle works")
            .accessibilityLabel("How Whittle works")
            .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("How Whittle works")
                        .font(.headline)
                    Text("""
                    Scanning happens entirely on your Mac: photos taken within \
                    10 seconds of each other are grouped, then Apple's Vision \
                    framework confirms they actually look alike. When you ask \
                    for a suggestion, Whittle sends small copies of that \
                    group's photos (~768px JPEGs) plus measured numbers about \
                    each — sharpness, face count and quality, eyes-open and \
                    smile counts, horizon tilt, scene type — to the model you \
                    chose. A local model keeps everything on this Mac; the \
                    cloud option sends those small copies and numbers to \
                    Google. Originals, names, and locations are never sent \
                    anywhere.

                    The model only suggests. Deleting always takes your click \
                    plus macOS's own confirmation, and deleted photos stay in \
                    Photos' Recently Deleted for 30 days.
                    """)
                    .font(.callout)
                    .frame(width: 340)
                    .fixedSize(horizontal: false, vertical: true)
                    Text("""
                    Anonymous usage counts (photos scanned, deleted, model \
                    used) guide development — never photos, names, or \
                    locations. Full details: whittle.builditwithai.xyz/privacy
                    """)
                    .font(.callout)
                    .frame(width: 340)
                    .fixedSize(horizontal: false, vertical: true)
                    Toggle("Share anonymous usage stats", isOn: $telemetryOn)
                        .toggleStyle(.switch)
                        .onChange(of: telemetryOn) { enabled in
                            if enabled { Telemetry.optIn() } else { Telemetry.optOut() }
                        }
                        .help("Opt in or out of anonymous usage stats")
                }
                .padding(16)
            }
            Spacer()
            Link("a BuildItWithAI project", destination: URL(string: "https://builditwithai.xyz")!)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("builditwithai.xyz — learning AI through building & sharing")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

struct ScanControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RangeMenu()
            Button {
                model.startScan()
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("r")
            .disabled(isScanning)

            switch model.scanState {
            case .scanning(let done, let total):
                ProgressView(value: total > 0 ? Double(done) / Double(total) : 0) {
                    Text("Comparing group \(done) of \(total)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .finished(let clusterCount, let photos):
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(clusterCount) groups · \(photos) photos")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        SuggestAllControl()
                    }
                    if model.reviewedCount > 0 {
                        ProgressView(value: Double(model.reviewedCount),
                                     total: Double(max(model.clusters.count, 1))) {
                            Text("\(model.reviewedCount) of \(model.clusters.count) reviewed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tint(whittleAmber)
                    }
                }
            default:
                EmptyView()
            }
        }
        .padding(12)
    }

    private var isScanning: Bool {
        if case .scanning = model.scanState { return true }
        return false
    }
}

/// Runs the judge over every group in the background, one at a time.
struct SuggestAllControl: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.suggestAllRunning {
            HStack(spacing: 6) {
                ProgressView(value: Double(model.suggestAllDone),
                             total: Double(max(model.suggestAllTotal, 1)))
                    .frame(width: 60)
                Text("\(model.suggestAllDone)/\(model.suggestAllTotal)")
                    .font(.caption)
                    .monospacedDigit()
                Button("Stop") { model.cancelSuggestAll() }
                    .controlSize(.mini)
            }
            .help("Suggesting for every group — you'll get a notification when done")
        } else {
            Button {
                model.suggestAll()
            } label: {
                Label("Suggest all", systemImage: "sparkles")
            }
            .controlSize(.small)
            .disabled(model.clusters.allSatisfy { model.verdicts[$0.id] != nil })
            .help("Get a suggestion for every group in the background; notifies when done")
        }
    }
}

struct ClusterRow: View {
    @EnvironmentObject var model: AppModel
    let cluster: PhotoCluster

    var body: some View {
        let resolved = model.isResolved(cluster)
        // After a verdict, the row's thumbnail is the suggested keeper.
        let thumbID = model.verdicts[cluster.id].flatMap { verdict in
            cluster.items.indices.contains(verdict.keepIndex)
                ? cluster.items[verdict.keepIndex].id : nil
        } ?? cluster.items[0].id

        HStack(spacing: 10) {
            AssetThumbnail(assetID: thumbID, maxDimension: 48)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(cluster.items.count) photos")
                    .font(.body.weight(.medium))
                Text(cluster.dateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if resolved {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Reviewed — every photo has a decision")
                    .accessibilityLabel("Reviewed")
            } else if case .loading = model.judgeStates[cluster.id] ?? .idle {
                ProgressView().controlSize(.mini)
            } else if model.verdicts[cluster.id] != nil {
                Image(systemName: "sparkles")
                    .foregroundStyle(whittleAmber)
                    .help("Suggestion ready")
                    .accessibilityLabel("Suggestion ready")
            }
            let discards = cluster.items.filter { model.decisions[$0.id] == .discard }.count
            if discards > 0 && !resolved {
                Text("\(discards)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .help("\(discards) marked for discard")
            }
        }
        .padding(.vertical, 2)
        .opacity(resolved ? 0.55 : 1)
    }
}

struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Select a group to review it")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Cluster detail

struct ClusterDetailView: View {
    @EnvironmentObject var model: AppModel
    let cluster: PhotoCluster
    @State private var focusedIndex = 0
    @State private var zoomed = false
    @FocusState private var gridFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            JudgePanel(cluster: cluster)
            Divider()
            GeometryReader { geo in
                let count = cluster.items.count
                let cols = max(1, Int(ceil(Double(count).squareRoot())))
                let rows = max(1, Int(ceil(Double(count) / Double(cols))))
                let spacing: CGFloat = 12
                let cellWidth = (geo.size.width - spacing * CGFloat(cols + 1)) / CGFloat(cols)
                let cellHeight = (geo.size.height - spacing * CGFloat(rows + 1)) / CGFloat(rows)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing),
                                   count: cols),
                    spacing: spacing
                ) {
                    ForEach(Array(cluster.items.enumerated()), id: \.element.id) { index, item in
                        PhotoCard(
                            item: item,
                            index: index,
                            isSuggested: model.verdicts[cluster.id]?.keepIndex == index,
                            isFocused: gridFocused && focusedIndex == index,
                            reason: reason(at: index)
                        )
                        .frame(width: cellWidth, height: cellHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { focusedIndex = index }
                    }
                }
                .padding(spacing)
            }
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onAppear { gridFocused = true }
            .onKeyPress { press in handleKey(press) }

            HStack {
                Text("←→ move · space zoom · A accept suggestion · ⏎ keep · ⌫ discard")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .navigationTitle("\(cluster.items.count) photos · \(cluster.dateLabel)")
        .overlay {
            if zoomed, cluster.items.indices.contains(focusedIndex) {
                ZoomOverlay(
                    item: cluster.items[focusedIndex],
                    index: focusedIndex,
                    total: cluster.items.count,
                    reason: reason(at: focusedIndex),
                    onDismiss: { zoomed = false }
                )
            }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let count = cluster.items.count
        switch press.key {
        case .leftArrow:
            focusedIndex = (focusedIndex - 1 + count) % count
            return .handled
        case .rightArrow:
            focusedIndex = (focusedIndex + 1) % count
            return .handled
        case .space:
            zoomed.toggle()
            return .handled
        case .escape:
            if zoomed { zoomed = false; return .handled }
            return .ignored
        case .return:
            toggle(.keep)
            return .handled
        default:
            if press.characters == "\u{7F}" || press.characters == "\u{08}" {
                toggle(.discard)
                return .handled
            }
            switch press.characters.lowercased() {
            case "a":
                if model.verdicts[cluster.id] != nil {
                    model.acceptSuggestion(cluster: cluster)
                    return .handled
                }
                return .ignored
            case "k": toggle(.keep); return .handled
            case "d": toggle(.discard); return .handled
            default: return .ignored
            }
        }
    }

    private func toggle(_ decision: Decision) {
        guard cluster.items.indices.contains(focusedIndex) else { return }
        let id = cluster.items[focusedIndex].id
        let current = model.decisions[id] ?? .undecided
        model.setDecision(current == decision ? .undecided : decision, for: id)
    }

    private func reason(at index: Int) -> String? {
        guard let verdict = model.verdicts[cluster.id],
              index < verdict.reasons.count,
              !verdict.reasons[index].isEmpty else { return nil }
        return verdict.reasons[index]
    }
}

/// Space-bar zoom: Quick Look-style close inspection of the focused photo.
/// Arrows keep working (the overlay follows focus); Space/Esc/click dismiss.
struct ZoomOverlay: View {
    let item: PhotoItem
    let index: Int
    let total: Int
    let reason: String?
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.92)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
            AssetThumbnail(assetID: item.id, maxDimension: 1200, fit: true)
                .padding(24)
                .onTapGesture { onDismiss() }
            HStack {
                Text("Photo \(index + 1) of \(total)")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white)
                Spacer()
                if let reason {
                    Text(reason)
                        .font(.callout)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(16)
        }
        .transition(.opacity)
        .accessibilityLabel("Zoomed view of photo \(index + 1)")
    }
}

// MARK: - Staged deletions

/// The global staging area: photos marked for discard across all groups wait
/// here until the user reviews and commits. Per-group state stays on the
/// photos themselves (red borders).
struct StagingFooter: View {
    @EnvironmentObject var model: AppModel
    @State private var showReview = false

    var body: some View {
        let total = model.discardedIDs.count
        if total > 0 {
            Divider()
            HStack {
                Label("\(total) staged for deletion", systemImage: "trash")
                    .font(.callout)
                    .foregroundStyle(.red)
                Spacer()
                Button("Review…") { showReview = true }
                    .controlSize(.small)
                    .help("See exactly which photos will be deleted, remove any, then delete")
            }
            .padding(10)
            .popover(isPresented: $showReview, arrowEdge: .trailing) {
                StagedReviewPopover()
                    .environmentObject(model)
            }
        }
    }
}

struct StagedReviewPopover: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false

    private var staged: [PhotoItem] {
        model.clusters.flatMap(\.items).filter { model.decisions[$0.id] == .discard }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("These photos will be deleted")
                .font(.headline)
            Text("Click ✕ to keep one after all. Deleting asks macOS to confirm; photos go to Recently Deleted for 30 days.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 316, alignment: .leading)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                    ForEach(staged) { item in
                        ZStack(alignment: .topTrailing) {
                            AssetThumbnail(assetID: item.id, maxDimension: 72)
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                            Button {
                                model.setDecision(.undecided, for: item.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(3)
                            .help("Remove from deletion — keeps the photo")
                            .accessibilityLabel("Keep this photo after all")
                        }
                    }
                }
            }
            .frame(width: 316, height: min(240, CGFloat((staged.count / 4 + 1) * 82)))
            HStack {
                Button("Clear all") {
                    model.clearDiscards()
                    dismiss()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    deleting = true
                    Task {
                        await model.deleteDiscarded()
                        deleting = false
                        dismiss()
                    }
                } label: {
                    Label(deleting ? "Deleting…" : "Delete \(staged.count) photo\(staged.count == 1 ? "" : "s")…",
                          systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(deleting || staged.isEmpty)
            }
        }
        .padding(14)
    }
}

// MARK: - Judge panel

struct JudgePanel: View {
    @EnvironmentObject var model: AppModel
    let cluster: PhotoCluster

    var body: some View {
        HStack(spacing: 12) {
            statusView
            Spacer()
            ModelChip()
            actionButtons
        }
        .padding(12)
    }

    /// Verdict only — the *reason* lives on the photo itself, once.
    @ViewBuilder
    private var statusView: some View {
        switch model.judgeStates[cluster.id] ?? .idle {
        case .idle:
            Label("No suggestion yet", systemImage: "sparkles")
                .foregroundStyle(.secondary)
        case .loading(let stage, let startedAt):
            ProgressView()
                .progressViewStyle(.linear)
                .frame(width: 120)
            VStack(alignment: .leading, spacing: 1) {
                Text(stage)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(startedAt))))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        case .failed(let message):
            Label {
                Text(message)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
            .help(message)
        case .done:
            if let verdict = model.verdicts[cluster.id] {
                let reason = verdict.reasons.indices.contains(verdict.keepIndex)
                    ? verdict.reasons[verdict.keepIndex] : ""
                Text(reason.isEmpty
                     ? "Photo \(verdict.keepIndex + 1) looks like the keeper"
                     : "Photo \(verdict.keepIndex + 1) — \(reason.prefix(1).lowercased() + reason.dropFirst())")
                    .foregroundStyle(whittleAmber)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .help(reason)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch model.judgeStates[cluster.id] ?? .idle {
        case .loading:
            Button("Cancel") {
                model.cancelJudge(cluster: cluster)
            }
        case .done where model.verdicts[cluster.id] != nil:
            // Post-verdict: Accept is the job; re-judging is the exception.
            Button {
                model.judge(cluster: cluster)
            } label: {
                Label("Suggest again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Ask the model again")

            AmberButton(
                title: "Accept",
                systemImage: "checkmark.seal.fill",
                help: "Keep the suggested photo, discard the rest, go to the next group (A)"
            ) {
                model.acceptSuggestion(cluster: cluster)
            }
            .accessibilityLabel("Accept suggestion")
        default:
            AmberButton(
                title: "Suggest",
                systemImage: "sparkles",
                help: "Ask the model which photo to keep"
            ) {
                model.judge(cluster: cluster)
            }
            .disabled(model.selectedBackend == nil)
            .accessibilityLabel("Get a suggestion")
        }
    }
}

/// The one prominent action, in the app's own amber.
struct AmberButton: View {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(whittleAmber)
        .help(help)
    }
}

/// One compact chip = current model + reachability. The popover holds all
/// configuration: model choice, server status, API key, server addresses.
struct ModelChip: View {
    @EnvironmentObject var model: AppModel
    @State private var showPopover = false
    @State private var keyDraft = ""
    @State private var lmStudio = ServerConfig.lmStudioOrigin
    @State private var ollama = ServerConfig.ollamaOrigin
    @State private var serverError: String?
    @State private var showPromptEditor = false

    var body: some View {
        Button {
            keyDraft = ""
            lmStudio = ServerConfig.lmStudioOrigin
            ollama = ServerConfig.ollamaOrigin
            showPopover = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(chipReady ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(model.selectedBackend?.friendlyModelName ?? "Choose model")
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .help(model.selectedBackend.map {
            "\($0.friendlyModelName) — \($0.isLocal ? "runs on this Mac" : "cloud (AI Studio)")"
        } ?? "Choose which model makes suggestions")
        .accessibilityLabel("Model settings")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var chipReady: Bool {
        guard let backend = model.selectedBackend else { return false }
        return backend.isLocal || model.hasAIStudioKey
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Model choice
            VStack(alignment: .leading, spacing: 6) {
                Text("Model").font(.headline)
                Picker("Model", selection: $model.selectedBackendID) {
                    let locals = model.backends.filter(\.isLocal)
                    let clouds = model.backends.filter { !$0.isLocal }
                    if !locals.isEmpty {
                        Section("On this Mac — private, free") {
                            ForEach(locals) { backend in
                                Text(backend.id == model.recommendedBackendID
                                     ? "★ \(backend.displayName)"
                                     : backend.displayName)
                                    .tag(backend.id)
                            }
                        }
                    }
                    if !clouds.isEmpty {
                        Section("Cloud — photos leave this Mac") {
                            ForEach(clouds) { backend in
                                Text(backend.displayName).tag(backend.id)
                            }
                        }
                    }
                }
                .labelsHidden()
            }

            Divider()

            // Server status
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Servers").font(.headline)
                    Spacer()
                    Button("Re-check") { Task { await model.refreshModels() } }
                        .controlSize(.small)
                }
                statusRow("LM Studio", up: model.backends.contains { $0.kind == .lmStudio })
                statusRow("Ollama", up: model.backends.contains { $0.kind == .ollama })
                statusRow("AI Studio key", up: model.hasAIStudioKey)
                TextField("LM Studio address", text: $lmStudio,
                          prompt: Text(ServerConfig.lmStudioDefault))
                    .textFieldStyle(.roundedBorder)
                TextField("Ollama address", text: $ollama,
                          prompt: Text(ServerConfig.ollamaDefault))
                    .textFieldStyle(.roundedBorder)
                if let serverError {
                    Text(serverError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            // API key
            VStack(alignment: .leading, spacing: 6) {
                Text("Google AI Studio key").font(.headline)
                Text("Stored in your macOS Keychain — macOS may show its own permission dialog when a cloud model first runs; choose \u{201C}Always Allow\u{201D}. Free key at aistudio.google.com.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    SecureField(model.hasAIStudioKey ? "•••••••• (key is set)" : "Paste key…",
                                text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                    if model.hasAIStudioKey {
                        Button("Remove", role: .destructive) {
                            model.setAIStudioKey("")
                        }
                        .controlSize(.small)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Judging instructions").font(.headline)
                    if JudgeService.customCriteria != nil {
                        Text("customized")
                            .font(.caption)
                            .foregroundStyle(whittleAmber)
                    }
                    Spacer()
                    Button("Edit…") { showPromptEditor = true }
                        .controlSize(.small)
                }
                Text("What the model is told to judge. The JSON output format is fixed and appended automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Save") {
                    // Local servers must be on this Mac — that's the promise
                    // behind "photos never leave your Mac" with a local model.
                    guard ServerConfig.normalizedLocalOrigin(lmStudio, fallback: ServerConfig.lmStudioDefault) != nil,
                          ServerConfig.normalizedLocalOrigin(ollama, fallback: ServerConfig.ollamaDefault) != nil
                    else {
                        serverError = "Server addresses must be on this Mac — 127.0.0.1 or localhost. Local models are what keep photos on-device."
                        return
                    }
                    serverError = nil
                    ServerConfig.lmStudioOrigin = lmStudio
                    ServerConfig.ollamaOrigin = ollama
                    if !keyDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                        model.setAIStudioKey(keyDraft)
                    }
                    showPopover = false
                    Task { await model.refreshModels() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .sheet(isPresented: $showPromptEditor) {
            PromptEditorSheet()
        }
    }

    private func statusRow(_ name: String, up: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(up ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(name)
                .font(.callout)
            Spacer()
            Text(up ? "ready" : "not found")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Edit the judging criteria; the output contract stays fixed.
struct PromptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = JudgeService.customCriteria ?? JudgeService.defaultCriteria

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Judging instructions")
                .font(.title3.bold())
            Text("Tell the model what makes a photo worth keeping — e.g. prefer candid over posed, never keep underexposed shots. \u{201C}{count}\u{201D} becomes the number of photos. The JSON output format and measured sharpness data are appended automatically and can't be broken from here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(width: 520, height: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Button("Reset to default") {
                    text = JudgeService.defaultCriteria
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    JudgeService.customCriteria = text
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(whittleAmber)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

// MARK: - Photo card

struct PhotoCard: View {
    @EnvironmentObject var model: AppModel
    let item: PhotoItem
    let index: Int
    let isSuggested: Bool
    let isFocused: Bool
    let reason: String?

    private var decision: Decision { model.decisions[item.id] ?? .undecided }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .overlay(AssetThumbnail(assetID: item.id, maxDimension: 480))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // clipShape hides the scaledToFill overflow but does NOT clip
                // hit-testing — without this, a wide photo's invisible spill
                // covers the neighboring card's buttons.
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .opacity(decision == .discard ? 0.4 : 1)

            // top-left badges
            VStack {
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.headline)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                    if isSuggested {
                        Label("Suggested", systemImage: "sparkles")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(whittleAmber, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    Spacer()
                }
                .padding(8)
                Spacer()
            }

            // bottom overlay: one-line reason pill left, decision buttons right
            HStack(alignment: .bottom, spacing: 8) {
                if let reason {
                    Text(reason)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(reason)
                        .shadow(color: .black.opacity(0.8), radius: 1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.65), in: Capsule())
                }
                Spacer(minLength: 4)
                roundButton(system: "checkmark", tint: .green,
                            active: decision == .keep,
                            label: "Keep photo \(index + 1)", help: "Keep (⏎)") {
                    set(.keep)
                }
                roundButton(system: "trash", tint: .red,
                            active: decision == .discard,
                            label: "Discard photo \(index + 1)", help: "Discard (⌫)") {
                    set(.discard)
                }
            }
            .padding(10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: isFocused ? 4 : 3)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo \(index + 1)\(isSuggested ? ", suggested" : "")")
    }

    private func set(_ d: Decision) {
        model.setDecision(decision == d ? .undecided : d, for: item.id)
    }

    private func roundButton(system: String, tint: Color, active: Bool,
                             label: String, help: String,
                             action: @escaping () -> Void) -> some View {
        HoverFillButton(system: system, tint: tint, active: active, action: action)
            .help(help)
            .accessibilityLabel(label)
    }

    private var borderColor: Color {
        if isFocused { return .white.opacity(0.9) }
        switch decision {
        case .keep: return .green
        case .discard: return .red
        case .undecided: return isSuggested ? whittleAmber : .clear
        }
    }
}

struct HoverFillButton: View {
    let system: String
    let tint: Color
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 38, height: 38)
                .background(
                    Circle().fill(active ? tint : (hovering ? tint.opacity(0.65) : Color.black.opacity(0.5)))
                )
                .overlay(Circle().strokeBorder(tint, lineWidth: active ? 0 : 1.5))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Async thumbnail

struct AssetThumbnail: View {
    let assetID: String
    let maxDimension: CGFloat
    var fit = false

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fit ? .fit : .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: assetID) {
            let assets = PhotoLibraryService.fetchAssets(withIdentifiers: [assetID])
            guard let asset = assets.first else { return }
            image = await PhotoLibraryService.loadImage(for: asset, maxDimension: maxDimension * 2)
        }
    }
}
