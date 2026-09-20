import SwiftUI

/// Unified diff for one file. Click a line number to comment on that line; threads render under their line.
struct DiffView: View {
    let file: FileDiff
    @ObservedObject var model: ReviewModel
    @State private var draft = ""
    @State private var colored: [Int: AttributedString] = [:]
    @Environment(\.colorScheme) private var scheme

    private let mono = Font.system(size: 11.5, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(file.path).font(Type.key).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                if file.status == .renamed { Text("from \(file.oldPath)").font(Type.meta).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer()
                Text("+\(file.additions)").font(Type.key).foregroundStyle(WorkItem.Tone.done.color)
                Text("−\(file.deletions)").font(Type.key).foregroundStyle(WorkItem.Tone.danger.color)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().opacity(0.4)
            if file.binary || file.hunks.isEmpty {
                Text(file.binary ? "Binary file" : "No diff to show").font(Type.meta).foregroundStyle(.tertiary).padding(16)
                Spacer()
            } else {
                Scrolling(indicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(file.hunks) { h in
                            Text(h.header).font(mono).foregroundStyle(.tertiary)
                                .padding(.horizontal, 16).padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.03))
                            ForEach(h.lines) { l in
                                row(l)
                                let ts = model.threads(at: l, in: file.path)
                                if !ts.isEmpty || model.composing == anchor(l) {
                                    VStack(spacing: 8) {
                                        ForEach(ts) { t in ThreadView(thread: t, model: model) }
                                        if model.composing == anchor(l) {
                                            ComposeBox(text: $draft, placeholder: "Comment on line \(l.newNo ?? l.oldNo ?? 0)…", submit: "Comment") {
                                                Task { await model.comment(draft, at: anchor(l)); draft = "" }
                                            } cancel: { model.composing = nil; draft = "" }
                                            .padding(12)
                                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.06)))
                                        }
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 8)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .task(id: "\(file.id)|\(scheme)") {
            colored = [:]
            colored = await Highlighting.shared.lines(for: file, dark: scheme == .dark)
        }
    }

    private func anchor(_ l: DiffLine) -> LineAnchor {
        LineAnchor(path: file.path, oldLine: l.kind == .del ? l.oldNo : (l.newNo == nil ? l.oldNo : nil), newLine: l.kind == .del ? nil : l.newNo)
    }

    private func row(_ l: DiffLine) -> some View {
        let bg: Color = switch l.kind {
        case .add: WorkItem.Tone.done.color.opacity(0.10)
        case .del: WorkItem.Tone.danger.color.opacity(0.10)
        default: .clear
        }
        let sign = l.kind == .add ? "+" : l.kind == .del ? "−" : " "
        return HStack(spacing: 0) {
            Button { model.composing = model.composing == anchor(l) ? nil : anchor(l) } label: {
                HStack(spacing: 0) {
                    Text(l.oldNo.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
                    Text(l.newNo.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
                }
                .font(mono).foregroundStyle(.quaternary).padding(.trailing, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Comment on this line")
            .disabled(l.kind == .meta)
            Text(sign).font(mono).foregroundStyle(l.kind == .add ? WorkItem.Tone.done.color : l.kind == .del ? WorkItem.Tone.danger.color : .clear)
                .frame(width: 12)
            Group {
                if let c = colored[l.id] { Text(c) } else { Text(l.text.isEmpty ? " " : l.text).font(mono) }
            }
            .textSelection(.enabled)
            .foregroundStyle(l.kind == .meta ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.trailing, 16).padding(.vertical, 1.5)
        .background(bg)
    }
}
