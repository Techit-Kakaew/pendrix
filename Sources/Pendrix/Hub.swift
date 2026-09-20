import Foundation
import Combine
import UserNotifications
import AppKit
import SwiftUI

/// Single source of truth: polls Jira and every code host, diffs against last poll, fires notifications.
@MainActor
final class Hub: ObservableObject {
    @Published var jira: [WorkItem] = []
    @Published var reviews: [WorkItem] = []
    @Published var ownMRs: [WorkItem] = []
    @Published var todos: [WorkItem] = []
    @Published var jiraError: String?
    @Published var hostErrors: [UUID: String] = [:]
    @Published var lastRefresh: Date?
    @Published var refreshing = false
    /// Items that arrived since the user last looked. Drives the accent dot and menu-bar count.
    @Published private(set) var unseen: Set<String> = []

    enum Route: Hashable { case home, standup, review(ChangeRef) }
    @Published var route: Route = .home
    func go(_ r: Route) { withAnimation(.snappy(duration: 0.28)) { route = r } }
    func back() { go(.home) }

    let config = Config.shared
    let updates = UpdateChecker()
    let isDemo: Bool
    private var timer: Timer?
    private var known: Set<String>
    private var seeded = false
    private var bag = Set<AnyCancellable>()
    private let knownKey = "knownIDs"

    init(demo: Bool = false) {
        isDemo = demo
        known = Set(UserDefaults.standard.stringArray(forKey: knownKey) ?? [])
        if demo { loadDemo(); return }
        config.$pollMinutes.removeDuplicates().sink { [weak self] _ in self?.schedule() }.store(in: &bag)
        config.$standupReminder.combineLatest(config.$standupMinutes).dropFirst().removeDuplicates(by: ==)
            .sink { [weak self] _ in self?.scheduleStandupReminder() }.store(in: &bag)
        schedule()
        scheduleStandupReminder()
        updates.autoCheck()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in Task { @MainActor in self?.updates.autoCheck() } }
        Task { await refresh() }
    }

    // MARK: filters (what the UI shows)

    private static let botMarkers = ["bot", "renovate", "dependabot", "ci", "automation", "pipeline"]
    private func isBot(_ item: WorkItem) -> Bool {
        let a = item.subtitle.lowercased()
        return a.hasSuffix("[bot]") || Self.botMarkers.contains { a == $0 || a.hasPrefix($0 + "-") || a.hasSuffix("-" + $0) || a.hasSuffix("_" + $0) }
    }
    private func passesProject(_ item: WorkItem) -> Bool {
        let terms = config.projectFilter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return true }
        let hay = (item.key + " " + item.hostLabel).lowercased()
        return terms.contains { hay.contains($0) }
    }
    private func visible(_ items: [WorkItem], drafts: Bool = true) -> [WorkItem] {
        items.filter { i in
            (drafts || !config.hideDrafts || !i.isDraft) && (!config.hideBots || !isBot(i)) && passesProject(i)
        }
    }
    var visibleJira: [WorkItem] { jira.filter(passesProject) }
    var visibleReviews: [WorkItem] { visible(reviews, drafts: false) }
    var visibleTodos: [WorkItem] { visible(todos) }
    var visibleOwn: [WorkItem] { visible(ownMRs) }
    var hiddenCount: Int { (jira.count + reviews.count + todos.count + ownMRs.count) - (visibleJira.count + visibleReviews.count + visibleTodos.count + visibleOwn.count) }

    /// Repo/project prefix for grouping: "pay/gateway!482" → "pay/gateway", "PAY-412" → "PAY".
    static func group(of item: WorkItem) -> String {
        if let r = item.key.range(of: "!") ?? item.key.range(of: "#") { return String(item.key[..<r.lowerBound]) }
        if let r = item.key.range(of: "-") { return String(item.key[..<r.lowerBound]) }
        return item.key
    }

    // MARK: aging

    func isAging(_ item: WorkItem) -> Bool {
        config.agingHours > 0 && item.kind == .reviewRequest && !item.isDraft
            && Date().timeIntervalSince(item.updated) > Double(config.agingHours) * 3600
    }
    var agingCount: Int { visibleReviews.filter(isAging).count }
    private var agedNotified: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "agedNotified") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "agedNotified") }
    }

    // MARK: keyboard selection

    @Published var selectedID: String? = nil
    /// Everything on screen in reading order, for j/k.
    var orderedItems: [WorkItem] { visibleJira + visibleReviews + visibleTodos + visibleOwn }
    func moveSelection(_ delta: Int) {
        let items = orderedItems; guard !items.isEmpty else { return }
        let idx = items.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : items.count)
        selectedID = items[max(0, min(items.count - 1, idx + delta))].id
    }
    var selectedItem: WorkItem? { orderedItems.first { $0.id == selectedID } }

    /// One-key approve from the inbox. Touch ID inside `approve`.
    func quickApprove(_ item: WorkItem) async {
        guard item.kind == .reviewRequest, let ref = item.change, let host = host(for: ref) else { return }
        guard await Auth.require("Pendrix: approve \(item.key)") else { return }
        do { try await host.approve(ref, approve: true); flash = "Approved \(item.key)"; await refresh() }
        catch { hostErrors[ref.hostID] = error.localizedDescription }
        Task { try? await Task.sleep(for: .seconds(2)); if flash?.hasPrefix("Approved") == true { flash = nil } }
    }

    var attentionCount: Int { visibleReviews.count + visibleTodos.count }
    var unseenCount: Int { unseen.count }
    var anyHostError: String? { hostErrors.values.first }

    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.pollMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; lastRefresh = Date() }

        async let j: Void = refreshJira()
        async let g: Void = refreshHosts()
        _ = await (j, g)

        let all = Set((jira + reviews + ownMRs + todos).map(\.id))
        let fresh = all.subtracting(known)
        if seeded || !known.isEmpty {
            let pings = (reviews + todos + jira).filter { fresh.contains($0.id) }
            unseen.formUnion(fresh)
            if config.notify { for p in pings.prefix(5) { notify(p) } }
        }
        seeded = true
        known = all
        UserDefaults.standard.set(Array(all), forKey: knownKey)

        // Aging: one notification per review request when it crosses the threshold.
        if config.notify, config.agingHours > 0 {
            var done = agedNotified
            for r in visibleReviews where isAging(r) && !done.contains(r.id) {
                done.insert(r.id)
                let c = UNMutableNotificationContent()
                c.title = "Still waiting for your review · \(r.key)"
                c.body = "\(r.title) — \(r.updated.relative) without a response"
                c.userInfo = ["url": r.url.absoluteString]
                if let data = try? JSONEncoder().encode(r.change) { c.userInfo["change"] = String(decoding: data, as: UTF8.self) }
                if Bundle.main.bundleIdentifier != nil {
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "aging.\(r.id)", content: c, trigger: nil)) { _ in }
                }
            }
            agedNotified = done.intersection(all)
        }
    }

    private func refreshJira() async {
        guard config.jiraReady, let url = config.jiraURL else { jiraError = nil; jira = []; return }
        do {
            jira = try await JiraClient(base: url, email: config.jiraEmail, token: config.jiraToken).search(jql: config.jiraJQL)
            jiraError = nil
        } catch { jiraError = error.localizedDescription }
    }

    private func refreshHosts() async {
        let hosts = config.hosts.filter(\.ready).compactMap(makeHost)
        var r: [WorkItem] = [], o: [WorkItem] = [], t: [WorkItem] = []
        var errs: [UUID: String] = [:]
        await withTaskGroup(of: (UUID, Result<Inbox, Error>).self) { group in
            for h in hosts { group.addTask { (h.config.id, await Result { try await h.inbox() }) } }
            for await (id, res) in group {
                switch res {
                case .success(let i): r += i.reviews; o += i.own; t += i.todos
                case .failure(let e): errs[id] = e.localizedDescription
                }
            }
        }
        reviews = r.sorted { $0.updated > $1.updated }
        ownMRs = o.sorted { $0.updated > $1.updated }
        todos = t.sorted { $0.updated > $1.updated }
        hostErrors = errs
    }

    func host(for ref: ChangeRef) -> CodeHost? { config.host(ref.hostID).flatMap(makeHost) }

    // MARK: Standup

    @Published var standup: Standup?
    @Published var standupBusy = false

    func buildStandup() async {
        standupBusy = true; defer { standupBusy = false }
        if isDemo { standup = Self.demoStandup(); return }
        let since = Standup.defaultSince()
        var acts: [Activity] = []
        if let c = jiraClient { acts += (try? await c.activity(since: since)) ?? [] }
        let hosts = config.hosts.filter(\.ready).compactMap(makeHost)
        await withTaskGroup(of: [Activity].self) { g in
            for h in hosts { g.addTask { (try? await h.activity(since: since)) ?? [] } }
            for await a in g { acts += a }
        }
        standup = StandupBuilder.build(since: since, activity: acts, jira: jira, reviews: reviews, own: ownMRs)
        await polishStandup()
    }

    @Published var polishing = false

    /// Re-run only the language model step (language switch, retry).
    func polishStandup() async {
        guard var s = standup else { return }
        guard let p = Polishers.make(config.aiProvider, apiKey: config.anthropicKey) else {
            s.polished = nil; s.polishError = config.aiProvider == .off ? nil : "AI provider not configured"; standup = s; return
        }
        polishing = true; defer { polishing = false }
        do { s.polished = try await p.polish(s, language: config.standupLanguage); s.polishError = nil }
        catch { s.polished = nil; s.polishError = error.localizedDescription }
        standup = s
    }

    /// Weekday reminder at the configured time. Cheap to reschedule on every change.
    func scheduleStandupReminder() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c0 = UNUserNotificationCenter.current()
        if !Features.standup { c0.removePendingNotificationRequests(withIdentifiers: (2...6).map { "standup.\($0)" }); return }
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: (2...6).map { "standup.\($0)" })
        guard config.standupReminder else { return }
        for wd in 2...6 {
            var dc = DateComponents(); dc.weekday = wd
            dc.hour = config.standupMinutes / 60; dc.minute = config.standupMinutes % 60
            let content = UNMutableNotificationContent()
            content.title = "Standup in a moment"
            content.body = "Your summary is ready — tap to open."
            content.userInfo = ["standup": true]
            c.add(UNNotificationRequest(identifier: "standup.\(wd)", content: content,
                                        trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)))
        }
    }

    static func demoStandup() -> Standup {
        var s = Standup(since: Standup.defaultSince())
        s.yesterday = ["Moved PAY-412 Refund webhook retries → In Progress · PAY",
                       "Approved pay/gateway!479 fix(ledger): settlement rounding · pay/gateway",
                       "Reviewed core/sdk!91 chore: bump swift-nio · core/sdk",
                       "Pushed to feat/refund-idempotency · pay/gateway"]
        s.today = ["Continue PAY-412 Refund webhook retries drop idempotency key after 3rd attempt",
                   "Review pay/gateway!482 feat(refund): persist idempotency key across retries (Nattapong S.)",
                   "Fix conflicts on core/sdk!88 refactor: hexagonal ports for payment adapters"]
        s.blockers = ["core/sdk!88 waiting for review since 20h ago"]
        return s
    }

    // MARK: Jira actions

    @Published var jiraCommentTarget: WorkItem? = nil
    @Published var flash: String? = nil

    private var jiraClient: JiraClient? {
        guard config.jiraReady, let u = config.jiraURL else { return nil }
        return JiraClient(base: u, email: config.jiraEmail, token: config.jiraToken)
    }

    func jiraTransitions(_ key: String) async -> [JiraClient.Transition] {
        guard let c = jiraClient else { return [] }
        return (try? await c.transitions(key)) ?? []
    }

    private func jiraDo(_ label: String, _ op: (JiraClient) async throws -> Void) async {
        guard let c = jiraClient else { return }
        guard await Auth.require("Pendrix: \(label)") else { return }
        do { try await op(c); flash = label; jiraError = nil; await refresh() }
        catch { jiraError = error.localizedDescription }
        Task { try? await Task.sleep(for: .seconds(2)); if flash == label { flash = nil } }
    }
    func jiraTransition(_ item: WorkItem, _ t: JiraClient.Transition) async {
        await jiraDo("\(item.key) → \(t.toStatus)") { try await $0.transition(item.key, to: t.id) }
    }
    func jiraComment(_ item: WorkItem, _ body: String) async {
        guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        await jiraDo("Commented on \(item.key)") { try await $0.comment(item.key, body) }
    }
    func jiraAssignToMe(_ item: WorkItem) async {
        await jiraDo("Assigned \(item.key) to you") { try await $0.assignToMe(item.key) }
    }

    // MARK: Jira ↔ MR linking

    private static let keyRegex = try! NSRegularExpression(pattern: "\\b[A-Z][A-Z0-9]{1,9}-[0-9]+\\b")

    static func jiraKeys(in text: String) -> [String] {
        let ns = text as NSString
        var seen = Set<String>(); var out: [String] = []
        for m in keyRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range)
            if seen.insert(k).inserted { out.append(k) }
        }
        return out
    }

    /// Jira issues an MR/PR mentions in its title or branch. Unknown keys become bare links.
    func linkedJira(for item: WorkItem) -> [WorkItem] {
        guard item.change != nil else { return [] }
        return Self.jiraKeys(in: item.title + " " + item.subtitle).compactMap { key in
            if let j = jira.first(where: { $0.key == key }) { return j }
            guard let u = config.jiraURL else { return nil }
            return WorkItem(id: "jira:\(key)", source: .jira, kind: .issue, key: key, title: "", subtitle: "",
                            url: u.appendingPathComponent("browse/\(key)"), updated: .distantPast)
        }
    }

    /// MRs/PRs whose title or branch mentions this Jira issue.
    func linkedChanges(for issue: WorkItem) -> [WorkItem] {
        (reviews + ownMRs).filter { Self.jiraKeys(in: $0.title + " " + $0.subtitle).contains(issue.key) }
    }

    func open(_ item: WorkItem) {
        unseen.remove(item.id)
        NSWorkspace.shared.open(item.url)
    }
    func markSeen(_ item: WorkItem) { unseen.remove(item.id) }
    func markAllSeen() { unseen.removeAll() }

    // MARK: notifications

    func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notify(_ item: WorkItem) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = switch item.kind {
        case .reviewRequest: "Review requested · \(item.key)"
        case .todo: item.subtitle
        case .issue: "New Jira task · \(item.key)"
        case .ownMergeRequest: item.key
        }
        c.body = item.title
        c.userInfo = ["url": item.url.absoluteString]
        if let ch = item.change, let data = try? JSONEncoder().encode(ch) { c.userInfo["change"] = String(decoding: data, as: UTF8.self) }
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: c, trigger: nil))
    }

    // MARK: demo data for --snapshot / design work

    private func loadDemo() {
        let now = Date()
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
        let u = URL(string: "https://example.com")!
        jira = [
            WorkItem(id: "jira:PAY-412", source: .jira, kind: .issue, key: "PAY-412", title: "Refund webhook retries drop idempotency key after 3rd attempt", subtitle: "Bug", url: u, updated: ago(0.4), status: "In Progress", statusTone: .active, priority: "High"),
            WorkItem(id: "jira:PAY-398", source: .jira, kind: .issue, key: "PAY-398", title: "Migrate settlement report to new ledger schema", subtitle: "Story", url: u, updated: ago(3), status: "In Review", statusTone: .active, priority: "Medium"),
            WorkItem(id: "jira:CORE-77", source: .jira, kind: .issue, key: "CORE-77", title: "Rate limiter: per-tenant buckets", subtitle: "Task", url: u, updated: ago(26), status: "To Do", statusTone: .neutral, priority: "Low"),
            WorkItem(id: "jira:CORE-81", source: .jira, kind: .issue, key: "CORE-81", title: "Spike: evaluate Swift 6 strict concurrency for SDK", subtitle: "Spike", url: u, updated: ago(50), status: "To Do", statusTone: .neutral, priority: "Lowest"),
        ]
        reviews = [
            WorkItem(id: "gl:mr:1", source: .gitlab, kind: .reviewRequest, key: "pay/gateway!482", title: "PAY-412 feat(refund): persist idempotency key across retries", subtitle: "Nattapong S.", url: u, updated: ago(0.2), status: "needs approval", statusTone: .active, pipeline: "success", hostLabel: "git.7.solutions"),
            WorkItem(id: "gh:pr:2", source: .gitlab, kind: .reviewRequest, key: "7solutions/sdk#91", title: "chore: bump swift-nio, drop deprecated EventLoopFuture helpers", subtitle: "maip", url: u, updated: ago(5), status: "threads open", statusTone: .warn, pipeline: "failed", hostLabel: "github.com"),
            WorkItem(id: "gl:mr:3", source: .gitlab, kind: .reviewRequest, key: "infra/helm!17", title: "Add PodDisruptionBudget for gateway", subtitle: "Ken W.", url: u, updated: ago(30), status: "draft", statusTone: .neutral, isDraft: true, pipeline: "running", hostLabel: "git.7.solutions"),
        ]
        ownMRs = [
            WorkItem(id: "gl:mr:4", source: .gitlab, kind: .ownMergeRequest, key: "pay/gateway!479", title: "fix(ledger): settlement rounding on multi-currency", subtitle: "fix/ledger-rounding", url: u, updated: ago(1.5), status: "mergeable", statusTone: .done, pipeline: "success", approvals: 2, hostLabel: "git.7.solutions"),
            WorkItem(id: "gl:mr:5", source: .gitlab, kind: .ownMergeRequest, key: "core/sdk!88", title: "refactor: hexagonal ports for payment adapters", subtitle: "refactor/ports", url: u, updated: ago(20), status: "conflicts", statusTone: .danger, hasConflicts: true, pipeline: "success", hostLabel: "git.7.solutions"),
        ]
        todos = [
            WorkItem(id: "gl:todo:9", source: .gitlab, kind: .todo, key: "pay/gateway#203", title: "Timeout on 3DS callback under load", subtitle: "Beam T. · mentioned you", url: u, updated: ago(0.8), status: "mentioned you", statusTone: .warn, hostLabel: "git.7.solutions"),
        ]
        unseen = ["gl:mr:1", "gl:todo:9", "jira:PAY-412"]
        lastRefresh = ago(0.03)
    }

    static func demoDetail() -> ChangeDetail {
        let patch = """
        @@ -41,9 +41,14 @@ final class RefundWorker {
             func retry(_ job: RefundJob) async throws {
        -        let key = UUID().uuidString
        -        try await gateway.refund(job.paymentID, amount: job.amount, idempotencyKey: key)
        +        // Reuse the key across attempts so the gateway can dedupe.
        +        let key = job.idempotencyKey ?? UUID().uuidString
        +        var job = job
        +        job.idempotencyKey = key
        +        try await store.save(job)
        +        try await gateway.refund(job.paymentID, amount: job.amount, idempotencyKey: key)
             }
         
             private func backoff(_ attempt: Int) -> Duration {
        -        .seconds(min(60, 1 << attempt))
        +        .seconds(min(300, 1 << attempt))
             }
         }
        """
        let hunks = DiffParser.parse(patch)
        let (a, d) = DiffParser.counts(hunks)
        let ref = ChangeRef(hostID: UUID(), project: "1", number: 482)
        return ChangeDetail(
            ref: ref, title: "feat(refund): persist idempotency key across retries",
            description: "Retries were minting a new idempotency key each attempt, so the gateway saw N distinct refunds.\n\nCloses PAY-412.",
            author: "Nattapong S.", sourceBranch: "feat/refund-idempotency", targetBranch: "main",
            url: URL(string: "https://example.com")!, state: "not_approved", draft: false, approvedByMe: false, approvals: ["Mai P."],
            mergeable: false, pipeline: "success",
            files: [
                FileDiff(oldPath: "Sources/Refund/RefundWorker.swift", newPath: "Sources/Refund/RefundWorker.swift", status: .modified, hunks: hunks, additions: a, deletions: d, binary: false),
                FileDiff(oldPath: "Sources/Refund/RefundJob.swift", newPath: "Sources/Refund/RefundJob.swift", status: .modified, hunks: [], additions: 1, deletions: 0, binary: false),
                FileDiff(oldPath: "Tests/RefundWorkerTests.swift", newPath: "Tests/RefundWorkerTests.swift", status: .added, hunks: [], additions: 42, deletions: 0, binary: false),
            ],
            threads: [
                ReviewThread(id: "t1", anchor: LineAnchor(path: "Sources/Refund/RefundWorker.swift", oldLine: nil, newLine: 47), resolved: false, resolvable: true,
                             comments: [Comment(id: "c1", author: "Mai P.", body: "Should this save happen before we call the gateway? If save fails we still refund.", created: Date().addingTimeInterval(-3600)),
                                        Comment(id: "c2", author: "Nattapong S.", body: "Yes — intentional, we want the key durable before the network call.", created: Date().addingTimeInterval(-1800))]),
                ReviewThread(id: "t2", anchor: nil, resolved: false, resolvable: false,
                             comments: [Comment(id: "c3", author: "Ken W.", body: "Ran this against staging, dedupe works.", created: Date().addingTimeInterval(-7200))]),
            ],
            baseSHA: "a", startSHA: "a", headSHA: "b")
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
