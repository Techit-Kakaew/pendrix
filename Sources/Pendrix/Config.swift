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
    /// Use a codegraph index (per repo, built on first review) as an MCP tool during deep review.
    @Published var useCodeGraph: Bool { didSet { d.set(useCodeGraph, forKey: "useCodeGraph") } }
    /// Pull linked Jira tickets (keys in the MR title/branch) into the review prompt. Off by default: slower, and not every MR needs it.
    @Published var aiReadTickets: Bool { didSet { d.set(aiReadTickets, forKey: "aiReadTickets") } }
    /// claude -p speed knobs. Model "" = whatever Claude Code defaults to; "sonnet" is 2–3× faster.
    @Published var aiModel: String { didSet { d.set(aiModel, forKey: "aiModel") } }
    @Published var aiEffort: String { didSet { d.set(aiEffort, forKey: "aiEffort") } }
    @Published var aiSkipUserHooks: Bool { didSet { d.set(aiSkipUserHooks, forKey: "aiSkipUserHooks") } }
    /// Keep claude transcripts for review runs so TokenBar (and `claude --resume`) can see them. Off = --no-session-persistence.
    @Published var aiPersistSessions: Bool { didSet { d.set(aiPersistSessions, forKey: "aiPersistSessions") } }
    // Updates
    @Published var autoUpdate: Bool { didSet { d.set(autoUpdate, forKey: "autoUpdate") } }
    /// GitHub "owner/repo" whose releases carry Pendrix-x.y.z.dmg + .dmg.sha256.
    @Published var updateRepo: String { didSet { d.set(updateRepo, forKey: "updateRepo") } }
    /// Hours before a review request counts as waiting too long. 0 = off.
    @Published var agingHours: Int { didSet { d.set(agingHours, forKey: "agingHours") } }
    /// Review sidebar: files under folder headers instead of one flat list.
    @Published var reviewGroupByFolder: Bool { didSet { d.set(reviewGroupByFolder, forKey: "reviewGroupByFolder") } }
    @Published var standupReminder: Bool { didSet { d.set(standupReminder, forKey: "standupReminder") } }
    /// Minutes after midnight, weekdays. Default 09:30.
    @Published var standupMinutes: Int { didSet { d.set(standupMinutes, forKey: "standupMinutes") } }
    @Published var standupUseGit: Bool { didSet { d.set(standupUseGit, forKey: "standupUseGit") } }
    @Published var standupUseClaude: Bool { didSet { d.set(standupUseClaude, forKey: "standupUseClaude") } }
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
        reviewGroupByFolder = d.object(forKey: "reviewGroupByFolder") as? Bool ?? true
        repoRoots = d.string(forKey: "repoRoots") ?? "~/Desktop/works"
        deepReview = d.object(forKey: "deepReview") as? Bool ?? true
        autoAIReview = d.object(forKey: "autoAIReview") as? Bool ?? true
        useCodeGraph = d.object(forKey: "useCodeGraph") as? Bool ?? true
        aiReadTickets = d.object(forKey: "aiReadTickets") as? Bool ?? false
        aiModel = d.string(forKey: "aiModel") ?? "sonnet"
        aiEffort = d.string(forKey: "aiEffort") ?? "medium"
        aiSkipUserHooks = d.object(forKey: "aiSkipUserHooks") as? Bool ?? true
        aiPersistSessions = d.object(forKey: "aiPersistSessions") as? Bool ?? true
        autoUpdate = d.object(forKey: "autoUpdate") as? Bool ?? true
        updateRepo = d.string(forKey: "updateRepo") ?? "Techit-Kakaew/pendrix"
        standupReminder = d.object(forKey: "standupReminder") as? Bool ?? false
        standupMinutes = d.object(forKey: "standupMinutes") as? Int ?? (9 * 60 + 30)
        standupUseGit = d.object(forKey: "standupUseGit") as? Bool ?? true
        standupUseClaude = d.object(forKey: "standupUseClaude") as? Bool ?? true
        standupLanguage = StandupLanguage(rawValue: d.string(forKey: "standupLanguage") ?? "") ?? .th
        aiProvider = AIProvider(rawValue: d.string(forKey: "aiProvider") ?? "") ?? .cli
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

    /// Re-read secrets after a denied Keychain dialog.
    func reloadSecrets() {
        Keychain.retry()
        jiraToken = Keychain.get("jiraToken") ?? ""
        anthropicKey = Keychain.get("anthropicKey") ?? ""
        hosts = hosts   // republish so HostConfig.ready re-evaluates
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
