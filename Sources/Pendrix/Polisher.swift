import Foundation

enum StandupLanguage: String, Codable, CaseIterable, Identifiable {
    case th, en
    var id: String { rawValue }
    var label: String { self == .th ? "ไทย" : "English" }
    var name: String { self == .th ? "Thai" : "English" }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case off, onDevice, claude
    var id: String { rawValue }
    var label: String {
        switch self { case .off: "Off (bullets only)"; case .onDevice: "On-device (Apple Intelligence)"; case .claude: "Claude API" }
    }
}

/// Turns the structured standup into something you can read aloud.
protocol Polisher {
    func polish(_ s: Standup, language: StandupLanguage) async throws -> String
}

enum PolishPrompt {
    static func system(_ lang: StandupLanguage) -> String {
        let heads = lang == .th ? "เมื่อวาน / วันนี้ / ติดอะไรไหม" : "Yesterday / Today / Blockers"
        return """
        You turn a developer's structured standup notes into a short spoken update for a daily standup.
        Write in \(lang.name). Three short sections with these exact headings, one per line, then 1–3 sentences each: \(heads).
        Spoken, plain, first person. Merge related items into one sentence. Keep ticket keys (PAY-412), MR/PR references (pay/gateway!482, repo#91) and branch names exactly as written; never invent work that is not in the notes. If a section is empty, say so in one short clause. No markdown, no bullet characters, no preamble.
        """
    }
    static func user(_ s: Standup) -> String { s.plain }
}

/// Claude Messages API over raw HTTP (no Swift SDK). Key lives in Keychain.
struct ClaudePolisher: Polisher {
    let apiKey: String
    static let model = "claude-opus-5"

    func polish(_ s: Standup, language: StandupLanguage) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 4096,
            "fallbacks": "default",
            "output_config": ["effort": "low"],
            "system": PolishPrompt.system(language),
            "messages": [["role": "user", "content": PolishPrompt.user(s)]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 90
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "Claude: no response") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw APIError(message: "Claude HTTP \(http.statusCode): \(msg)")
        }
        if json["stop_reason"] as? String == "refusal" { throw APIError(message: "Claude declined to answer this request") }
        let text = (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw APIError(message: "Claude returned no text") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Apple's on-device model. Nothing leaves the Mac. Needs Apple Intelligence on, and language support varies.
@available(macOS 26, *)
struct OnDevicePolisher: Polisher {
    static var availabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let r): return "On-device model unavailable: \(String(describing: r))"
        }
    }

    func polish(_ s: Standup, language: StandupLanguage) async throws -> String {
        if let m = Self.availabilityMessage { throw APIError(message: m) }
        let session = LanguageModelSession(instructions: PolishPrompt.system(language))
        let r = try await session.respond(to: PolishPrompt.user(s))
        return r.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

enum Polishers {
    static func make(_ p: AIProvider, apiKey: String) -> Polisher? {
        switch p {
        case .off: return nil
        case .claude: return apiKey.isEmpty ? nil : ClaudePolisher(apiKey: apiKey)
        case .onDevice:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) { return OnDevicePolisher() }
            #endif
            return nil
        }
    }
}
