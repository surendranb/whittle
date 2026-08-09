import Foundation

/// Anonymous, opt-out usage telemetry. Contract: docs/internal/2026-08-09-analytics-model.md.
/// Everything the app knows about your library is computed here; only these
/// bucketed counts ever leave, and only after you opted in on first run.
enum Telemetry {
    enum Consent: String { case undecided, enabled, disabled }

    private static let defaults = UserDefaults.standard
    private static let consentKey = "telemetry.consent"
    private static let installIDKey = "telemetry.installID"
    private static let bufferKey = "telemetry.buffer"
    private static let schemaVersion = "1"
    private static let relay = URL(string: "https://whittle.builditwithai.xyz/e")!
    private static let maxBuffered = 50

    static var consent: Consent {
        get { Consent(rawValue: defaults.string(forKey: consentKey) ?? "") ?? .undecided }
        set { defaults.set(newValue.rawValue, forKey: consentKey) }
    }

    private static var installID: String? {
        defaults.string(forKey: installIDKey)
    }

    /// First-run opt-in (from the welcome sheet). Mints the install ID and
    /// records first_boot exactly once per identity.
    static func optIn() {
        guard consent != .enabled else { return }
        consent = .enabled
        if installID == nil {
            defaults.set(UUID().uuidString.lowercased(), forKey: installIDKey)
        }
        send("first_boot")
    }

    /// Opt-out: wipes the identity and the buffer. Re-enabling later mints a
    /// fresh ID — old data can never be relinked.
    static func optOut() {
        consent = .disabled
        defaults.removeObject(forKey: installIDKey)
        defaults.removeObject(forKey: bufferKey)
    }

    /// App launch heartbeat. Safe on every launch; no-ops unless opted in.
    static func boot() {
        guard consent == .enabled else { return }
        send("boot")
    }

    /// Single chokepoint: every event routes through here. Nothing is ever
    /// sent (or buffered) unless consent is enabled.
    static func send(_ event: String, _ properties: [String: Any] = [:]) {
        guard consent == .enabled, let id = installID else { return }

        var props = envelope()
        for (k, v) in properties { props[k] = v }

        let entry: [String: Any] = [
            "event": event,
            "distinct_id": id,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "properties": props,
        ]
        var buffer = buffered()
        buffer.append(entry)
        if buffer.count > maxBuffered { buffer.removeFirst(buffer.count - maxBuffered) }
        store(buffer)
        if buffer.count >= 10 { flush() }
    }

    private static func envelope() -> [String: Any] {
        var arch = "unknown"
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            "os_version": "\(os.majorVersion).\(os.minorVersion)",
            "arch": arch,
            "locale": Locale.current.identifier,
            "tz_offset_minutes": TimeZone.current.secondsFromGMT() / 60,
            "schema_version": schemaVersion,
        ]
    }

    // MARK: - Buffer

    /// In-memory + UserDefaults staging so short offline windows don't lose
    /// events; capped so a dead network can't grow the store forever.
    private static func buffered() -> [[String: Any]] {
        guard let data = defaults.data(forKey: bufferKey),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return list
    }

    private static func store(_ entries: [[String: Any]]) {
        if let data = try? JSONSerialization.data(withJSONObject: entries) {
            defaults.set(data, forKey: bufferKey)
        }
    }

    /// Flush the buffer to the relay. Fire-and-forget; on success the buffer
    /// clears, on failure it stays for the next flush.
    static func flush() {
        let entries = buffered()
        guard !entries.isEmpty else { return }
        let request = postRequest(entries, timeout: 15)
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 202
            else { return }
            defaults.removeObject(forKey: bufferKey)
        }.resume()
    }

    /// Synchronous flush at shutdown — the process dies right after, so an
    /// async task would never complete. Blocks at most ~6s; on failure the
    /// buffer stays for the next launch.
    static func flushBeforeQuit() {
        let entries = buffered()
        guard !entries.isEmpty else { return }
        let request = postRequest(entries, timeout: 5)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 202
            else { return }
            defaults.removeObject(forKey: bufferKey)
        }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    private static func postRequest(_ entries: [[String: Any]], timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: relay)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = timeout
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["events": entries])
        return request
    }
}

/// Counts and durations are bucketed on-device; exact values never leave.
enum Buckets {
    static func photos(_ n: Int) -> String {
        switch n {
        case ..<50: return "0-49"
        case ..<200: return "50-199"
        case ..<1000: return "200-999"
        case ..<5000: return "1000-4999"
        default: return "5000+"
        }
    }

    static func groups(_ n: Int) -> String {
        switch n {
        case ..<5: return "0-4"
        case ..<20: return "5-19"
        case ..<100: return "20-99"
        case ..<500: return "100-499"
        default: return "500+"
        }
    }

    static func library(_ n: Int) -> String {
        switch n {
        case ..<1000: return "0-999"
        case ..<5000: return "1000-4999"
        case ..<20000: return "5000-19999"
        case ..<100000: return "20000-99999"
        default: return "100000+"
        }
    }

    static func seconds(_ t: TimeInterval) -> String {
        switch t {
        case ..<5: return "0-4s"
        case ..<15: return "5-14s"
        case ..<60: return "15-59s"
        case ..<300: return "1-4m"
        default: return "5m+"
        }
    }
}
