import Foundation
import Combine

/// User-editable settings. URLs/email/JQL live in UserDefaults, secrets in Keychain.
@MainActor
final class Config: ObservableObject {
    static let shared = Config()
    private let d = UserDefaults.standard

    @Published var jiraSite: String { didSet { d.set(jiraSite, forKey: "jiraSite") } }
    @Published var jiraEmail: String { didSet { d.set(jiraEmail, forKey: "jiraEmail") } }
    @Published var jiraToken: String { didSet { Keychain.set(jiraToken, for: "jiraToken") } }
    @Published var jiraJQL: String { didSet { d.set(jiraJQL, forKey: "jiraJQL") } }

    /// GitLab / GitHub accounts. Any number, any mix.
    @Published var hosts: [HostConfig] { didSet { persistHosts() } }
    private func persistHosts() { if let data = try? JSONEncoder().encode(hosts) { d.set(data, forKey: "hosts") } }

    @Published var pollMinutes: Int { didSet { d.set(pollMinutes, forKey: "pollMinutes") } }
    @Published var notify: Bool { didSet { d.set(notify, forKey: "notify") } }
    /// Touch ID / password before opening Settings and before approve, merge, comment, resolve.
    @Published var requireAuth: Bool { didSet { d.set(requireAuth, forKey: "requireAuth") } }

    // Inbox filters
    @Published var hideDrafts: Bool { didSet { d.set(hideDrafts, forKey: "hideDrafts") } }
    @Published var hideBots: Bool { didSet { d.set(hideBots, forKey: "hideBots") } }
    @Published var groupByRepo: Bool { didSet { d.set(groupByRepo, forKey: "groupByRepo") } }
    /// Comma-separated substrings; an item stays only if its key/project matches one. Empty = everything.
    @Published var projectFilter: String { didSet { d.set(projectFilter, forKey: "projectFilter") } }
    // AI review
    /// Comma-separated folders scanned for local clones (deep review runs claude inside the repo).
    @Published var repoRoots: String { didSet { d.set(repoRoots, forKey: "repoRoots") } }
    @Published var deepReview: Bool { didSet { d.set(deepReview, forKey: "deepReview") } }
    /// Start the AI pass as soon as a review request opens, so drafts arrive while you read.
    @Published var autoAIReview: Bool { didSet { d.set(autoAIReview, forKey: "autoAIReview") } }
    // Updates
    @Published var autoUpdate: Bool { didSet { d.set(autoUpdate, forKey: "autoUpdate") } }
    /// GitHub "owner/repo" whose releases carry Pendrix-x.y.z.dmg + .dmg.sha256.
    @Published var updateRepo: String { didSet { d.set(updateRepo, forKey: "updateRepo") } }
    /// Hours before a review request counts as waiting too long. 0 = off.
    @Published var agingHours: Int { didSet { d.set(agingHours, forKey: "agingHours") } }
    @Published var standupReminder: Bool { didSet { d.set(standupReminder, forKey: "standupReminder") } }
    /// Minutes after midnight, weekdays. Default 09:30.
    @Published var standupMinutes: Int { didSet { d.set(standupMinutes, forKey: "standupMinutes") } }
    @Published var standupLanguage: StandupLanguage { didSet { d.set(standupLanguage.rawValue, forKey: "standupLanguage") } }
    @Published var aiProvider: AIProvider { didSet { d.set(aiProvider.rawValue, forKey: "aiProvider") } }
    @Published var anthropicKey: String { didSet { Keychain.set(anthropicKey, for: "anthropicKey") } }

    static let defaultJQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"

    private init() {
        jiraSite = d.string(forKey: "jiraSite") ?? ""
        jiraEmail = d.string(forKey: "jiraEmail") ?? ""
        jiraToken = Keychain.get("jiraToken") ?? ""
        jiraJQL = d.string(forKey: "jiraJQL") ?? Self.defaultJQL
        pollMinutes = max(1, d.integer(forKey: "pollMinutes") == 0 ? 2 : d.integer(forKey: "pollMinutes"))
        notify = d.object(forKey: "notify") as? Bool ?? true
        requireAuth = d.object(forKey: "requireAuth") as? Bool ?? true
        hideDrafts = d.object(forKey: "hideDrafts") as? Bool ?? false
        hideBots = d.object(forKey: "hideBots") as? Bool ?? true
        groupByRepo = d.object(forKey: "groupByRepo") as? Bool ?? false
        projectFilter = d.string(forKey: "projectFilter") ?? ""
        agingHours = d.object(forKey: "agingHours") as? Int ?? 24
        repoRoots = d.string(forKey: "repoRoots") ?? "~/Desktop/works"
        deepReview = d.object(forKey: "deepReview") as? Bool ?? true
        autoAIReview = d.object(forKey: "autoAIReview") as? Bool ?? true
        autoUpdate = d.object(forKey: "autoUpdate") as? Bool ?? true
        updateRepo = d.string(forKey: "updateRepo") ?? "Techit-Kakaew/pendrix"
        standupReminder = d.object(forKey: "standupReminder") as? Bool ?? false
        standupMinutes = d.object(forKey: "standupMinutes") as? Int ?? (9 * 60 + 30)
        standupLanguage = StandupLanguage(rawValue: d.string(forKey: "standupLanguage") ?? "") ?? .th
        aiProvider = AIProvider(rawValue: d.string(forKey: "aiProvider") ?? "") ?? .off
        anthropicKey = Keychain.get("anthropicKey") ?? ""

        if let data = d.data(forKey: "hosts"), let h = try? JSONDecoder().decode([HostConfig].self, from: data) {
            hosts = h
        } else {
            // Migrate the single-GitLab settings from 0.1, or start with the company instance.
            var h = HostConfig(kind: .gitlab, baseURL: d.string(forKey: "gitlabBase") ?? "https://git.7.solutions",
                               showOwn: d.object(forKey: "includeOwnMRs") as? Bool ?? true,
                               showTodos: d.object(forKey: "includeTodos") as? Bool ?? true)
            // Re-adopt a token whose host row never got persisted (0.2 bug): reuse its UUID.
            if let orphan = Keychain.accounts().first(where: { $0.hasPrefix("token.") }),
               let id = UUID(uuidString: String(orphan.dropFirst("token.".count))) { h.id = id }
            if let t = Keychain.get("gitlabToken"), !t.isEmpty { h.token = t; Keychain.set("", for: "gitlabToken") }
            hosts = [h]
            persistHosts()   // didSet does not fire inside init
        }
    }

    var jiraReady: Bool { !jiraSite.isEmpty && !jiraEmail.isEmpty && !jiraToken.isEmpty }
    var anyHostReady: Bool { hosts.contains { $0.ready } }

    var jiraURL: URL? {
        var s = jiraSite.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    func host(_ id: UUID) -> HostConfig? { hosts.first { $0.id == id } }
    func addHost(_ kind: HostKind) {
        hosts.append(HostConfig(kind: kind, baseURL: kind == .github ? "https://github.com" : ""))
    }
    func removeHost(_ id: UUID) {
        if let h = host(id) { h.token = "" }
        hosts.removeAll { $0.id == id }
    }
}
