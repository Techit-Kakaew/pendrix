import Foundation
import Combine
import AppKit

/// State for one review window. Loads the change, performs actions, reloads.
@MainActor
final class ReviewModel: ObservableObject {
    let ref: ChangeRef
    let host: CodeHost?
    let kind: HostKind
    @Published var detail: ChangeDetail?
    @Published var error: String?
    @Published var busy = false
    @Published var selectedFile: String? = nil     // nil = conversation
    @Published var composing: LineAnchor? = nil    // line being commented on
    @Published var flash: String? = nil
    /// Commit mode: browsing one commit's files instead of the whole change. Commenting is off there.
    @Published var selectedCommit: CommitInfo? = nil
    @Published var commitFiles: [FileDiff] = []
    @Published var commitLoading = false
    var commitMode: Bool { selectedCommit != nil }

    // MARK: AI review drafts (local until posted)

    @Published var aiDrafts: [AIDraft] = []
    @Published var aiSummary: String = ""
    @Published var aiSkipped: [String] = []
    @Published var aiRunning = false
    @Published var aiError: String?
    @Published var aiMode: AIReviewer.Mode? = nil
    @Published var askingAt: LineAnchor? = nil
    var aiAutoStarted = false

    /// Files the AI pass looked at and left without findings.
    func aiChecked(_ f: FileDiff) -> Bool {
        guard aiMode != nil, !aiRunning, !aiSkipped.contains(f.path) else { return false }
        return !aiDrafts.contains { $0.path == f.path }
    }

    func ask(_ question: String, at line: DiffLine, in file: FileDiff) async {
        guard let d = detail else { return }
        let anchor = LineAnchor(path: file.path, oldLine: line.kind == .del ? line.oldNo : nil, newLine: line.kind == .del ? nil : line.newNo)
        askingAt = anchor; composing = nil
        defer { askingAt = nil }
        do {
            let draft = try await AIReviewer.ask(question, at: anchor, line: line, file: file, detail: d)
            aiDrafts.append(draft)
            if aiMode == nil { aiMode = .diffOnly }
        } catch { aiError = error.localizedDescription; self.error = error.localizedDescription }
    }
    @Published var showDrafts = false          // sidebar "AI drafts" screen selected
    var pendingDrafts: [AIDraft] { aiDrafts.filter { !$0.posted } }

    func runAIReview() async {
        guard let d = detail, !aiRunning else { return }
        aiRunning = true; aiError = nil
        defer { aiRunning = false }
        do {
            let r = try await AIReviewer.review(d)
            aiSummary = r.summary; aiDrafts = r.drafts; aiSkipped = r.skipped; aiMode = r.mode
            showDrafts = true; selectedFile = nil
        } catch { aiError = error.localizedDescription }
    }
    func drafts(at line: DiffLine, in path: String) -> [AIDraft] {
        pendingDrafts.filter { dft in
            guard let a = dft.anchor, a.path == path else { return false }
            if let n = line.newNo, a.newLine == n { return true }
            if line.kind == .del, let o = line.oldNo, a.oldLine == o, a.newLine == nil { return true }
            return false
        }
    }
    func draftCount(in path: String) -> Int { pendingDrafts.filter { $0.path == path }.count }
    func update(_ draft: AIDraft, body: String) {
        if let i = aiDrafts.firstIndex(where: { $0.id == draft.id }) { aiDrafts[i].body = body }
    }
    func dismiss(_ draft: AIDraft) { aiDrafts.removeAll { $0.id == draft.id } }
    /// Posts one draft as a real comment (anchored when the line resolved, otherwise on the conversation with a path prefix).
    func post(_ draft: AIDraft) async {
        guard let host, let d = detail else { return }
        let body = draft.anchor != nil ? draft.display : "`\(draft.path ?? "")`\n\n\(draft.display)"
        guard await Auth.require("Pendrix: post comment on \(d.title)") else { return }
        busy = true
        do {
            try await host.comment(ref, at: draft.anchor, body: body, detail: d)
            if let i = aiDrafts.firstIndex(where: { $0.id == draft.id }) { aiDrafts[i].posted = true }
            flash = "Comment posted"; error = nil
            await load()
        } catch { self.error = error.localizedDescription }
        busy = false
        Task { try? await Task.sleep(for: .seconds(2)); if flash == "Comment posted" { flash = nil } }
    }
    func jump(to draft: AIDraft) {
        showDrafts = false
        selectedFile = draft.path
    }

    // MARK: search (current file) + file stepping

    @Published var query = ""
    @Published var matchIndex = 0
    @Published var searchFocusRequest = 0     // bump to focus the search field
    var searchActive: Bool { !query.isEmpty }

    func matches(in f: FileDiff) -> [Int] {
        guard !query.isEmpty else { return [] }
        return f.hunks.flatMap(\.lines).filter { $0.kind != .meta && $0.text.localizedCaseInsensitiveContains(query) }.map(\.id)
    }
    func matchCount(in f: FileDiff) -> Int {
        guard !query.isEmpty else { return 0 }
        return f.hunks.flatMap(\.lines).reduce(0) { $0 + (($1.kind != .meta && $1.text.localizedCaseInsensitiveContains(query)) ? 1 : 0) }
    }
    /// Step through matches in the open file; wraps.
    func stepMatch(_ delta: Int) {
        guard let f = file(selectedFile) else { return }
        let n = matches(in: f).count; guard n > 0 else { return }
        matchIndex = ((matchIndex + delta) % n + n) % n
    }
    func selectFile(offset: Int) {
        showDrafts = false
        let files = shownFiles; guard !files.isEmpty else { return }
        let idx = files.firstIndex { $0.path == selectedFile } ?? (offset > 0 ? -1 : files.count)
        selectedFile = files[max(0, min(files.count - 1, idx + offset))].path
        matchIndex = 0
    }

    /// True while a text field/view has keyboard focus, so single-key shortcuts stay out of the way of typing.
    static var isTyping: Bool {
        guard let r = NSApp.keyWindow?.firstResponder else { return false }
        return r is NSTextView || r is NSTextField
    }

    // MARK: viewed files (local, per change)

    @Published private(set) var viewed: Set<String> = []
    private var viewedKey: String { "viewed.\(ref.hostID).\(ref.project).\(ref.number)" }
    func loadViewed() { viewed = Set(UserDefaults.standard.stringArray(forKey: viewedKey) ?? []) }
    func isViewed(_ f: FileDiff) -> Bool { viewed.contains(f.digest) }
    func setViewed(_ f: FileDiff, _ on: Bool) {
        if on { viewed.insert(f.digest) } else { viewed.remove(f.digest) }
        // keep only digests that still exist so the set doesn't grow forever
        let live = Set(detail?.files.map(\.digest) ?? [])
        UserDefaults.standard.set(Array(viewed.intersection(live)), forKey: viewedKey)
    }
    /// Toggle the open file and step to the next unviewed one.
    func toggleViewedAndAdvance() {
        guard !Self.isTyping, !commitMode, let f = file(selectedFile) else { return }
        let now = !isViewed(f)
        setViewed(f, now)
        guard now, let files = detail?.files, let idx = files.firstIndex(where: { $0.path == f.path }) else { return }
        if let next = (files[(idx + 1)...] + files[..<idx]).first(where: { !isViewed($0) }) { selectedFile = next.path }
    }
    var viewedCount: Int { detail?.files.filter(isViewed).count ?? 0 }
    var shownFiles: [FileDiff] { commitMode ? commitFiles : (detail?.files ?? []) }

    func showCommit(_ c: CommitInfo?) {
        selectedCommit = c; commitFiles = []; composing = nil
        guard let c else { selectedFile = detail?.files.first?.path; return }
        selectedFile = nil
        guard let host else { return }
        commitLoading = true
        Task {
            defer { commitLoading = false }
            do {
                let files = try await host.commitDiff(ref, sha: c.id)
                guard selectedCommit?.id == c.id else { return }
                commitFiles = files; selectedFile = files.first?.path
            } catch { self.error = error.localizedDescription }
        }
    }

    init(ref: ChangeRef, host: CodeHost?, kind: HostKind) {
        self.ref = ref; self.host = host; self.kind = kind
    }

    /// Demo instance for --snapshot.
    init(demo: ChangeDetail) {
        ref = demo.ref; host = nil; kind = .gitlab; detail = demo; selectedFile = demo.files.first?.path
        viewed = [demo.files[1].digest]
    }

    func load() async {
        guard let host else { error = "Account for this change was removed"; return }
        busy = true; defer { busy = false }
        do {
            let d = try await host.detail(ref)
            detail = d
            loadViewed()
            if selectedFile == nil, d.threads.filter({ $0.anchor == nil }).isEmpty { selectedFile = d.files.first?.path }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func file(_ path: String?) -> FileDiff? { shownFiles.first { $0.path == path } }

    func threads(for path: String?) -> [ReviewThread] {
        commitMode ? [] : (detail?.threads.filter { $0.anchor?.path == path } ?? [])
    }
    func threads(at line: DiffLine, in path: String) -> [ReviewThread] {
        threads(for: path).filter { t in
            guard let a = t.anchor else { return false }
            if let n = line.newNo, a.newLine == n { return true }
            if line.kind == .del, let o = line.oldNo, a.oldLine == o, a.newLine == nil { return true }
            return false
        }
    }
    var unresolvedCount: Int { detail?.threads.filter { $0.resolvable && !$0.resolved }.count ?? 0 }

    private func perform(_ label: String, _ op: @escaping () async throws -> Void) async {
        guard let _ = host else { return }
        guard await Auth.require("Pendrix: \(label.lowercased()) on \(detail?.title ?? "this change")") else {
            error = "Authentication cancelled"; return
        }
        busy = true
        do { try await op(); flash = label; error = nil; await load() } catch { self.error = error.localizedDescription }
        busy = false
        Task { try? await Task.sleep(for: .seconds(2)); if flash == label { flash = nil } }
    }

    func comment(_ body: String, at anchor: LineAnchor?) async {
        guard let host, let d = detail, !body.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        composing = nil
        await perform("Comment posted") { try await host.comment(self.ref, at: anchor, body: body, detail: d) }
    }
    func reply(_ body: String, to thread: ReviewThread) async {
        guard let host, !body.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        await perform("Reply posted") { try await host.reply(self.ref, thread: thread, body: body) }
    }
    func resolve(_ thread: ReviewThread, _ resolved: Bool) async {
        guard let host else { return }
        await perform(resolved ? "Resolved" : "Reopened") { try await host.resolve(self.ref, thread: thread, resolved: resolved) }
    }
    func approve(_ on: Bool) async {
        guard let host else { return }
        await perform(on ? "Approved" : "Approval removed") { try await host.approve(self.ref, approve: on) }
    }
    func merge() async {
        guard let host else { return }
        await perform("Merged") { try await host.merge(self.ref) }
    }
    func openInBrowser() { if let u = detail?.url { NSWorkspace.shared.open(u) } }
}
