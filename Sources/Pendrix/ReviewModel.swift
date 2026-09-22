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
        guard !commitMode, let f = file(selectedFile) else { return }
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
