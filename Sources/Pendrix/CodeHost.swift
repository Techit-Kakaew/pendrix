import Foundation

enum HostKind: String, Codable, CaseIterable, Identifiable {
    case gitlab, github
    var id: String { rawValue }
    var label: String { self == .gitlab ? "GitLab" : "GitHub" }
    var noun: String { self == .gitlab ? "MR" : "PR" }
}

/// One configured account. Token lives in Keychain under `token.<id>`.
struct HostConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: HostKind
    var baseURL: String
    var showOwn = true
    var showTodos = true

    var url: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
    var host: String { url?.host ?? baseURL }
    var token: String {
        get { Keychain.get("token.\(id.uuidString)") ?? "" }
        nonmutating set { Keychain.set(newValue, for: "token.\(id.uuidString)") }
    }
    var ready: Bool { url != nil && !token.isEmpty }
}

/// Points at one MR/PR on one account. Codable so it can open a review window.
struct ChangeRef: Hashable, Codable {
    let hostID: UUID
    let project: String     // GitLab numeric project id / GitHub "owner/repo"
    let number: Int         // MR iid / PR number
}

struct Inbox {
    var reviews: [WorkItem] = []
    var own: [WorkItem] = []
    var todos: [WorkItem] = []
}

struct LineAnchor: Hashable, Codable {
    var path: String
    var oldLine: Int?
    var newLine: Int?
}

struct Comment: Identifiable, Hashable {
    let id: String
    let author: String
    let body: String
    let created: Date
    var isSystem = false
}

struct ReviewThread: Identifiable, Hashable {
    let id: String
    var anchor: LineAnchor?
    var resolved = false
    var resolvable = true
    var comments: [Comment]
    /// Host-specific handle for replies (GitHub needs the root comment's REST id).
    var replyHandle: String? = nil
}

struct CommitInfo: Identifiable, Hashable {
    let id: String          // full sha
    let short: String
    let title: String
    let author: String
    let date: Date
    let url: URL?
}

struct ChangeDetail {
    var ref: ChangeRef
    var title: String
    var description: String
    var author: String
    var sourceBranch: String
    var targetBranch: String
    var url: URL
    var state: String
    var draft: Bool
    var approvedByMe: Bool
    var approvals: [String]
    var mergeable: Bool
    var pipeline: String?
    var files: [FileDiff]
    var threads: [ReviewThread]
    var commits: [CommitInfo] = []
    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
    /// GitLab needs base/start/head for new line comments; GitHub only head.
    var baseSHA: String
    var startSHA: String
    var headSHA: String
}

protocol CodeHost {
    var config: HostConfig { get }
    func inbox() async throws -> Inbox
    /// What the token's user did since `since`: pushes, MRs opened, approvals, comments, merges.
    func activity(since: Date) async throws -> [Activity]
    func detail(_ ref: ChangeRef) async throws -> ChangeDetail
    /// Files touched by one commit of the change (no threads; commenting is MR-level).
    func commitDiff(_ ref: ChangeRef, sha: String) async throws -> [FileDiff]
    func comment(_ ref: ChangeRef, at anchor: LineAnchor?, body: String, detail: ChangeDetail) async throws
    func reply(_ ref: ChangeRef, thread: ReviewThread, body: String) async throws
    func resolve(_ ref: ChangeRef, thread: ReviewThread, resolved: Bool) async throws
    func approve(_ ref: ChangeRef, approve: Bool) async throws
    func merge(_ ref: ChangeRef) async throws
}

func makeHost(_ c: HostConfig) -> CodeHost? {
    guard let url = c.url else { return nil }
    switch c.kind {
    case .gitlab: return GitLabHost(config: c, base: url, token: c.token)
    case .github: return GitHubHost(config: c, base: url, token: c.token)
    }
}

// MARK: - HTTP helper shared by hosts

struct HTTP {
    var headers: [String: String]

    func send(_ method: String, _ url: URL, json: Any? = nil, form: [String: String]? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let form {
            var c = URLComponents(); c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = c.percentEncodedQuery?.data(using: .utf8)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(message: "HTTP \(http.statusCode) \(url.path): \(Self.message(data))")
        }
        return data
    }

    func get<T: Decodable>(_ url: URL) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send("GET", url))
    }

    static func message(_ d: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let m = o["errorMessages"] as? [String], !m.isEmpty { return m.joined(separator: "; ") }
            if let m = o["message"] as? String { return m }
            if let m = o["error"] as? String { return m }
        }
        return String(data: d.prefix(200), encoding: .utf8) ?? ""
    }
}

func url(_ base: URL, _ path: String, _ query: [String: String] = [:]) -> URL {
    var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
    return c.url!
}
