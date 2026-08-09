import Foundation

/// Client for LM Studio's OpenAI-compatible server. The model only ever
/// annotates (which photo looks best and why) — it never acts on the library.
struct JudgeService {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    // MARK: - Model discovery

    struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    /// LM Studio: use the native API which labels vision models (type "vlm"),
    /// so users never pick a text-only model. Falls back to the generic list.
    static func lmStudioVisionModels() async throws -> [String] {
        struct V0List: Decodable {
            struct Model: Decodable {
                let id: String
                let type: String?
            }
            let data: [Model]
        }
        let url = URL(string: ServerConfig.lmStudioOrigin + "/api/v0/models")!
        do {
            let (data, _) = try await session.data(from: url)
            let list = try JSONDecoder().decode(V0List.self, from: data)
            let vlms = list.data.filter { $0.type == "vlm" }.map(\.id)
            if !vlms.isEmpty { return sortForJudging(vlms) }
        } catch { /* fall through to OpenAI-compat list */ }
        return try await availableModels(baseURL: URL(string: ServerConfig.lmStudioOrigin + "/v1")!)
    }

    /// Ollama: check each model's capabilities for "vision" (newer Ollama);
    /// models without capability info are kept (older versions).
    static func ollamaVisionModels() async throws -> [String] {
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        struct ShowResponse: Decodable { let capabilities: [String]? }
        let base = ServerConfig.ollamaOrigin
        let (data, _) = try await session.data(from: URL(string: "\(base)/api/tags")!)
        let names = try JSONDecoder().decode(Tags.self, from: data).models.map(\.name)
        var vision: [String] = []
        for name in names {
            var request = URLRequest(url: URL(string: "\(base)/api/show")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name])
            guard let (showData, _) = try? await session.data(for: request),
                  let show = try? JSONDecoder().decode(ShowResponse.self, from: showData) else {
                vision.append(name)   // can't tell — keep it
                continue
            }
            if let caps = show.capabilities {
                if caps.contains("vision") { vision.append(name) }
            } else {
                vision.append(name)
            }
        }
        return sortForJudging(vision)
    }

    static func sortForJudging(_ ids: [String]) -> [String] {
        ids.sorted { a, b in
            func rank(_ s: String) -> Int {
                if s.localizedCaseInsensitiveContains("qwen") { return 0 }
                if s.localizedCaseInsensitiveContains("gemma") { return 1 }
                if s.localizedCaseInsensitiveContains("glm") { return 2 }
                return 3
            }
            return rank(a) < rank(b)
        }
    }

    /// Generic OpenAI-compatible model list (fallback).
    static func availableModels(baseURL: URL) async throws -> [String] {
        let (data, _) = try await session.data(from: baseURL.appendingPathComponent("models"))
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        let ids = list.data.map(\.id).filter { !$0.contains("embed") }
        return ids.sorted { a, b in
            func rank(_ s: String) -> Int {
                if s.localizedCaseInsensitiveContains("qwen") { return 0 }
                if s.localizedCaseInsensitiveContains("gemma") { return 1 }
                if s.localizedCaseInsensitiveContains("glm") { return 2 }
                return 3
            }
            return rank(a) < rank(b)
        }
    }

    /// Discovers Gemma models available on Google AI Studio for this key.
    /// Returns model IDs usable with :generateContent (no "models/" prefix).
    static func aiStudioModelList(apiKey: String) async throws -> [String] {
        struct List: Decodable {
            struct Model: Decodable {
                let name: String
                let supportedGenerationMethods: [String]?
            }
            let models: [Model]?
        }
        var request = URLRequest(url: URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw JudgeError.server("AI Studio model list failed (HTTP \(http.statusCode)) — check the API key.")
        }
        let list = try JSONDecoder().decode(List.self, from: data)
        let usable = (list.models ?? [])
            .filter { ($0.supportedGenerationMethods ?? []).contains("generateContent") }
            .map { $0.name.replacingOccurrences(of: "models/", with: "") }
        // Gemini Flash first (structured output + fastest), then Gemma
        // (same family as the recommended local model).
        let flash = ["gemini-flash-latest", "gemini-flash-lite-latest"].filter(usable.contains)
        let gemma = usable.filter { $0.localizedCaseInsensitiveContains("gemma") }
        return flash + gemma
    }

    // MARK: - Judging

    struct RawVerdict: Decodable {
        let keep_index: Int
        let reasons: [String]
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finish_reason: String?
        }
        let choices: [Choice]
    }

    /// Max photos per model call. Local models judge small groups reliably but
    /// lose track (and overflow modest context windows) beyond ~3 images.
    static let maxPhotosPerCall = 3

    /// Judges a cluster of any size. Up to `maxPhotosPerCall` photos go in one
    /// call; larger clusters run as a tournament — balanced groups of 2-3, each
    /// group's winner advances to a final round. `keepIndex` is 0-based into
    /// `jpegs`; reasons come from the round each photo was judged in.
    static func judgeCluster(
        jpegs: [Data], signals: [NativeSignals] = [],
        backend: JudgeBackend, apiKey: String?,
        onStage: @escaping @Sendable (String) async -> Void
    ) async throws -> ClusterVerdict {
        let indices = Array(jpegs.indices)
        var reasons = [String](repeating: "", count: jpegs.count)
        var contenders = indices

        while contenders.count > maxPhotosPerCall {
            var winners: [Int] = []
            for group in balancedChunks(contenders, maxSize: maxPhotosPerCall) {
                if group.count == 1 {
                    winners.append(group[0])   // bye — advances unjudged
                    continue
                }
                await onStage("Comparing photos \(group.map { String($0 + 1) }.joined(separator: ", "))…")
                let verdict = try await judge(
                    jpegs: group.map { jpegs[$0] },
                    signals: group.compactMap { signals.indices.contains($0) ? signals[$0] : nil },
                    backend: backend, apiKey: apiKey)
                for (k, original) in group.enumerated() { reasons[original] = verdict.reasons[k] }
                winners.append(group[verdict.keepIndex])
            }
            contenders = winners
        }

        let keep: Int
        if contenders.count == 1 {
            keep = contenders[0]
        } else {
            if contenders.count < jpegs.count {
                await onStage("Final round: photos \(contenders.map { String($0 + 1) }.joined(separator: " vs "))…")
            } else {
                await onStage("Comparing \(jpegs.count) photos…")
            }
            let verdict = try await judge(
                jpegs: contenders.map { jpegs[$0] },
                signals: contenders.compactMap { signals.indices.contains($0) ? signals[$0] : nil },
                backend: backend, apiKey: apiKey)
            for (k, original) in contenders.enumerated() { reasons[original] = verdict.reasons[k] }
            keep = contenders[verdict.keepIndex]
        }
        return ClusterVerdict(keepIndex: keep, reasons: reasons, model: backend.displayName)
    }

    static func balancedChunks(_ items: [Int], maxSize: Int) -> [[Int]] {
        ClusterEngine.balancedChunks(items, maxSize: maxSize)
    }

    /// The judging criteria — the user-editable half of the prompt.
    /// "{count}" is substituted at call time.
    static let defaultCriteria = """
        You are helping a user pick the best photo from a burst of {count} \
        similar photos, shown in order and numbered 1 to {count}. \
        Judge sharpness/focus, motion blur, exposure, framing/composition, and \
        how interesting the subject moment is. The measured analysis below tells \
        you the scene type and face data: when faces are present, weigh face \
        quality, open eyes, and flattering expressions heavily; when there are \
        none, judge the scene alone and do not mention faces at all.
        """

    static var customCriteria: String? {
        get {
            let value = UserDefaults.standard.string(forKey: "judgePrompt.custom")
            return value?.isEmpty == false ? value : nil
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty || trimmed == defaultCriteria {
                UserDefaults.standard.removeObject(forKey: "judgePrompt.custom")
            } else {
                UserDefaults.standard.set(trimmed, forKey: "judgePrompt.custom")
            }
        }
    }

    /// Full prompt = criteria (default or user's) + fixed output contract +
    /// measured signals. The contract is never editable — removing it would
    /// break every suggestion.
    static func prompt(count: Int, signals: [NativeSignals]) -> String {
        let criteria = (customCriteria ?? defaultCriteria)
            .replacingOccurrences(of: "{count}", with: String(count))
        let contract = """
        Respond with JSON only, no other text: "keep_index" = the 1-based number \
        of the single best photo, and "reasons" = exactly \(count) short strings \
        (max 12 words each). Reason N names a concrete, visible quality of photo \
        N itself — never commentary about which criteria apply, and NEVER photo \
        numbers or comparisons to other photos. \
        Your reply MUST start with the character '{' — no analysis, no preamble, \
        no markdown fences, just the JSON object.
        """
        return criteria + "\n" + contract + "\n" + NativeSignals.promptBlock(signals)
    }

    /// Single model call comparing 2-3 photos. `keepIndex` in the result is 0-based.
    static func judge(jpegs: [Data], signals: [NativeSignals] = [], backend: JudgeBackend, apiKey: String?) async throws -> ClusterVerdict {
        precondition(jpegs.count >= 2)
        switch backend.kind {
        case .lmStudio, .ollama:
            return try await judgeViaOpenAICompat(
                jpegs: jpegs, signals: signals, model: backend.modelID, baseURL: backend.localBaseURL!)
        case .aiStudio:
            guard let apiKey, !apiKey.isEmpty else {
                throw JudgeError.server("No AI Studio API key set. Add one via the key button next to the model picker.")
            }
            return try await judgeViaAIStudio(jpegs: jpegs, signals: signals, model: backend.modelID, apiKey: apiKey)
        }
    }

    private static func judgeViaOpenAICompat(jpegs: [Data], signals: [NativeSignals], model: String, baseURL: URL) async throws -> ClusterVerdict {
        var content: [[String: Any]] = [["type": "text", "text": prompt(count: jpegs.count, signals: signals)]]
        for jpeg in jpegs {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
            ])
        }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "keep_index": ["type": "integer", "minimum": 1, "maximum": jpegs.count],
                "reasons": [
                    "type": "array",
                    "items": ["type": "string"],
                    "minItems": jpegs.count,
                    "maxItems": jpegs.count,
                ],
            ],
            "required": ["keep_index", "reasons"],
            "additionalProperties": false,
        ]

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": content]],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "verdict", "strict": true, "schema": schema],
            ],
            "temperature": 0.2,
            "max_tokens": 4000,
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let text = String(data: data, encoding: .utf8) ?? ""
            Log.error("local \(model): HTTP \(http.statusCode): \(text.prefix(300))")
            let lower = text.lowercased()
            if lower.contains("image") || lower.contains("vision") || lower.contains("multimodal") {
                throw JudgeError.server("\(model) can't process images — pick a vision model (look for 'vl' or 'vision' in the name).")
            }
            throw JudgeError.server("HTTP \(http.statusCode): \(text.prefix(300))")
        }
        Log.info("local \(model): 200, \(data.count) bytes")

        let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let contentText = chat.choices.first?.message.content, !contentText.isEmpty else {
            throw JudgeError.server("Model returned an empty response (it may have spent all tokens reasoning).")
        }
        return try verdict(fromModelText: contentText, photoCount: jpegs.count, model: model)
    }

    /// Gemini API (Google AI Studio). Gemma models there accept images but not
    /// structured-output mode, so we prompt for JSON and parse tolerantly.
    private static func judgeViaAIStudio(jpegs: [Data], signals: [NativeSignals], model: String, apiKey: String) async throws -> ClusterVerdict {
        var parts: [[String: Any]] = [["text": prompt(count: jpegs.count, signals: signals)]]
        for jpeg in jpegs {
            parts.append(["inline_data": [
                "mime_type": "image/jpeg",
                "data": jpeg.base64EncodedString(),
            ]])
        }
        var generationConfig: [String: Any] = ["temperature": 0.2, "maxOutputTokens": 8000]
        if model.hasPrefix("gemini") {
            // Gemini supports enforced JSON schemas; Gemma on this API does not.
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseSchema"] = [
                "type": "OBJECT",
                "properties": [
                    "keep_index": ["type": "INTEGER"],
                    "reasons": ["type": "ARRAY", "items": ["type": "STRING"]],
                ],
                "required": ["keep_index", "reasons"],
            ]
        }
        let body: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": generationConfig,
        ]

        var request = URLRequest(url: URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 429 {
                Log.error("aistudio \(model): 429 rate limited")
                throw JudgeError.server("AI Studio rate limit hit (free tier). Wait a bit or switch to a local model.")
            }
            if http.statusCode == 400 || http.statusCode == 403 {
                let text = String(data: data, encoding: .utf8) ?? ""
                Log.error("aistudio \(model): HTTP \(http.statusCode): \(text.prefix(300))")
                throw JudgeError.server("AI Studio rejected the request (HTTP \(http.statusCode)) — check the API key.")
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            Log.error("aistudio \(model): HTTP \(http.statusCode): \(text.prefix(300))")
            throw JudgeError.server("AI Studio HTTP \(http.statusCode): \(text.prefix(200))")
        }
        Log.info("aistudio \(model): 200, \(data.count) bytes")

        struct GeminiResponse: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }
        let gemini = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = gemini.candidates?.first?.content?.parts?
            .compactMap(\.text).joined() ?? ""
        guard !text.isEmpty else {
            throw JudgeError.server("AI Studio returned an empty response.")
        }
        return try verdict(fromModelText: text, photoCount: jpegs.count, model: model)
    }

    /// Extracts the JSON verdict from model text (tolerates markdown fences and
    /// surrounding prose) and normalizes indices/reasons.
    static func verdict(fromModelText text: String, photoCount: Int, model: String) throws -> ClusterVerdict {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end,
              let jsonData = String(text[start...end]).data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawVerdict.self, from: jsonData) else {
            Log.error("parse failure from \(model): \(text.prefix(300))")
            throw JudgeError.server("Could not parse model output: \(text.prefix(200))")
        }
        let keep = min(max(raw.keep_index - 1, 0), photoCount - 1)
        var reasons = raw.reasons.map { reason -> String in
            var r = reason
            for pattern in ["[Pp]hotos? [0-9]+(,? ?(and )?[0-9]+)*", "[Ee]ither photo", "[Bb]oth photos"] {
                r = r.replacingOccurrences(of: pattern, with: "This shot", options: .regularExpression)
            }
            return r
        }
        if reasons.count < photoCount {
            reasons += Array(repeating: "", count: photoCount - reasons.count)
        } else if reasons.count > photoCount {
            reasons = Array(reasons.prefix(photoCount))
        }
        return ClusterVerdict(keepIndex: keep, reasons: reasons, model: model)
    }

    enum JudgeError: LocalizedError {
        case server(String)

        var errorDescription: String? {
            switch self {
            case .server(let message): return message
            }
        }
    }
}
