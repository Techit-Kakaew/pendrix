import SwiftUI

/// GitLab/GitHub "suggestion" block: replaces the commented line plus `above`/`below` neighbours.
/// Emits ```suggestion:-A+B (GitLab) or plain ```suggestion with a start line (GitHub multi-line).
struct SuggestionEditor: View {
    let file: FileDiff
    let line: DiffLine
    let kind: HostKind
    @Binding var above: Int
    @Binding var below: Int
    @Binding var text: String

    /// New-side lines (context + additions) in file order; suggestions apply to the new file.
    private var newLines: [DiffLine] { file.hunks.flatMap(\.lines).filter { $0.kind != .del && $0.kind != .meta && $0.newNo != nil } }
    private var range: [DiffLine] {
        guard let n = line.newNo else { return [line] }
        return newLines.filter { ($0.newNo ?? 0) >= n - above && ($0.newNo ?? 0) <= n + below }
    }
    var originalText: String { range.map(\.text).joined(separator: "\n") }
    var firstLine: Int { range.first?.newNo ?? line.newNo ?? 0 }
    var lastLine: Int { range.last?.newNo ?? line.newNo ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Suggested change").font(Type.meta).fontWeight(.medium)
                Text("lines \(firstLine)–\(lastLine)").font(Type.key).foregroundStyle(.tertiary)
                Spacer()
                stepper("above", $above)
                stepper("below", $below)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(range) { l in
                    Text(l.text.isEmpty ? " " : l.text).font(.system(size: 11.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 1)
                        .background(WorkItem.Tone.danger.color.opacity(0.12))
                }
                TextEditor(text: $text)
                    .font(.system(size: 11.5, design: .monospaced)).scrollContentBackground(.hidden)
                    .frame(minHeight: CGFloat(max(2, text.split(separator: "\n", omittingEmptySubsequences: false).count)) * 17 + 8)
                    .padding(.horizontal, 4)
                    .background(WorkItem.Tone.done.color.opacity(0.12))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(kind == .gitlab ? "Author gets an Apply button in GitLab." : "Author gets a Commit suggestion button in GitHub.").font(Type.meta).foregroundStyle(.tertiary)
        }
        .onChange(of: above) { _, _ in resetIfUntouched() }
        .onChange(of: below) { _, _ in resetIfUntouched() }
        .onAppear { if text.isEmpty { text = originalText } }
    }

    @State private var lastOriginal = ""
    private func resetIfUntouched() {
        // keep the user's edits unless the box still held the previous original
        if text == lastOriginal || text.isEmpty { text = originalText }
        lastOriginal = originalText
    }

    private func stepper(_ label: String, _ v: Binding<Int>) -> some View {
        HStack(spacing: 2) {
            Text(label).font(Type.meta).foregroundStyle(.tertiary)
            Button("−") { v.wrappedValue = max(0, v.wrappedValue - 1) }.buttonStyle(.plain).foregroundStyle(.secondary)
            Text("\(v.wrappedValue)").font(Type.key).monospacedDigit()
            Button("+") { v.wrappedValue = min(20, v.wrappedValue + 1) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    /// Markdown block for the host, plus the anchor adjusted for a multi-line range.
    func render(comment: String) -> (body: String, anchor: LineAnchor) {
        let code = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let fence = kind == .gitlab ? "```suggestion:-\(above)+\(below)" : "```suggestion"
        let body = (comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : comment.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n") + "\(fence)\n\(code)\n```"
        var a = AIReviewer.anchor(for: line, path: file.path)
        if kind == .github {
            // GitHub anchors multi-line suggestions on the LAST line, with start_line for the first
            a = LineAnchor(path: file.path, oldLine: nil, newLine: lastLine, startNewLine: above + below > 0 ? firstLine : nil)
        }
        return (body, a)
    }
}

/// Renders ```suggestion blocks inside a posted comment as a red/green box.
struct SuggestionBlockView: View {
    let code: String
    let original: [String]?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Suggested change").font(Type.meta).fontWeight(.medium).padding(.horizontal, 8).padding(.vertical, 4)
            if let o = original {
                ForEach(Array(o.enumerated()), id: \.offset) { _, l in
                    Text(l.isEmpty ? " " : l).font(.system(size: 11.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 1)
                        .background(WorkItem.Tone.danger.color.opacity(0.12))
                }
            }
            ForEach(Array(code.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, l in
                Text(l.isEmpty ? " " : String(l)).font(.system(size: 11.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 1)
                    .background(WorkItem.Tone.done.color.opacity(0.12))
            }
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

enum SuggestionMarkdown {
    /// Splits a comment into prose and suggestion blocks. Returns (prose, [(above, below, code)]).
    static func parse(_ body: String) -> (prose: String, blocks: [(above: Int, below: Int, code: String)]) {
        var prose = body, blocks: [(Int, Int, String)] = []
        let re = try! NSRegularExpression(pattern: "```suggestion(?::-(\\d+)\\+(\\d+))?[ \\t]*\\n([\\s\\S]*?)\\n?```", options: [])
        let ns = body as NSString
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)).reversed() {
            let a = m.range(at: 1).location == NSNotFound ? 0 : Int(ns.substring(with: m.range(at: 1))) ?? 0
            let b = m.range(at: 2).location == NSNotFound ? 0 : Int(ns.substring(with: m.range(at: 2))) ?? 0
            blocks.insert((a, b, ns.substring(with: m.range(at: 3))), at: 0)
            prose = (prose as NSString).replacingCharacters(in: m.range, with: "")
        }
        return (prose.trimmingCharacters(in: .whitespacesAndNewlines), blocks)
    }
}
