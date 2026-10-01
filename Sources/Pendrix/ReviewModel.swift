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
    @Published var aiTiming = ""
    @Published var askingAt: LineAnchor? = nil
    var aiAutoStarted = false

    /// Files the AI pass looked at and left without findings.
    func aiChecked(_ f: FileDiff) -> Bool {
        guard aiMode != nil, !aiRunning, !aiSkipped.contains(f.path) else { return false }
        return !aiDrafts.contains { $0.path == f.path }
    }

    func ask(_ question: String, at line: DiffLine, in file: FileDiff) async {
        guard let d = detail else { return }
        let anchor = AIReviewer.anchor(for: line, path: file.path)
        askingAt = anchor; composing = nil
        defer { askingAt = nil }
        do {
            let draft = try await AIReviewer.ask(question, at: anchor, line: line, file: file, detail: d)
            aiDrafts.append(draft)
            if aiMode == nil { aiMode = .diffOnly }
            persistAI()
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
            aiTiming = AIReviewer.lastTiming
            showDrafts = true; selectedFile = nil
            persistAI()
        } catch { aiError = error.localizedDescription }
    }

    /// Bring back a previous pass for the same head commit; a new push invalidates it (and lets auto-review run again).
    private func restoreAI(for d: ChangeDetail) {
        guard aiDrafts.isEmpty, let s = AIReviewer.load(for: ref) else { return }
        if s.headSHA == d.headSHA {
            aiSummary = s.summary; aiDrafts = s.drafts; aiSkipped = s.skipped; aiMode = s.mode
            aiAutoStarted = true
        } else {
            aiStale = !s.drafts.filter { !$0.posted }.isEmpty
        }
    }
    @Published var aiStale = false   // a previous pass existed but the MR moved on
    func persistAI() {
        guard let d = detail else { return }
        AIReviewer.save(.init(headSHA: d.headSHA, summary: aiSummary, drafts: aiDrafts, skipped: aiSkipped, mode: aiMode ?? .diffOnly), for: ref)
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
    /// Drafts for this file that could not be pinned to a visible line (or whose line isn't in the hunks).
    func unanchoredDrafts(in file: FileDiff) -> [AIDraft] {
        let ids = Set(file.hunks.flatMap(\.lines).map(\.id))
        let index = lineIndex(for: file).drafts
        let anchored = Set(index.filter { ids.contains($0.key) }.values.flatMap { $0 }.map(\.id))
        return pendingDrafts.filter { $0.path == file.path && !anchored.contains($0.id) }
    }
    func update(_ draft: AIDraft, body: String) {
        if let i = aiDrafts.firstIndex(where: { $0.id == draft.id }) { aiDrafts[i].body = body }
        persistAI()
    }
    func dismiss(_ draft: AIDraft) { aiDrafts.removeAll { $0.id == draft.id }; persistAI() }
    /// Re-derive old/new numbers from the current diff so stored anchors (older rules, or a new push) post correctly.
    func normalized(_ a: LineAnchor?, in d: ChangeDetail) -> LineAnchor? {
        guard let a, let file = d.files.first(where: { $0.path == a.path }) else { return a }
        let lines = file.hunks.flatMap(\.lines)
        if let n = a.newLine, let l = lines.first(where: { $0.kind != .del && $0.newNo == n }) { return AIReviewer.anchor(for: l, path: file.path) }
        if let o = a.oldLine, let l = lines.first(where: { $0.kind == .del && $0.oldNo == o }) { return AIReviewer.anchor(for: l, path: file.path) }
        if let o = a.oldLine, let l = lines.first(where: { $0.oldNo == o }) { return AIReviewer.anchor(for: l, path: file.path) }
        return a
    }

    /// Posts one draft as a real comment (anchored when the line resolved, otherwise on the conversation with a path prefix).
    func post(_ draft: AIDraft) async {
        guard let host, let d = detail else { return }
        var draft = draft
        draft.anchor = normalized(draft.anchor, in: d)
        let body = draft.anchor != nil ? draft.display : "`\(draft.path ?? "")`\n\n\(draft.display)"
        guard await Auth.require("Pendrix: post comment on \(d.title)") else { return }
        busy = true
        do {
            do { try await host.comment(ref, at: draft.anchor, body: body, detail: d) }
            catch let e as APIError where e.message.contains("line_code") || e.message.contains("HTTP 400") {
                let fresh = try await host.detail(ref); detail = fresh
                try await host.comment(ref, at: normalized(draft.anchor, in: fresh), body: body, detail: fresh)
            }
            if let i = aiDrafts.firstIndex(where: { $0.id == draft.id }) { aiDrafts[i].posted = true }
            persistAI()
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
    /// Sidebar file filter: every whitespace-separated token must appear in the path (case-insensitive).
    @Published var fileQuery = ""
    @Published var fileFilterFocusRequest = 0
    var allShownFiles: [FileDiff] { commitMode ? commitFiles : (detail?.files ?? []) }
    var shownFiles: [FileDiff] {
        let tokens = fileQuery.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return allShownFiles }
        return allShownFiles.filter { f in let p = f.path.lowercased(); return tokens.allSatisfy { p.contains($0) } }
    }

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
            restoreAI(for: d)
            if selectedFile == nil, d.threads.filter({ $0.anchor == nil }).isEmpty { selectedFile = d.files.first?.path }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func file(_ path: String?) -> FileDiff? { shownFiles.first { $0.path == path } }

    func threads(for path: String?) -> [ReviewThread] {
        commitMode ? [] : (detail?.threads.filter { $0.anchor?.path == path } ?? [])
    }
    /// Threads and drafts keyed by DiffLine.id, built once per render instead of filtering per row.
    func lineIndex(for file: FileDiff) -> (threads: [Int: [ReviewThread]], drafts: [Int: [AIDraft]]) {
        var t: [Int: [ReviewThread]] = [:], d: [Int: [AIDraft]] = [:]
        let ts = threads(for: file.path), ds = commitMode ? [] : pendingDrafts.filter { $0.path == file.path }
        guard !ts.isEmpty || !ds.isEmpty else { return (t, d) }
        var byNew: [Int: Int] = [:], byOld: [Int: Int] = [:]
        for l in file.hunks.flatMap(\.lines) {
            if let n = l.newNo, l.kind != .del { byNew[n] = l.id }
            if l.kind == .del, let o = l.oldNo { byOld[o] = l.id }
        }
        func lineID(_ a: LineAnchor?) -> Int? {
            guard let a else { return nil }
            if let n = a.newLine { return byNew[n] }
            if let o = a.oldLine { return byOld[o] }
            return nil
        }
        for th in ts { if let id = lineID(th.anchor) { t[id, default: []].append(th) } }
        for df in ds { if let id = lineID(df.anchor) { d[id, default: []].append(df) } }
        return (t, d)
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
        let a0 = normalized(anchor, in: d)
        await perform("Comment posted") {
            do { try await host.comment(self.ref, at: a0, body: body, detail: d) }
            catch let e as APIError where e.message.contains("line_code") || e.message.contains("HTTP 400") {
                // position rejected: usually SHAs moved after a push — reload and try once with fresh refs
                let fresh = try await host.detail(self.ref)
                let a1 = await MainActor.run { self.detail = fresh; return self.normalized(anchor, in: fresh) }
                try await host.comment(self.ref, at: a1, body: body, detail: fresh)
            }
        }
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
