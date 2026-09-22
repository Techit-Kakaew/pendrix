import Foundation
import CryptoKit

struct DiffLine: Identifiable, Hashable {
    enum Kind { case context, add, del, meta }
    let id: Int
    let kind: Kind
    let oldNo: Int?
    let newNo: Int?
    let text: String
}

struct Hunk: Identifiable, Hashable {
    let id: Int
    let header: String
    var lines: [DiffLine]
}

struct FileDiff: Identifiable, Hashable {
    enum Status { case added, deleted, renamed, modified }
    var id: String { newPath }
    let oldPath: String
    let newPath: String
    let status: Status
    let hunks: [Hunk]
    let additions: Int
    let deletions: Int
    let binary: Bool
    var path: String { newPath }
    /// Path + content digest. Viewed marks key on this, so a file that changes after a push comes back unviewed.
    var digest: String {
        let text = hunks.flatMap { $0.lines.map(\.text) }.joined(separator: "\n")
        let h = SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(newPath)@\(h)"
    }
}

/// Unified-diff body parser. GitLab `diff` and GitHub `patch` are both hunk-only (no ---/+++ header).
enum DiffParser {
    static func parse(_ text: String) -> [Hunk] {
        var hunks: [Hunk] = []
        var cur: Hunk?
        var old = 0, new = 0, lid = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                if let c = cur { hunks.append(c) }
                // @@ -12,7 +12,9 @@ optional
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    old = Int(parts[1].dropFirst().split(separator: ",").first ?? "0") ?? 0
                    new = Int(parts[2].dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
                cur = Hunk(id: hunks.count, header: line, lines: [])
                continue
            }
            guard cur != nil else { continue }
            lid += 1
            if line.hasPrefix("+") {
                cur!.lines.append(DiffLine(id: lid, kind: .add, oldNo: nil, newNo: new, text: String(line.dropFirst()))); new += 1
            } else if line.hasPrefix("-") {
                cur!.lines.append(DiffLine(id: lid, kind: .del, oldNo: old, newNo: nil, text: String(line.dropFirst()))); old += 1
            } else if line.hasPrefix("\\") {
                cur!.lines.append(DiffLine(id: lid, kind: .meta, oldNo: nil, newNo: nil, text: line))
            } else if line.isEmpty && raw == text.split(separator: "\n", omittingEmptySubsequences: false).last {
                continue // trailing newline
            } else {
                cur!.lines.append(DiffLine(id: lid, kind: .context, oldNo: old, newNo: new, text: String(line.dropFirst()))); old += 1; new += 1
            }
        }
        if let c = cur { hunks.append(c) }
        return hunks
    }

    static func counts(_ hunks: [Hunk]) -> (Int, Int) {
        var a = 0, d = 0
        for h in hunks { for l in h.lines { if l.kind == .add { a += 1 } else if l.kind == .del { d += 1 } } }
        return (a, d)
    }
}
