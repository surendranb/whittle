import Foundation
import Security

/// A selectable judge backend: a model on a local OpenAI-compatible server
/// (LM Studio or Ollama) or a Gemma model on Google AI Studio (Gemini API).
struct JudgeBackend: Identifiable, Hashable {
    enum Kind: String {
        case lmStudio
        case ollama
        case aiStudio
    }

    let kind: Kind
    let modelID: String

    var id: String { "\(kind.rawValue)|\(modelID)" }

    var isLocal: Bool { kind != .aiStudio }

    /// Base URL for local OpenAI-compatible servers (user-configurable).
    var localBaseURL: URL? {
        switch kind {
        case .lmStudio: return URL(string: ServerConfig.lmStudioOrigin + "/v1")
        case .ollama: return URL(string: ServerConfig.ollamaOrigin + "/v1")
        case .aiStudio: return nil
        }
    }

    var shortModelName: String {
        modelID.split(separator: "/").last.map(String.init) ?? modelID
    }

    var sourceLabel: String {
        switch kind {
        case .lmStudio: return "LM Studio"
        case .ollama: return "Ollama"
        case .aiStudio: return "AI Studio"
        }
    }

    var displayName: String { "\(friendlyModelName) (\(sourceLabel))" }

    /// "qwen3-vl-4b" → "Qwen3 VL 4B", "gemini-flash-lite-latest" → "Gemini Flash Lite".
    var friendlyModelName: String {
        var name = shortModelName
        for suffix in ["-latest", "-it", "-instruct", "-qat"] {
            name = name.replacingOccurrences(of: suffix, with: "")
        }
        return name.split(separator: "-").map { token -> String in
            let t = String(token)
            if t.range(of: "^[0-9]+(b|k|m)$", options: [.regularExpression, .caseInsensitive]) != nil {
                return t.uppercased()
            }
            if t.count <= 3 && t.allSatisfy(\.isLetter) && t != "pro" {
                return t.uppercased()   // vl, glm → VL, GLM
            }
            return t.prefix(1).uppercased() + t.dropFirst()
        }.joined(separator: " ")
    }

    /// Used in status and error messages so local vs cloud is unmistakable.
    var localityLabel: String { isLocal ? "on this Mac" : "cloud" }

    /// Fallback cloud models on the Gemini API, used until live discovery
    /// with the user's key populates the cache. Flash aliases are stable and
    /// give free-tier users guaranteed-valid structured output.
    static let aiStudioModels = [
        "gemini-flash-latest",
        "gemini-flash-lite-latest",
        "gemma-4-26b-a4b-it",
        "gemma-4-31b-it",
    ]
}

/// Local server addresses, editable for non-default ports
/// (LM Studio's port is configurable; Ollama respects OLLAMA_HOST).
enum ServerConfig {
    static let lmStudioDefault = "http://127.0.0.1:1234"
    static let ollamaDefault = "http://127.0.0.1:11434"

    static var lmStudioOrigin: String {
        get { UserDefaults.standard.string(forKey: "server.lmstudio") ?? lmStudioDefault }
        set { store(newValue, key: "server.lmstudio", fallback: lmStudioDefault) }
    }

    static var ollamaOrigin: String {
        get { UserDefaults.standard.string(forKey: "server.ollama") ?? ollamaDefault }
        set { store(newValue, key: "server.ollama", fallback: ollamaDefault) }
    }

    /// Normalizes user input to a loopback origin, or nil if it points off-Mac.
    /// "Local model" is a promise that photos never leave this machine — a
    /// remote address here would break it silently while the UI still says
    /// "on this Mac". Cloud use stays explicit (AI Studio backend).
    static func normalizedLocalOrigin(_ value: String, fallback: String) -> String? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
        if trimmed.isEmpty { return fallback }
        if !trimmed.hasPrefix("http") { trimmed = "http://" + trimmed }
        guard let host = URL(string: trimmed)?.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
        else { return nil }
        return trimmed
    }

    private static func store(_ value: String, key: String, fallback: String) {
        let origin = normalizedLocalOrigin(value, fallback: fallback) ?? fallback
        UserDefaults.standard.set(origin, forKey: key)
    }
}

/// Minimal Keychain wrapper for the AI Studio API key. The key never touches
/// UserDefaults, logs, or disk outside the Keychain.
/// Keys saved under the app's pre-rename identity ("com.surendran.culler")
/// are migrated to the Whittle identity on first read, so keychain dialogs
/// show "Whittle", not the old name.
enum KeychainStore {
    private static let service = "com.surendran.whittle"
    private static let legacyService = "com.surendran.culler"

    static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "Whittle — Google AI Studio key"
        // Readable only while the Mac is unlocked, and never synced off-device.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Moves a pre-rename item to the Whittle identity. Returns the value if
    /// a legacy item existed. Triggers one final "culler" dialog, then never again.
    private static func migrateLegacy(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        save(value, account: account)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        Log.info("keychain: migrated legacy item to Whittle identity")
        return value
    }

    /// Existence check that does NOT read the protected value, so it never
    /// triggers the macOS keychain permission prompt.
    static func exists(account: String) -> Bool {
        for svc in [service, legacyService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrAccount as String: account,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess { return true }
        }
        return false
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return migrateLegacy(account: account)
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        for svc in [service, legacyService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
