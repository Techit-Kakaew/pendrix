import SwiftUI

/// One work item. No icons: the key, a status word and a tone dot carry the meaning.
struct ItemRow: View {
    let item: WorkItem
    let isNew: Bool
    let open: () -> Void
    var links: [WorkItem] = []
    var openLink: ((WorkItem) -> Void)? = nil
    var menu: AnyView? = nil
    var selected = false
    var aging = false
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Circle().fill(isNew ? WorkItem.pendingColor : .clear)
                    .shadow(color: isNew ? WorkItem.pendingColor.opacity(0.6) : .clear, radius: 3)
                    .frame(width: 6, height: 6).offset(y: -1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.key).font(Type.key).foregroundStyle(.secondary)
                        if let s = item.status { StatusPill(text: s, tone: item.statusTone) }
                        if aging { StatusPill(text: "waiting \(item.updated.relative)", tone: .danger) }
                        if let p = item.pipeline { PipelineMark(status: p) }
                        Spacer(minLength: 0)
                        Text(item.updated.relative).font(Type.meta).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    Text(item.title).font(Type.title).lineLimit(2).multilineTextAlignment(.leading)
                        .foregroundStyle(item.isDraft ? .secondary : .primary)
                    HStack(spacing: 6) {
                        Text(item.subtitle).font(Type.meta).foregroundStyle(.secondary)
                        if !item.hostLabel.isEmpty {
                            Text("·").foregroundStyle(.quaternary)
                            Text(item.hostLabel).font(Type.meta).foregroundStyle(.tertiary)
                        }
                        if let p = item.priority, item.source == .jira {
                            Text("·").foregroundStyle(.quaternary)
                            Text(p).font(Type.meta).foregroundStyle(.tertiary)
                        }
                        if item.approvals > 0 {
                            Text("·").foregroundStyle(.quaternary)
                            Text("\(item.approvals) approved").font(Type.meta).foregroundStyle(.tertiary)
                        }
                    }
                    if !links.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(links) { l in LinkChip(item: l) { openLink?(l) } }
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(selected ? 0.10 : hover ? 0.06 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? WorkItem.Tone.active.color.opacity(0.6) : .clear, lineWidth: 1))
            .id(item.id)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(item.url.absoluteString)
        .contextMenu { if let menu { menu } }
    }
}

/// Cross-reference: a Jira key under an MR, or an MR under a Jira task. Key + status, nothing else.
struct LinkChip: View {
    let item: WorkItem
    let open: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Text(item.key).font(.system(size: 10, weight: .semibold, design: .monospaced))
                if let s = item.status {
                    Text(s.lowercased()).font(.system(size: 10)).foregroundStyle(item.statusTone.color)
                }
            }
            .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.primary.opacity(hover ? 0.12 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(item.title.isEmpty ? item.url.absoluteString : item.title)
    }
}

/// Right-click menu for a Jira row: transitions load lazily, then comment / assign / open.
struct JiraMenu: View {
    let item: WorkItem
    @EnvironmentObject var hub: Hub
    @State private var transitions: [JiraClient.Transition] = []
    var body: some View {
        Group {
            if transitions.isEmpty {
                Text("Loading transitions…")
            } else {
                ForEach(transitions) { t in
                    Button("Move to \(t.toStatus)") { Task { await hub.jiraTransition(item, t) } }
                }
            }
            Divider()
            Button("Comment…") { hub.jiraCommentTarget = item }
            Button("Assign to me") { Task { await hub.jiraAssignToMe(item) } }
            Divider()
            Button("Open in browser") { hub.open(item) }
        }
        .task { transitions = await hub.jiraTransitions(item.key) }
    }
}

/// Sheet for a Jira comment.
struct JiraCommentSheet: View {
    let item: WorkItem
    @EnvironmentObject var hub: Hub
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(item.key).font(Type.key).foregroundStyle(.secondary)
                Text(item.title).font(Type.title).lineLimit(1)
            }
            ComposeBox(text: $text, placeholder: "Comment…", submit: "Comment") {
                let body = text; dismiss()
                Task { await hub.jiraComment(item, body) }
            } cancel: { dismiss() }
        }
        .padding(18).frame(width: 480)
    }
}

struct StatusPill: View {
    let text: String
    let tone: WorkItem.Tone
    var body: some View {
        Text(text.lowercased())
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill((tone == .neutral ? Color.primary : tone.color).opacity(0.10)))
    }
}

/// CI state as a thin bar rather than a badge. Green/red/amber only when it matters.
struct PipelineMark: View {
    let status: String
    var color: Color {
        switch status {
        case "success": return WorkItem.Tone.done.color
        case "failed", "canceled": return WorkItem.Tone.danger.color
        case "running", "pending": return WorkItem.Tone.warn.color
        default: return .secondary.opacity(0.4)
        }
    }
    var body: some View {
        RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 3)
            .help("pipeline: \(status)")
    }
}

/// Section = glass card with a quiet header and rows.
struct SectionCard<Content: View>: View {
    let title: String
    let count: Int
    var tint: Color? = nil
    var error: String? = nil
    var empty: String = "Nothing here"
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased()).font(Type.section).foregroundStyle(.secondary).kerning(0.8)
                Spacer()
                Text("\(count)").font(Type.count).foregroundStyle(count == 0 ? .tertiary : .primary).monospacedDigit()
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            if let error {
                Text(error).font(Type.meta).foregroundStyle(WorkItem.Tone.danger.color)
                    .padding(.horizontal, 16).padding(.bottom, 14).textSelection(.enabled)
            } else if count == 0 {
                Text(empty).font(Type.meta).foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.bottom, 14)
            } else {
                VStack(spacing: 2) { content }.padding(.horizontal, 4).padding(.bottom, 6)
            }
        }
        .glass(tint: tint)
    }
}
