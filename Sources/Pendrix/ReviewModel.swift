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

    init(ref: ChangeRef, host: CodeHost?, kind: HostKind) {
        self.ref = ref; self.host = host; self.kind = kind
    }

    /// Demo instance for --snapshot.
    init(demo: ChangeDetail) {
        ref = demo.ref; host = nil; kind = .gitlab; detail = demo; selectedFile = demo.files.first?.path
    }

    func load() async {
        guard let host else { error = "Account for this change was removed"; return }
        busy = true; defer { busy = false }
        do {
            let d = try await host.detail(ref)
            detail = d
            if selectedFile == nil, d.threads.filter({ $0.anchor == nil }).isEmpty { selectedFile = d.files.first?.path }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func file(_ path: String?) -> FileDiff? { detail?.files.first { $0.path == path } }

    func threads(for path: String?) -> [ReviewThread] {
        detail?.threads.filter { $0.anchor?.path == path } ?? []
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
