import SwiftUI

struct ReviewView: View {
    @StateObject var model: ReviewModel
    @EnvironmentObject var hub: Hub
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var confirmMerge = false

    var body: some View {
        Group {
            if let d = model.detail {
                VStack(spacing: 0) {
                    header(d)
                    if isSnapshot {
                        HStack(spacing: 0) {
                            fileList(d).frame(width: 280)
                            content(d).frame(maxWidth: .infinity)
                        }
                    } else {
                        HSplitView {
                            fileList(d).frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                            content(d).frame(minWidth: 480, maxWidth: .infinity)
                        }
                    }
                }
            } else if let e = model.error {
                VStack(spacing: 8) {
                    BackButton()
                    Text(e).font(Type.meta).foregroundStyle(WorkItem.Tone.danger.color).textSelection(.enabled)
                    Button("Retry") { Task { await model.load() } }.buttonStyle(.plain).font(Type.meta).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if model.detail == nil { await model.load() } }
        .background {
            Group {
                Button("") { model.toggleViewedAndAdvance() }.keyboardShortcut("v", modifiers: [])
                Button("") { if !ReviewModel.isTyping { model.selectFile(offset: 1) } }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") { if !ReviewModel.isTyping { model.selectFile(offset: -1) } }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { if !ReviewModel.isTyping { model.selectFile(offset: 1) } }.keyboardShortcut("j", modifiers: [])
                Button("") { if !ReviewModel.isTyping { model.selectFile(offset: -1) } }.keyboardShortcut("k", modifiers: [])
                Button("") { model.searchFocusRequest += 1 }.keyboardShortcut("f", modifiers: .command)
                Button("") { if !ReviewModel.isTyping { model.stepMatch(1) } }.keyboardShortcut("n", modifiers: [])
                Button("") { if !ReviewModel.isTyping { model.stepMatch(-1) } }.keyboardShortcut("n", modifiers: .shift)
            }
            .hidden()
        }
        .onChange(of: model.searchActive) { _, on in hub.escapeOwnedBySubview = on }
        .onDisappear { hub.escapeOwnedBySubview = false }
    }

    // MARK: header

    private func header(_ d: ChangeDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                BackButton()
                Text(d.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                if d.draft { StatusPill(text: "draft", tone: .neutral) }
                if !d.isOpen { StatusPill(text: d.state, tone: d.state == "merged" ? .done : .neutral) }
                Spacer()
                if let f = model.flash { Text(f).font(Type.meta).foregroundStyle(WorkItem.Tone.done.color).transition(.opacity) }
                if model.busy { ProgressView().controlSize(.mini) }
                if let e = model.error { Text(e).font(Type.meta).foregroundStyle(WorkItem.Tone.danger.color).lineLimit(1).help(e) }
            }
            HStack(spacing: 10) {
                Text(d.author).font(Type.meta).foregroundStyle(.secondary)
                Text("\(d.sourceBranch) → \(d.targetBranch)").font(Type.key).foregroundStyle(.tertiary).lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(d.files.count) files").font(Type.meta).foregroundStyle(.secondary)
                    Text("+\(d.additions)").font(Type.key).foregroundStyle(WorkItem.Tone.done.color)
                    Text("−\(d.deletions)").font(Type.key).foregroundStyle(WorkItem.Tone.danger.color)
                    Text("· \(d.commits.count) commits").font(Type.meta).foregroundStyle(.secondary)
                }
                if let p = d.pipeline { PipelineMark(status: p); Text(p).font(Type.meta).foregroundStyle(.tertiary) }
                ForEach(linkedJira(d)) { j in LinkChip(item: j) { hub.open(j) } }
                if !d.approvals.isEmpty {
                    Text("approved by \(d.approvals.joined(separator: ", "))").font(Type.meta).foregroundStyle(WorkItem.Tone.done.color)
                }
                if model.unresolvedCount > 0 {
                    Text("\(model.unresolvedCount) unresolved").font(Type.meta).foregroundStyle(WorkItem.Tone.warn.color)
                }
                Spacer()
                if d.isOpen {
                    actionButton(d.approvedByMe ? "Unapprove" : "Approve", tone: d.approvedByMe ? nil : .done) {
                        Task { await model.approve(!d.approvedByMe) }
                    }
                    actionButton("Merge", tone: d.mergeable ? .active : nil) { confirmMerge = true }
                        .disabled(!d.mergeable)
                        .confirmationDialog("Merge into \(d.targetBranch)?", isPresented: $confirmMerge) {
                            Button("Merge") { Task { await model.merge() } }
                        } message: { Text(d.title) }
                }
                actionButton("Refresh") { Task { await model.load() } }.keyboardShortcut("r")
                actionButton("Open in browser") { model.openInBrowser() }
            }
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
    }

    private func linkedJira(_ d: ChangeDetail) -> [WorkItem] {
        let probe = WorkItem(id: "probe", source: .gitlab, kind: .reviewRequest, key: "", title: d.title, subtitle: d.sourceBranch,
                             url: d.url, updated: .distantPast, change: d.ref)
        return hub.linkedJira(for: probe)
    }

    private func actionButton(_ title: String, tone: WorkItem.Tone? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Type.meta).fontWeight(tone == nil ? .regular : .medium)
                .foregroundStyle(tone.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
                .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .glass(tint: tone?.color, radius: 8, interactive: true)
    }

    // MARK: file list

    private func fileList(_ d: ChangeDetail) -> some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 2) {
                fileRow(title: "Conversation", meta: "\(model.threads(for: nil).count)", selected: model.selectedFile == nil, status: nil) {
                    model.selectedFile = nil
                }
                if let c = model.selectedCommit {
                    HStack(spacing: 6) {
                        Button("All changes") { model.showCommit(nil) }.buttonStyle(.plain).font(Type.meta).foregroundStyle(WorkItem.Tone.active.color)
                        Text("›").foregroundStyle(.quaternary)
                        Text(c.short).font(Type.key).foregroundStyle(.secondary)
                        if model.commitLoading { ProgressView().controlSize(.mini) }
                    }
                    .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                    Text(c.title).font(Type.meta).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 12).padding(.bottom, 6)
                }
                HStack(spacing: 6) {
                    Text("FILES · \(model.shownFiles.count)").font(Type.section).foregroundStyle(.secondary).kerning(0.8)
                    if !model.commitMode, model.viewedCount > 0 {
                        Text("· \(model.viewedCount) viewed").font(Type.section).foregroundStyle(model.viewedCount == d.files.count ? AnyShapeStyle(WorkItem.Tone.done.color) : AnyShapeStyle(.tertiary))
                    }
                }
                .padding(.horizontal, 12).padding(.top, model.commitMode ? 4 : 14).padding(.bottom, 4)
                ForEach(model.shownFiles) { f in
                    let unresolved = model.threads(for: f.path).filter { !$0.resolved }.count
                    let hits = model.matchCount(in: f)
                    fileRow(title: f.path, meta: hits > 0 ? "\(hits) hits" : "+\(f.additions) −\(f.deletions)", selected: model.selectedFile == f.path,
                            status: f.status, threads: unresolved,
                            viewed: model.commitMode ? nil : model.isViewed(f),
                            toggleViewed: { model.setViewed(f, !model.isViewed(f)) }) { model.selectedFile = f.path }
                }
                if !d.commits.isEmpty {
                    Text("COMMITS · \(d.commits.count)").font(Type.section).foregroundStyle(.secondary).kerning(0.8)
                        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                    ForEach(d.commits) { c in commitRow(c) }
                }
            }
            .padding(10)
        }
        .glass(radius: 14)
        .padding(.leading, 18).padding(.bottom, 18)
    }

    private func commitRow(_ c: CommitInfo) -> some View {
        let selected = model.selectedCommit?.id == c.id
        return Button { model.showCommit(selected ? nil : c) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(c.short).font(Type.key).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.title).font(Type.title).lineLimit(2)
                    Text("\(c.author) · \(c.date.relative)").font(Type.meta).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(selected ? 0.10 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { if let u = c.url { Button("Open commit in browser") { NSWorkspace.shared.open(u) } } }
        .help(c.url?.absoluteString ?? c.id)
    }

    private func fileRow(title: String, meta: String, selected: Bool, status: FileDiff.Status?, threads: Int = 0,
                         viewed: Bool? = nil, toggleViewed: (() -> Void)? = nil, _ tap: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        // The viewed toggle sits beside the row button, not inside it, so its tap isn't swallowed.
        return HStack(spacing: 4) {
            Button(action: tap) {
                HStack(spacing: 8) {
                    if let s = status {
                        Circle().fill(statusColor(s)).frame(width: 6, height: 6)
                    } else {
                        Circle().fill(.clear).frame(width: 6, height: 6)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text((title as NSString).lastPathComponent).font(Type.title).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                        let dir = (title as NSString).deletingLastPathComponent
                        if !dir.isEmpty { Text(dir).font(Type.meta).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head) }
                    }
                    Spacer(minLength: 4)
                    if threads > 0 { Circle().fill(WorkItem.Tone.warn.color).frame(width: 5, height: 5) }
                    Text(meta).font(Type.key).foregroundStyle(.tertiary)
                }
                .padding(.leading, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let viewed, let toggleViewed {
                ViewedMark(on: viewed, toggle: toggleViewed).padding(.trailing, 3)
            } else {
                Spacer().frame(width: 8)
            }
        }
        .background(shape.fill(selected ? WorkItem.Tone.active.color.opacity(0.16) : .clear))
        .overlay(shape.strokeBorder(selected ? WorkItem.Tone.active.color.opacity(0.45) : .clear, lineWidth: 1))
        .opacity(viewed == true && !selected ? 0.55 : 1)
    }

    private func statusColor(_ s: FileDiff.Status) -> Color {
        switch s {
        case .added: return WorkItem.Tone.done.color
        case .deleted: return WorkItem.Tone.danger.color
        case .renamed: return WorkItem.Tone.warn.color
        case .modified: return WorkItem.Tone.active.color
        }
    }

    // MARK: right pane

    @ViewBuilder
    private func content(_ d: ChangeDetail) -> some View {
        if let f = model.file(model.selectedFile) {
            DiffView(file: f, model: model)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .glass(radius: 14).padding(.horizontal, 18).padding(.bottom, 18)
        } else if model.commitMode {
            VStack(spacing: 8) {
                if model.commitLoading { ProgressView().controlSize(.small) }
                else { Text(model.commitFiles.isEmpty ? "No files in this commit" : "Pick a file").font(Type.meta).foregroundStyle(.tertiary) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glass(radius: 14).padding(.horizontal, 18).padding(.bottom, 18)
        } else {
            ConversationView(detail: d, model: model)
                .glass(radius: 14).padding(.horizontal, 18).padding(.bottom, 18)
        }
    }
}

/// Description + unanchored threads + new-comment box.
struct ConversationView: View {
    let detail: ChangeDetail
    @ObservedObject var model: ReviewModel
    @State private var draft = ""

    var body: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 16) {
                if !detail.description.isEmpty {
                    Text(markdown(detail.description)).font(Type.title).textSelection(.enabled).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(model.threads(for: nil)) { t in ThreadView(thread: t, model: model) }
                ComposeBox(text: $draft, placeholder: "Comment on this \(model.kind.noun)…", submit: "Comment") {
                    Task { await model.comment(draft, at: nil); draft = "" }
                }
            }
            .padding(18)
        }
    }
}

func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

struct ThreadView: View {
    let thread: ReviewThread
    @ObservedObject var model: ReviewModel
    @State private var reply = ""
    @State private var replying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(thread.comments) { c in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(c.author).font(Type.meta).fontWeight(.medium)
                        Text(c.created.relative).font(Type.meta).foregroundStyle(.tertiary)
                    }
                    Text(markdown(c.body)).font(Type.title).textSelection(.enabled).lineSpacing(2)
                }
            }
            HStack(spacing: 12) {
                if replying {
                    ComposeBox(text: $reply, placeholder: "Reply…", submit: "Reply") {
                        Task { await model.reply(reply, to: thread); reply = ""; replying = false }
                    }
                } else {
                    Button("Reply") { replying = true }.buttonStyle(.plain).font(Type.meta).foregroundStyle(.secondary)
                    if thread.resolvable {
                        Button(thread.resolved ? "Reopen" : "Resolve") { Task { await model.resolve(thread, !thread.resolved) } }
                            .buttonStyle(.plain).font(Type.meta)
                            .foregroundStyle(thread.resolved ? AnyShapeStyle(.secondary) : AnyShapeStyle(WorkItem.Tone.done.color))
                    }
                    Spacer()
                    if thread.resolved { Text("resolved").font(Type.meta).foregroundStyle(.tertiary) }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(thread.resolved ? 0.03 : 0.06)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(thread.resolved ? Color.clear : WorkItem.Tone.warn.color.opacity(0.7)).frame(width: 2).padding(.vertical, 10)
        }
        .opacity(thread.resolved ? 0.7 : 1)
    }
}

struct ComposeBox: View {
    @Binding var text: String
    let placeholder: String
    let submit: String
    let action: () -> Void
    var cancel: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(Type.title).lineLimit(2...8)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.05)))
            HStack(spacing: 10) {
                if let cancel { Button("Cancel", action: cancel).buttonStyle(.plain).font(Type.meta).foregroundStyle(.tertiary) }
                Button(submit, action: action).buttonStyle(.plain).font(Type.meta).fontWeight(.medium)
                    .foregroundStyle(text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(WorkItem.Tone.active.color))
                    .disabled(text.isEmpty).keyboardShortcut(.return, modifiers: .command)
            }
        }
        .frame(maxWidth: .infinity)
    }
}


/// Hollow ring → filled ring with a check. Click to toggle; `v` does the same for the open file.
struct ViewedMark: View {
    let on: Bool
    let toggle: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: toggle) {
            ZStack {
                Circle().strokeBorder(on ? WorkItem.Tone.done.color : Color.secondary.opacity(hover ? 0.8 : 0.35), lineWidth: 1.2)
                if on { Circle().fill(WorkItem.Tone.done.color.opacity(0.18)) }
                if on { Text("✓").font(.system(size: 9, weight: .bold)).foregroundStyle(WorkItem.Tone.done.color) }
            }
            .frame(width: 15, height: 15)
            .padding(5)                      // bigger target; the stroke alone was the only hittable pixel
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(on ? "Viewed — click to unmark" : "Mark as viewed (v)")
    }
}
